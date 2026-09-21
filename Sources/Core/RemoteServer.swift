import Foundation

enum RemoteLinkStatus: String, Equatable {
    case connecting
    case ok
    case offline
    case auth
    case unsupported
}

struct RemoteServer: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var user: String?
    var port: Int?
    var identityPath: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityPath = identityPath
    }

    var destination: String { host }

    var subtitle: String {
        var value = host
        if let user, !user.isEmpty {
            value = "\(user)@\(value)"
        }
        if let port, port != 22 {
            value += ":\(port)"
        }
        return value
    }
}

struct RemoteSample: Equatable {
    var status: RemoteLinkStatus = .connecting
    var notice: String?
    var hostname: String?
    var cpuFraction: Double = 0
    var cpuReady: Bool = false
    var cpuHistory: [Double] = []
    var ramUsed: UInt64 = 0
    var ramTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var uptimeSeconds: TimeInterval = 0
    var diskUsed: UInt64 = 0
    var diskTotal: UInt64 = 0
    var powerWatts: Double?
    var topProcesses: [ProcessUsage] = []

    var ramFraction: Double {
        guard ramTotal > 0 else { return 0 }
        return min(max(Double(ramUsed) / Double(ramTotal), 0), 1)
    }

    var diskFraction: Double {
        guard diskTotal > 0 else { return 0 }
        return min(max(Double(diskUsed) / Double(diskTotal), 0), 1)
    }

    static func connecting() -> RemoteSample {
        RemoteSample(status: .connecting)
    }

    static func failed(_ status: RemoteLinkStatus, notice: String?) -> RemoteSample {
        RemoteSample(status: status, notice: notice)
    }
}

enum RemoteCatalog {
    static let maxServers = 8
    static let maxNameLength = 32
    static let maxHostLength = 253

    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func make(
        host: String,
        name: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityPath: String? = nil
    ) throws -> RemoteServer {
        let host = try requireToken(host, label: "Host", max: maxHostLength)
        if host.hasPrefix("-") {
            throw ToolError.failed("Host cannot start with a dash.")
        }
        let user = try optionalToken(user, label: "User", max: 64)
        if let user, user.hasPrefix("-") {
            throw ToolError.failed("User cannot start with a dash.")
        }
        let identity = try optionalToken(identityPath, label: "Identity", max: 1024)
        if let port, !(1...65_535).contains(port) {
            throw ToolError.failed("Port must be between 1 and 65535.")
        }
        let resolvedPort = port == 22 ? nil : port
        var label = tidy(name ?? "")
        if label.isEmpty { label = host }
        label = String(label.prefix(maxNameLength))
        return RemoteServer(
            name: label,
            host: host,
            user: user,
            port: resolvedPort,
            identityPath: identity
        )
    }

    static func clean(_ servers: [RemoteServer]) -> [RemoteServer] {
        var seenIDs = Set<UUID>()
        var result: [RemoteServer] = []
        for server in servers {
            guard seenIDs.insert(server.id).inserted else { continue }
            guard let made = try? make(
                host: server.host,
                name: server.name,
                user: server.user,
                port: server.port,
                identityPath: server.identityPath
            ) else { continue }
            result.append(
                RemoteServer(
                    id: server.id,
                    name: made.name,
                    host: made.host,
                    user: made.user,
                    port: made.port,
                    identityPath: made.identityPath
                )
            )
            if result.count == maxServers { break }
        }
        return result
    }

    static func adding(_ server: RemoteServer, to servers: [RemoteServer]) throws -> [RemoteServer] {
        var servers = clean(servers)
        if servers.contains(where: { $0.id == server.id }) {
            return servers.map { $0.id == server.id ? server : $0 }
        }
        if servers.count >= maxServers {
            throw ToolError.failed("You can add up to \(maxServers) servers.")
        }
        if servers.contains(where: { $0.name.compare(server.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw ToolError.failed("A server named \(server.name) is already there.")
        }
        servers.append(server)
        return servers
    }

    static func removing(_ key: String, from servers: [RemoteServer]) throws -> [RemoteServer] {
        let match = try match(key, in: servers)
        return servers.filter { $0.id != match.id }
    }

    static func match(_ key: String, in servers: [RemoteServer]) throws -> RemoteServer {
        let needle = tidy(key)
        guard !needle.isEmpty else {
            throw ToolError.failed("Say which server: a name or id.")
        }
        if let uuid = UUID(uuidString: needle), let found = servers.first(where: { $0.id == uuid }) {
            return found
        }
        let named = servers.filter {
            $0.name.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw ToolError.failed("More than one server is named \(needle). Pass the id.")
        }
        let hosted = servers.filter {
            $0.host.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if hosted.count == 1 { return hosted[0] }
        if hosted.count > 1 {
            throw ToolError.failed("More than one server uses \(needle). Pass the name or id.")
        }
        let lowered = needle.lowercased()
        let prefixed = servers.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
        if prefixed.count == 1 { return prefixed[0] }
        throw ToolError.failed("\(needle) is not a saved server.")
    }

    static func save(_ servers: [RemoteServer]) {
        ToolStateStore.shared.update { $0.remotes = clean(servers) }
        ToolStateStore.shared.notifyChange()
    }

    static func current() -> [RemoteServer] {
        clean(ToolStateStore.shared.current.remotes)
    }

    private static func requireToken(_ text: String, label: String, max: Int) throws -> String {
        let value = tidy(text)
        guard !value.isEmpty else {
            throw ToolError.failed("\(label) cannot be empty.")
        }
        if value.contains(where: { $0.isNewline }) {
            throw ToolError.failed("\(label) cannot contain a line break.")
        }
        return String(value.prefix(max))
    }

    private static func optionalToken(_ text: String?, label: String, max: Int) throws -> String? {
        guard let text else { return nil }
        let value = tidy(text)
        if value.isEmpty { return nil }
        return try requireToken(value, label: label, max: max)
    }
}
