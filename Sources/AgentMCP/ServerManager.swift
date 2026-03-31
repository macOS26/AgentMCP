import Foundation

/// Manages persistent MCP server configurations
/// Stores server configs in ~/Library/Application Support/Agent!/MCPServers/
/// Uses dictionary-backed O(1) lookups for all ID-based operations.
public actor ServerManager {

    // MARK: - Properties

    public static let shared = ServerManager()

    private let configDirectory: URL
    private let configFile: URL
    /// Ordered list for serialization and display
    private var servers: [MCPClient.ServerConfig] = []
    /// O(1) lookup by UUID
    private var serverIndex: [UUID: Int] = [:]

    // MARK: - Initialization

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        configDirectory = appSupport.appendingPathComponent("Agent!/MCPServers")
        configFile = configDirectory.appendingPathComponent("servers.json")
    }

    /// Rebuild the UUID → index map from the servers array
    private func rebuildIndex() {
        serverIndex.removeAll(keepingCapacity: true)
        for (i, s) in servers.enumerated() {
            serverIndex[s.id] = i
        }
    }

    // MARK: - Server Management

    /// Load saved server configurations
    public func loadServers() throws -> [MCPClient.ServerConfig] {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: configFile.path),
              let data = FileManager.default.contents(atPath: configFile.path),
              let decoded = try? JSONDecoder().decode([MCPClient.ServerConfig].self, from: data) else {
            servers = []
            serverIndex = [:]
            return servers
        }

        servers = decoded
        rebuildIndex()
        return servers
    }

    /// Save server configurations to disk
    public func saveServers() throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(servers)
        try data.write(to: configFile)
    }

    /// Add a new server configuration
    public func addServer(_ config: MCPClient.ServerConfig) throws {
        guard serverIndex[config.id] == nil else {
            throw ServerManagerError.duplicateServer
        }
        serverIndex[config.id] = servers.count
        servers.append(config)
        try saveServers()
    }

    /// Remove a server configuration
    public func removeServer(_ serverId: UUID) throws {
        guard let index = serverIndex[serverId] else {
            throw ServerManagerError.serverNotFound
        }
        servers.remove(at: index)
        rebuildIndex()
        try saveServers()
    }

    /// Update a server configuration
    public func updateServer(_ config: MCPClient.ServerConfig) throws {
        guard let index = serverIndex[config.id] else {
            throw ServerManagerError.serverNotFound
        }
        servers[index] = config
        try saveServers()
    }

    /// Get all server configurations
    public func getServers() -> [MCPClient.ServerConfig] {
        servers
    }

    /// Get a server by ID — O(1)
    public func getServer(_ id: UUID) -> MCPClient.ServerConfig? {
        guard let index = serverIndex[id] else { return nil }
        return servers[index]
    }

    /// Enable a server
    public func enableServer(_ serverId: UUID) throws {
        guard let index = serverIndex[serverId] else {
            throw ServerManagerError.serverNotFound
        }
        let config = servers[index]
        servers[index] = MCPClient.ServerConfig(
            id: config.id,
            name: config.name,
            command: config.command,
            arguments: config.arguments,
            env: config.env,
            enabled: true
        )
        try saveServers()
    }

    /// Disable a server
    public func disableServer(_ serverId: UUID) throws {
        guard let index = serverIndex[serverId] else {
            throw ServerManagerError.serverNotFound
        }
        let config = servers[index]
        servers[index] = MCPClient.ServerConfig(
            id: config.id,
            name: config.name,
            command: config.command,
            arguments: config.arguments,
            env: config.env,
            enabled: false
        )
        try saveServers()
    }

    // MARK: - Presets

    /// Common MCP server presets for quick setup
    public static let presets: [MCPClient.ServerConfig] = [
        MCPClient.ServerConfig(
            name: "Filesystem",
            command: "/usr/local/bin/mcp-server-filesystem",
            arguments: ["/Users/\(NSUserName())/Documents"],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "GitHub",
            command: "/usr/local/bin/mcp-server-github",
            arguments: [],
            env: ["GITHUB_TOKEN": ""],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "Puppeteer",
            command: "/usr/local/bin/mcp-server-puppeteer",
            arguments: [],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "SQLite",
            command: "/usr/local/bin/mcp-server-sqlite",
            arguments: [],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "Brave Search",
            command: "/usr/local/bin/mcp-server-brave-search",
            arguments: [],
            env: ["BRAVE_API_KEY": ""],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "Memory",
            command: "/usr/local/bin/mcp-server-memory",
            arguments: [],
            enabled: false
        ),
        MCPClient.ServerConfig(
            name: "Sequential Thinking",
            command: "/usr/local/bin/mcp-server-sequential-thinking",
            arguments: [],
            enabled: false
        )
    ]
}

// MARK: - Errors

public enum ServerManagerError: LocalizedError {
    case duplicateServer
    case serverNotFound
    case saveFailed(String)
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateServer:
            return "Server with this ID already exists"
        case .serverNotFound:
            return "Server not found"
        case .saveFailed(let reason):
            return "Failed to save servers: \(reason)"
        case .loadFailed(let reason):
            return "Failed to load servers: \(reason)"
        }
    }
}
