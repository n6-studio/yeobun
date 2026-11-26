import CoreWLAN
import Foundation
import SystemConfiguration

/// One network service (Wi-Fi, Ethernet, a VPN) inside a location, with the DNS
/// servers typed into that location. Empty `servers` means the service takes DNS
/// from the network it joins.
struct LocationNetworkService: Equatable, Identifiable {
    var id: String
    var name: String
    var enabled: Bool
    var servers: [String]
    var searchDomains: [String]
}

/// A macOS network location (an `SCNetworkSet`).
struct NetworkLocation: Equatable, Identifiable {
    var id: String
    var name: String
    var services: [LocationNetworkService]

    /// Enabled services that set their own DNS servers.
    var customDNS: [LocationNetworkService] {
        services.filter { $0.enabled && !$0.servers.isEmpty }
    }

    /// "Automatic" or the custom servers, for one line under the name.
    var dnsSummary: String {
        let custom = customDNS
        guard !custom.isEmpty else { return "DNS from network" }
        let servers = custom.flatMap(\.servers)
        var seen = Set<String>()
        let unique = servers.filter { seen.insert($0).inserted }
        return "DNS " + unique.joined(separator: ", ")
    }
}

/// DNS the Mac resolves with right now.
struct DNSInUse: Equatable {
    /// Primary service, e.g. Wi-Fi.
    var serviceName: String?
    var interface: String?
    /// Servers on the primary service: typed into the location, or handed out by the network.
    var servers: [String]
    var searchDomains: [String]
    var setByLocation: Bool
    /// The system-wide default resolver. A VPN such as Tailscale can put its own here.
    var resolverServers: [String]
    var resolverSearchDomains: [String]

    /// True when something other than the primary service answers by default.
    var resolverDiffers: Bool {
        !resolverServers.isEmpty && resolverServers != servers
    }
}

struct NetworkLocationSnapshot: Equatable {
    var locations: [NetworkLocation]
    var currentID: String?
    var dns: DNSInUse?

    static let empty = NetworkLocationSnapshot(locations: [], currentID: nil, dns: nil)

    var current: NetworkLocation? {
        locations.first { $0.id == currentID }
    }
}

struct NetworkLocationError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }

    var isCancelled = false
}

/// Reads locations from System Configuration. Switching uses `scselect`, which an
/// ordinary user may run. Adding and deleting a location go through `networksetup`
/// and need an administrator.
enum NetworkLocations {
    static let maxNameLength = 64

    static func snapshot() -> NetworkLocationSnapshot {
        guard let prefs = SCPreferencesCreate(nil, "Yeobun" as CFString, nil) else {
            return .empty
        }
        let sets = (SCNetworkSetCopyAll(prefs) as? [SCNetworkSet]) ?? []
        let currentID = SCNetworkSetCopyCurrent(prefs).flatMap { SCNetworkSetGetSetID($0) as String? }
        let locations = sets
            .compactMap(location(from:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let current = locations.first { $0.id == currentID }
        return NetworkLocationSnapshot(
            locations: locations,
            currentID: currentID,
            dns: dnsInUse(current: current)
        )
    }

    /// Finds a location by name (case-insensitive) or set ID.
    static func match(_ key: String, in locations: [NetworkLocation]) throws -> NetworkLocation {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let byID = locations.first(where: { $0.id == trimmed }) {
            return byID
        }
        let byName = locations.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 {
            throw NetworkLocationError("More than one location is called \(trimmed). Use its id.")
        }
        throw NetworkLocationError("No location called \(trimmed).")
    }

    static func switchTo(_ location: NetworkLocation) throws {
        let result = run("/usr/sbin/scselect", [location.id])
        guard result.status == 0 else {
            let detail = result.err.isEmpty ? result.out : result.err
            throw NetworkLocationError(
                detail.isEmpty ? "Unable to switch to \(location.name)." : detail
            )
        }
        guard snapshot().currentID == location.id else {
            throw NetworkLocationError("macOS did not switch to \(location.name).")
        }
    }

    /// Returns the cleaned name, or throws why it cannot be used.
    static func validatedName(_ raw: String, existing: [NetworkLocation]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NetworkLocationError("Name the location.") }
        guard name.count <= maxNameLength else {
            throw NetworkLocationError("Keep the name under \(maxNameLength) characters.")
        }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw NetworkLocationError("The name cannot contain line breaks or tabs.")
        }
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw NetworkLocationError("A location called \(name) already exists.")
        }
        return name
    }

    /// Creates a location with every current network service, like System Settings does.
    static func create(_ raw: String) throws -> String {
        let name = try validatedName(raw, existing: snapshot().locations)
        try runAsAdmin(["-createlocation", name, "populate"], action: "add \(name)")
        guard snapshot().locations.contains(where: { $0.name == name }) else {
            throw NetworkLocationError("macOS did not add \(name).")
        }
        return name
    }

    static func delete(_ location: NetworkLocation) throws {
        let current = snapshot()
        if current.currentID == location.id {
            throw NetworkLocationError("Switch to another location before deleting \(location.name).")
        }
        if current.locations.filter({ $0.name == location.name }).count > 1 {
            throw NetworkLocationError("More than one location is called \(location.name). Delete it in System Settings.")
        }
        try runAsAdmin(["-deletelocation", location.name], action: "delete \(location.name)")
        if snapshot().locations.contains(where: { $0.id == location.id }) {
            throw NetworkLocationError("macOS did not delete \(location.name).")
        }
    }

    // MARK: Reading

    private static func location(from set: SCNetworkSet) -> NetworkLocation? {
        guard let id = SCNetworkSetGetSetID(set) as String? else { return nil }
        let name = (SCNetworkSetGetName(set) as String?) ?? id
        let services = (SCNetworkSetCopyServices(set) as? [SCNetworkService]) ?? []
        let order = (SCNetworkSetGetServiceOrder(set) as? [String]) ?? []
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let mapped = services.compactMap(service(from:)).sorted {
            (rank[$0.id] ?? Int.max, $0.name) < (rank[$1.id] ?? Int.max, $1.name)
        }
        return NetworkLocation(id: id, name: name, services: mapped)
    }

    private static func service(from service: SCNetworkService) -> LocationNetworkService? {
        guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
        var servers: [String] = []
        var domains: [String] = []
        if let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS),
           let config = SCNetworkProtocolGetConfiguration(dns) as? [String: Any] {
            servers = config[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
            domains = config[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
        }
        return LocationNetworkService(
            id: id,
            name: (SCNetworkServiceGetName(service) as String?) ?? id,
            enabled: SCNetworkServiceGetEnabled(service),
            servers: servers,
            searchDomains: domains
        )
    }

    private static func dnsInUse(current: NetworkLocation?) -> DNSInUse? {
        guard let store = SCDynamicStoreCreate(nil, "Yeobun" as CFString, nil, nil) else { return nil }
        func value(_ key: String) -> [String: Any]? {
            SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
        }
        let global = value("State:/Network/Global/DNS")
        let resolverServers = global?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
        let resolverDomains = global?[kSCPropNetDNSSearchDomains as String] as? [String] ?? []

        let primary = value("State:/Network/Global/IPv4") ?? value("State:/Network/Global/IPv6")
        let serviceID = primary?["PrimaryService"] as? String
        let interface = primary?["PrimaryInterface"] as? String
        guard let serviceID else {
            if resolverServers.isEmpty { return nil }
            return DNSInUse(
                serviceName: nil,
                interface: nil,
                servers: [],
                searchDomains: [],
                setByLocation: false,
                resolverServers: resolverServers,
                resolverSearchDomains: resolverDomains
            )
        }
        let configured = current?.services.first { $0.id == serviceID }
        let state = value("State:/Network/Service/\(serviceID)/DNS")
        let fromNetwork = state?[kSCPropNetDNSServerAddresses as String] as? [String] ?? []
        var domains = configured?.searchDomains ?? []
        if domains.isEmpty {
            domains = state?[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
            if domains.isEmpty, let domain = state?[kSCPropNetDNSDomainName as String] as? String {
                domains = [domain]
            }
        }
        let manual = configured?.servers ?? []
        let setup = value("Setup:/Network/Service/\(serviceID)")
        return DNSInUse(
            serviceName: configured?.name ?? setup?[kSCPropUserDefinedName as String] as? String,
            interface: interface,
            servers: manual.isEmpty ? fromNetwork : manual,
            searchDomains: domains,
            setByLocation: !manual.isEmpty,
            resolverServers: resolverServers,
            resolverSearchDomains: resolverDomains
        )
    }

    // MARK: Running tools

    private static func runAsAdmin(_ arguments: [String], action: String) throws {
        let networksetup = "/usr/sbin/networksetup"
        if run(networksetup, arguments).status == 0 { return }
        if isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 {
            let status = runInteractive("/usr/bin/sudo", [networksetup] + arguments)
            guard status == 0 else {
                throw NetworkLocationError("Unable to \(action). Allow administrator access and try again.")
            }
            return
        }
        let command = ([networksetup] + arguments).map(shellQuoted).joined(separator: " ")
        let source = "do shell script \(appleScriptString(command)) with administrator privileges"
        // In process, so the prompt names Yeobun. NSAppleScript belongs on the main thread.
        var outcome: (output: String, number: Int, message: String?)?
        let body = {
            var errorInfo: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo).stringValue ?? ""
            if let errorInfo {
                outcome = (
                    output,
                    errorInfo[NSAppleScript.errorNumber] as? Int ?? 0,
                    errorInfo[NSAppleScript.errorMessage] as? String
                )
            } else {
                outcome = (output, 0, nil)
            }
        }
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.sync(execute: body)
        }
        guard let outcome else {
            throw NetworkLocationError("Unable to ask for administrator access.")
        }
        if outcome.number == -128 {
            var error = NetworkLocationError("Allow administrator access to \(action).")
            error.isCancelled = true
            throw error
        }
        if outcome.number != 0 {
            let detail = outcome.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NetworkLocationError(detail.isEmpty ? "Unable to \(action)." : detail)
        }
        // networksetup reports some failures on stdout with a zero exit status.
        if outcome.output.contains("** Error") {
            throw NetworkLocationError(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runInteractive(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        do {
            try process.run()
        } catch {
            return 1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return (1, "", error.localizedDescription)
        }
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        process.waitUntilExit()
        group.wait()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

/// "On this Wi-Fi, use this location." Matched by Wi-Fi name, ignoring case.
struct LocationRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var wifi: String
    var locationID: String
    /// Name when the rule was saved, shown if the location is deleted later.
    var locationName: String
}

enum LocationRules {
    /// Wi-Fi names are at most 32 bytes.
    static let maxWiFiBytes = 32
    static let maxCount = 32

    /// The Wi-Fi this Mac is joined to. macOS hides the name from apps
    /// without Location Services, so this is nil until Yeobun is allowed.
    static func currentWiFi() -> String? {
        guard let name = CWWiFiClient.shared().interface()?.ssid(), !name.isEmpty else { return nil }
        return name
    }

    static func rule(for wifi: String, in rules: [LocationRule]) -> LocationRule? {
        rules.first { $0.wifi == wifi } ?? rules.first { $0.wifi.caseInsensitiveCompare(wifi) == .orderedSame }
    }

    /// Adds a rule, or points an existing rule for the same Wi-Fi at the new location.
    static func adding(wifi raw: String, location: NetworkLocation, to rules: [LocationRule]) throws -> [LocationRule] {
        let wifi = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wifi.isEmpty else { throw NetworkLocationError("Name the Wi-Fi network.") }
        guard wifi.utf8.count <= maxWiFiBytes else {
            throw NetworkLocationError("Wi-Fi names are at most \(maxWiFiBytes) bytes.")
        }
        var next = rules
        let rule = LocationRule(wifi: wifi, locationID: location.id, locationName: location.name)
        if let index = next.firstIndex(where: { $0.wifi.caseInsensitiveCompare(wifi) == .orderedSame }) {
            next[index] = LocationRule(id: next[index].id, wifi: wifi, locationID: location.id, locationName: location.name)
        } else {
            guard next.count < maxCount else { throw NetworkLocationError("Up to \(maxCount) Wi-Fi rules.") }
            next.append(rule)
        }
        return next
    }

    static func removing(wifi raw: String, from rules: [LocationRule]) throws -> [LocationRule] {
        let wifi = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rules.contains(where: { $0.wifi.caseInsensitiveCompare(wifi) == .orderedSame }) else {
            throw NetworkLocationError("No rule for \(wifi).")
        }
        return rules.filter { $0.wifi.caseInsensitiveCompare(wifi) != .orderedSame }
    }

    /// The location to be on for this Wi-Fi, or nil to stay put.
    static func targetID(wifi: String, rules: [LocationRule], otherwiseID: String?) -> String? {
        rule(for: wifi, in: rules)?.locationID ?? otherwiseID
    }
}

/// Calls back when the current location, the DNS in use, or the Wi-Fi changes,
/// from System Settings, `scselect`, the CLI, or a network join.
final class NetworkLocationWatcher {
    var onChange: (() -> Void)?
    private var store: SCDynamicStore?
    private let queue = DispatchQueue(label: "studio.n6.yeobun.location.watch", qos: .utility)

    func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkLocationWatcher>.fromOpaque(info).takeUnretainedValue().onChange?()
        }
        guard let store = SCDynamicStoreCreate(nil, "Yeobun.location" as CFString, callback, &context) else {
            return
        }
        let keys = [
            "Setup:/",
            "State:/Network/Global/DNS",
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/DNS",
            "Setup:/Network/Service/.*/DNS",
            "State:/Network/Interface/[^/]+/AirPort"
        ] as CFArray
        SCDynamicStoreSetNotificationKeys(store, keys, patterns)
        SCDynamicStoreSetDispatchQueue(store, queue)
        self.store = store
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    deinit {
        stop()
    }
}
