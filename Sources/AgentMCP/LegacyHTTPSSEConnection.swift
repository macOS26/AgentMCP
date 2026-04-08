import Foundation
import os

// MARK: - Legacy HTTP+SSE Connection (MCP spec 2024-11-05)

/// Implements the LEGACY MCP HTTP+SSE transport (MCP spec 2024-11-05).
///
/// This transport is fundamentally different from the modern Streamable HTTP
/// transport (`HTTPConnection`) — see the README for the comparison.
///
/// Connection lifecycle:
///
///   1. Client opens a long-lived `GET` request to the SSE URL with
///      `Accept: text/event-stream`. The response is a chunked SSE stream
///      that stays open for the entire connection.
///
///   2. The server's FIRST event over that stream is an `endpoint` event
///      whose data field is the URL the client must POST messages to.
///      Typically this is a relative URL containing a session id, e.g.
///      `data: /messages/?session_id=abc123`. We resolve it against the
///      base URL.
///
///   3. To send a JSON-RPC request, the client `POST`s the JSON to the
///      discovered message URL. The POST returns `202 Accepted` with an
///      empty body — the actual JSON-RPC RESPONSE is delivered back over
///      the original SSE stream as a `message` event.
///
///   4. To match a response to a pending request, the connection keeps a
///      map of expected request IDs → continuations. When a `message`
///      event arrives over SSE, we look up the request ID in the JSON-RPC
///      payload and resume the matching continuation.
///
///   5. `disconnect()` cancels the SSE task and resumes any outstanding
///      continuations with a "connection closed" error.
///
/// Used by Z.AI's MCP web search server, the original MCP Python SDK
/// (FastMCP < 2.0), and any other server whose URL pauses on a `/sse`
/// suffix. Auto-detected by `MCPClient.connectHTTP` when the URL path
/// ends in `/sse`.
final class LegacyHTTPSSEConnection: @unchecked Sendable, MCPConnection {

    // MARK: - State

    private let sseURL: URL
    private let customHeaders: [String: String]
    private let session: URLSession
    private let logger = Logger(subsystem: "AgentMCP", category: "LegacyHTTPSSE")

    private struct State {
        /// URL we POST messages to, resolved from the server's `endpoint` event.
        var messageURL: URL?
        /// Continuations for in-flight requests, keyed by JSON-RPC id.
        /// Resolved when a matching `message` SSE event arrives.
        var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        /// Continuation that wakes up when the first `endpoint` event arrives.
        var endpointContinuation: CheckedContinuation<URL, Error>?
        var nextId: Int = 0
        var alive: Bool = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Background task that owns the long-lived SSE GET stream.
    private var sseTask: Task<Void, Never>?

    // MARK: - Init / connect

    init(url: URL, headers: [String: String]) {
        self.sseURL = url
        self.customHeaders = headers
        let config = URLSessionConfiguration.default
        // The SSE stream is intentionally long-lived. Bump the per-resource
        // timeout into hours; without this URLSession will tear the stream
        // down after the default 7 days but URLSession.bytes will throw
        // when the request-side timeout fires (180s default). Set both
        // generous values so the stream survives quiet periods.
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 86400
        self.session = URLSession(configuration: config)
    }

    var isAlive: Bool { state.withLock { $0.alive } }

    /// Open the SSE stream and wait for the server's `endpoint` event.
    /// Must be called once before any sendRequest/sendNotification calls.
    func connectAndDiscoverEndpoint() async throws {
        // Spawn the background reader task. It will populate `messageURL`
        // when the server emits the `endpoint` event.
        sseTask = Task { [weak self] in
            await self?.runSSEStream()
        }

        // Wait up to 30 seconds for the endpoint to be discovered.
        let endpointURL: URL = try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.endpointContinuation = continuation
            }
        }

        // Stash the discovered URL so subsequent POSTs use it.
        state.withLock { $0.messageURL = endpointURL }
    }

    // MARK: - SSE stream reader

    private func runSSEStream() async {
        var request = URLRequest(url: sseURL)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                fail(MCPClientError.connectionFailed("Invalid HTTP response from SSE endpoint"))
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                fail(MCPClientError.connectionFailed("SSE endpoint returned HTTP \(httpResponse.statusCode)"))
                return
            }

            // Parse the stream line by line. Per the SSE spec, an event is
            // delimited by a blank line. Each event accumulates `event:` and
            // one or more `data:` lines.
            var currentEvent = ""
            var currentData = ""

            for try await line in bytes.lines {
                // Stop reading if disconnected.
                if !isAlive { break }

                if line.isEmpty {
                    // Event boundary — dispatch what we've collected.
                    if !currentData.isEmpty {
                        handleSSEEvent(eventType: currentEvent, data: currentData)
                    }
                    currentEvent = ""
                    currentData = ""
                    continue
                }
                if line.hasPrefix(":") {
                    // SSE comment / keep-alive — ignore.
                    continue
                }
                if line.hasPrefix("event:") {
                    currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("data:") {
                    let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    currentData = currentData.isEmpty ? chunk : currentData + "\n" + chunk
                    continue
                }
                // Ignore "id:", "retry:" and any other field per spec.
            }

            // Stream ended cleanly — fail any in-flight requests so callers
            // don't hang waiting for a response that will never arrive.
            fail(MCPClientError.connectionFailed("SSE stream closed by server"))
        } catch {
            fail(error)
        }
    }

    /// Handle a single complete SSE event. The two events we care about are:
    ///   - `endpoint` (sent once near the start of the stream): the URL we
    ///     should POST messages to. Wakes up `connectAndDiscoverEndpoint()`.
    ///   - `message` (sent for every JSON-RPC response): a JSON-RPC payload.
    ///     We parse it, look up the matching request id in `pending`, and
    ///     resume the continuation with the response.
    ///
    /// All other event types are ignored per the MCP spec.
    private func handleSSEEvent(eventType: String, data: String) {
        let type = eventType.isEmpty ? "message" : eventType

        switch type {
        case "endpoint":
            // The endpoint URL is typically a relative path with a session
            // id query parameter. Resolve against the base SSE URL so we
            // get a fully-qualified URL to POST to.
            let resolved = resolveEndpointURL(data)
            guard let resolved else {
                fail(MCPClientError.connectionFailed("Server sent invalid endpoint URL: \(data)"))
                return
            }
            // Wake up connectAndDiscoverEndpoint().
            let cont = state.withLock { state -> CheckedContinuation<URL, Error>? in
                let c = state.endpointContinuation
                state.endpointContinuation = nil
                return c
            }
            cont?.resume(returning: resolved)

        case "message":
            // Parse the JSON-RPC payload and route by id.
            guard let jsonData = data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                logger.warning("Dropped non-JSON SSE message event")
                return
            }
            // Notifications (no id) are server-pushed events that we don't
            // currently route — discard them. Adding subscription support is
            // a separate concern.
            guard let idAny = json["id"] else { return }
            let id: Int
            if let i = idAny as? Int { id = i }
            else if let s = idAny as? String, let i = Int(s) { id = i }
            else { return }

            let cont = state.withLock { state -> CheckedContinuation<[String: Any], Error>? in
                state.pending.removeValue(forKey: id)
            }
            cont?.resume(returning: json)

        default:
            // Unknown event type — ignore per SSE spec.
            return
        }
    }

    /// Resolve the URL the server sent in its `endpoint` event. The server
    /// typically sends a relative path like `/messages/?session_id=xyz`,
    /// which we resolve against the SSE base URL. Absolute URLs are
    /// passed through unchanged.
    private func resolveEndpointURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Absolute URL — use as-is.
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        // Relative URL — resolve against the SSE URL.
        return URL(string: trimmed, relativeTo: sseURL)?.absoluteURL
    }

    /// Resume every outstanding continuation with `error` and mark the
    /// connection dead. Used both on stream errors and on `disconnect()`.
    private func fail(_ error: Error) {
        let (pendings, endpoint) = state.withLock { state -> ([CheckedContinuation<[String: Any], Error>], CheckedContinuation<URL, Error>?) in
            state.alive = false
            let pendings = Array(state.pending.values)
            state.pending.removeAll()
            let endpoint = state.endpointContinuation
            state.endpointContinuation = nil
            return (pendings, endpoint)
        }
        for c in pendings { c.resume(throwing: error) }
        endpoint?.resume(throwing: error)
    }

    // MARK: - MCPConnection protocol

    func sendRequest(method: String, params: [String: Any]?) async throws -> [String: Any] {
        guard isAlive else {
            throw MCPClientError.connectionFailed("Legacy HTTP+SSE connection is closed")
        }
        guard let messageURL = state.withLock({ $0.messageURL }) else {
            throw MCPClientError.connectionFailed("Legacy HTTP+SSE connection has not received an `endpoint` event yet")
        }

        let id = nextRequestId()

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params { body["params"] = params }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        // Register the continuation BEFORE sending the POST so the SSE
        // reader can route the response back to us regardless of how
        // quickly it arrives.
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.pending[id] = continuation
            }

            // Fire-and-forget POST. The actual JSON-RPC response will arrive
            // over the SSE stream and resume `continuation`.
            var request = URLRequest(url: messageURL)
            request.httpMethod = "POST"
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (key, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let task = session.dataTask(with: request) { [weak self] _, response, error in
                // If the POST itself fails (network error, non-2xx status)
                // we have to clean up the pending continuation here — the
                // SSE side will never deliver a response.
                if let error {
                    self?.failPending(id: id, with: error)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   !(200..<300).contains(httpResponse.statusCode)
                {
                    self?.failPending(
                        id: id,
                        with: MCPClientError.connectionFailed("Message POST returned HTTP \(httpResponse.statusCode)")
                    )
                    return
                }
                // 202 Accepted — wait for the SSE response.
            }
            task.resume()
        }
    }

    func sendNotification(method: String, params: [String: Any]?) throws {
        guard isAlive else { return }
        guard let messageURL = state.withLock({ $0.messageURL }) else {
            throw MCPClientError.connectionFailed("Legacy HTTP+SSE connection has not received an `endpoint` event yet")
        }

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params { body["params"] = params }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: messageURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Fire-and-forget — notifications never receive a response.
        let task = session.dataTask(with: request)
        task.resume()
    }

    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        fail(MCPClientError.connectionFailed("Legacy HTTP+SSE connection closed by client"))
        session.invalidateAndCancel()
    }

    // MARK: - Helpers

    private func nextRequestId() -> Int {
        state.withLock { s in
            s.nextId += 1
            return s.nextId
        }
    }

    private func failPending(id: Int, with error: Error) {
        let cont = state.withLock { state -> CheckedContinuation<[String: Any], Error>? in
            state.pending.removeValue(forKey: id)
        }
        cont?.resume(throwing: error)
    }
}
