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
    /// URLSession used ONLY for the long-lived SSE GET stream. Configured
    /// with a delegate so bytes are pushed via `urlSession(_:dataTask:didReceive:)`
    /// the moment they arrive — `URLSession.bytes(for:)` would buffer
    /// chunks indefinitely on quiet streams (verified against Z.AI: small
    /// initialize responses arrive instantly, but a 3KB tools/list response
    /// gets held back until the buffer fills). Delegate-based reading
    /// bypasses that buffering entirely.
    private let sseSession: URLSession
    private let sseDelegate: SSEStreamDelegate
    /// Separate URLSession for outbound POSTs so HTTP/2 multiplexing on the
    /// SSE stream can't interfere with message sending.
    private let postSession: URLSession
    private let logger = Logger(subsystem: "AgentMCP", category: "LegacyHTTPSSE")

    private struct State {
        /// URL we POST messages to, resolved from the server's `endpoint` event.
        var messageURL: URL?
        /// Continuations for in-flight requests, keyed by JSON-RPC id.
        /// Resolved when a matching `message` SSE event arrives.
        var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        /// Continuation that wakes up when the first `endpoint` event arrives.
        var endpointContinuation: CheckedContinuation<URL, Error>?
        /// Set if the SSE reader received the endpoint event BEFORE
        /// `connectAndDiscoverEndpoint` registered its continuation. The
        /// caller checks this on registration so the event is never lost
        /// to a races between the spawn-task-then-register sequence.
        var pendingEndpoint: URL?
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
        // Long-lived SSE stream — bump both timeouts so quiet periods don't
        // tear the connection down.
        let sseConfig = URLSessionConfiguration.ephemeral
        sseConfig.timeoutIntervalForRequest = 600
        sseConfig.timeoutIntervalForResource = 86400
        let delegate = SSEStreamDelegate()
        self.sseDelegate = delegate
        self.sseSession = URLSession(configuration: sseConfig, delegate: delegate, delegateQueue: nil)
        // POSTs use a separate session so they can't get muxed onto the
        // same HTTP/2 connection as the SSE stream and cause head-of-line
        // blocking on the response side.
        let postConfig = URLSessionConfiguration.ephemeral
        postConfig.timeoutIntervalForRequest = 60
        self.postSession = URLSession(configuration: postConfig)
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

        // Wait for the endpoint event. Race-safe: the SSE reader may have
        // ALREADY received and stashed `pendingEndpoint` before we get
        // here, so the registration step checks for it and resumes
        // immediately if so. Otherwise we register the continuation and
        // the SSE reader will resume it when the event arrives.
        let endpointURL: URL = try await withCheckedThrowingContinuation { continuation in
            let immediate: URL? = state.withLock { state in
                if let pending = state.pendingEndpoint {
                    state.pendingEndpoint = nil
                    return pending
                }
                state.endpointContinuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
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

        // Wire the delegate to forward bytes into our parser. Using a
        // URLSessionDataDelegate (rather than URLSession.bytes) is the
        // ONLY way to get bytes pushed as soon as they arrive — bytes()
        // buffers chunks until enough data has accumulated, which makes
        // long-lived SSE streams stall waiting for events that have
        // already been written to the wire by the server.
        sseDelegate.onBytes = { [weak self] data in
            self?.feedSSEBytes(data)
        }
        sseDelegate.onComplete = { [weak self] error in
            if let error {
                self?.fail(error)
            } else {
                self?.fail(MCPClientError.connectionFailed("SSE stream closed by server"))
            }
        }

        let task = sseSession.dataTask(with: request)
        task.resume()
    }

    /// SSE parser state — owned by the connection, fed by the delegate one
    /// chunk at a time. Kept as instance properties so the parser is
    /// stateful across multiple delegate callbacks.
    private var parserCurrentEvent = ""
    private var parserCurrentData = ""
    private var parserLineBuffer = Data()
    private let parserLock = OSAllocatedUnfairLock(initialState: ())

    /// Process a chunk of bytes pushed by the SSE delegate. The same
    /// byte-level event-detection logic that worked in the bytes-iterator
    /// version, just driven by chunks instead of an `await` loop.
    private func feedSSEBytes(_ data: Data) {
        // Parse inside the lock and return the list of complete events to
        // dispatch outside the lock. Holding the parser lock across the
        // dispatch boundary risks deadlock with the connection state lock.
        let eventsToDispatch: [(String, String)] = parserLock.withLock { _ -> [(String, String)] in
            var events: [(String, String)] = []
            for byte in data {
                if byte == 0x0D { continue }  // strip CR
                if byte != 0x0A {
                    parserLineBuffer.append(byte)
                    continue
                }

                let line = String(data: parserLineBuffer, encoding: .utf8) ?? ""
                parserLineBuffer.removeAll(keepingCapacity: true)

                if line.isEmpty {
                    // Blank line — event delimiter.
                    if !parserCurrentData.isEmpty || !parserCurrentEvent.isEmpty {
                        events.append((parserCurrentEvent, parserCurrentData))
                        parserCurrentEvent = ""
                        parserCurrentData = ""
                    }
                    continue
                }
                if line.hasPrefix(":") { continue }  // SSE comment
                if line.hasPrefix("event:") {
                    parserCurrentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                    continue
                }
                if line.hasPrefix("data:") {
                    let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    parserCurrentData = parserCurrentData.isEmpty ? chunk : parserCurrentData + "\n" + chunk
                    continue
                }
                // Ignore id:, retry:, and any other field per spec.
            }
            return events
        }
        // Dispatch events synchronously on the delegate queue (already a
        // background queue from URLSession). Avoids queue-hop overhead and
        // lifetime concerns of jumping to global() while the connection
        // might be tearing down.
        for (ev, dt) in eventsToDispatch {
            handleSSEEvent(eventType: ev, data: dt)
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
            // Wake up connectAndDiscoverEndpoint() if it's already waiting,
            // OR stash the URL in state so the upcoming registration picks
            // it up immediately. The race exists because we spawn the SSE
            // task BEFORE registering the continuation, and Z.AI sends the
            // endpoint event in <1s.
            let cont = state.withLock { state -> CheckedContinuation<URL, Error>? in
                if let c = state.endpointContinuation {
                    state.endpointContinuation = nil
                    return c
                }
                state.pendingEndpoint = resolved
                return nil
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

            let task = postSession.dataTask(with: request) { [weak self] _, response, error in
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
                // 200/202 — wait for the SSE response.
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
        let task = postSession.dataTask(with: request)
        task.resume()
    }

    func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        fail(MCPClientError.connectionFailed("Legacy HTTP+SSE connection closed by client"))
        sseSession.invalidateAndCancel()
        postSession.invalidateAndCancel()
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

// MARK: - SSE Stream Delegate

/// URLSessionDataDelegate that pushes incoming bytes to a callback the
/// moment they arrive — bypassing URLSession.bytes(for:)'s internal
/// buffering. Required for long-lived MCP HTTP+SSE streams where the
/// server emits a few KB and then waits for the client to POST.
final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Called for every chunk of bytes the server pushes.
    var onBytes: ((Data) -> Void)?
    /// Called once when the stream ends (cleanly or with an error).
    var onComplete: ((Error?) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        onBytes?(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete?(error)
    }
}
