import Foundation

struct KeyboardStatusJSON: Encodable {
    var locked: Bool
    var remainingMinutes: Int?
    var dim: Bool

    enum CodingKeys: String, CodingKey { case locked, remainingMinutes, dim }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(locked, forKey: .locked)
        try container.encode(remainingMinutes, forKey: .remainingMinutes)
        try container.encode(dim, forKey: .dim)
    }
}

struct ScrollMouseJSON: Encodable {
    var id: String
    var name: String
    var enabled: Bool
}

struct ScrollStatusJSON: Encodable {
    var enabled: Bool
    var active: Bool
    var accessibility: Bool
    var mice: [ScrollMouseJSON]
}

struct LidStatusJSON: Encodable {
    var disabled: Bool
}

struct AwakeStatusJSON: Encodable {
    var active: Bool
    var remainingSeconds: Int?

    enum CodingKeys: String, CodingKey { case active, remainingSeconds }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(remainingSeconds, forKey: .remainingSeconds)
    }
}

struct MenuBarStatusJSON: Encodable {
    var enabled: Bool
    var hidden: Bool
    var iconSize: Int
    var labelSize: Int
    var layout: String
    /// Status items the system left off screen right now (any hider's included).
    var offscreenItems: Int
}

struct VoiceStatusJSON: Encodable {
    /// Master switch: the shortcut is registered and sessions are allowed.
    var enabled: Bool
    var listening: Bool
    var locale: String
    var hotkey: String
    var silenceSeconds: Int
    var typesText: Bool
    var vocabulary: [VoiceTerm]
    var accessibility: Bool
    /// "granted", "denied", or "" until the app has asked.
    var microphone: String
    var notice: String
}

struct MacStatusJSON: Encodable {
    var cpuPercent: Int
    var ramUsedBytes: UInt64
    var ramTotalBytes: UInt64
    var ramCompressedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    var memoryPressure: String
    var thermal: String
    var uptimeSeconds: Int
    var powerWatts: Double?
    var batteryPercent: Int?
    var batteryCharging: Bool?
    var lowPowerMode: Bool?
    var diskUsedBytes: UInt64?
    var diskTotalBytes: UInt64?
    var networkKind: String
    var networkIP: String?
    var networkDownBytesPerSecond: UInt64
    var networkUpBytesPerSecond: UInt64
    var accessories: [AccessoryBatteryJSON]
    var processes: [ProcessJSON]
}

struct LocationServiceJSON: Encodable {
    var name: String
    var enabled: Bool
    /// Typed into the location. Empty means DNS comes from the network.
    var dnsServers: [String]
    var searchDomains: [String]
}

struct LocationJSON: Encodable {
    var id: String
    var name: String
    var current: Bool
    var services: [LocationServiceJSON]
}

struct DNSInUseJSON: Encodable {
    var service: String?
    var interface: String?
    var servers: [String]
    var searchDomains: [String]
    /// "location" when the current location sets the servers, "network" when DHCP does.
    var source: String
    /// System default resolver. A VPN can differ from the service.
    var resolverServers: [String]
    var resolverSearchDomains: [String]
}

struct LocationRuleJSON: Encodable {
    var wifi: String
    var location: String
    var locationId: String
}

struct LocationAutoJSON: Encodable {
    var enabled: Bool
    var rules: [LocationRuleJSON]
    /// Location for a Wi-Fi without a rule. Nil keeps the current one.
    var otherwise: String?
    var otherwiseId: String?

    enum CodingKeys: String, CodingKey { case enabled, rules, otherwise, otherwiseId }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(rules, forKey: .rules)
        try container.encode(otherwise, forKey: .otherwise)
        try container.encode(otherwiseId, forKey: .otherwiseId)
    }
}

struct LocationStatusJSON: Encodable {
    var current: String?
    var locations: [LocationJSON]
    var dns: DNSInUseJSON?
    var auto: LocationAutoJSON
}

struct AccessoryBatteryJSON: Encodable {
    var name: String
    var percent: Int
}

struct ProcessJSON: Encodable {
    var name: String
    var cpuPercent: Int
    var ramBytes: UInt64
}

struct ToolsSnapshot: Encodable {
    var keyboard: KeyboardStatusJSON
    var scroll: ScrollStatusJSON
    var lid: LidStatusJSON
    var awake: AwakeStatusJSON
    var menubar: MenuBarStatusJSON
    var voice: VoiceStatusJSON
    var remotes: [RemoteConfigJSON]
    var location: LocationStatusJSON
    var mac: MacStatusJSON?
}

struct RemoteConfigJSON: Encodable {
    var id: String
    var name: String
    var host: String
    var user: String?
    var port: Int?
    var identity: String?
}

struct RemoteStatusJSON: Encodable {
    var id: String
    var name: String
    var host: String
    var status: String
    var notice: String?
    var cpuPercent: Int?
    var ramUsedBytes: UInt64?
    var ramTotalBytes: UInt64?
    var load1: Double?
    var load5: Double?
    var load15: Double?
    var uptimeSeconds: Int?
    var diskUsedBytes: UInt64?
    var diskTotalBytes: UInt64?
    var powerWatts: Double?
}

enum StatusBuilder {
    static func make(includeMac: Bool) -> ToolsSnapshot {
        let tools = ToolRegistry.shared
        let store = ToolStateStore.shared.current
        let keyboard = (try? tools.keyboard.hardwareSnapshot())
            ?? .init(locked: false, remainingMinutes: nil)
        let mice = DeviceMonitor.listMiceOnce()
        let lid = tools.lid.hardwareSnapshot()
        let awake = tools.awake.hardwareSnapshot()
        let menuBar = tools.menuBar.hardwareSnapshot()
        let voice = tools.voice.hardwareSnapshot()
        return ToolsSnapshot(
            keyboard: KeyboardStatusJSON(
                locked: keyboard.locked,
                remainingMinutes: keyboard.remainingMinutes,
                dim: store.dimKeyboardWhenLocked
            ),
            scroll: ScrollStatusJSON(
                enabled: store.scrollReverseEnabled,
                active: ScrollHelperController.shared.isRunning,
                accessibility: AccessibilityAuth.hasPermission,
                mice: mice.map { mouse in
                    ScrollMouseJSON(
                        id: mouse.id,
                        name: mouse.name,
                        enabled: store.scrollReverseByDevice[mouse.id] ?? true
                    )
                }
            ),
            lid: LidStatusJSON(disabled: lid.disabled),
            awake: AwakeStatusJSON(
                active: awake.active,
                remainingSeconds: awake.remainingSeconds
            ),
            menubar: MenuBarStatusJSON(
                enabled: menuBar.enabled,
                hidden: menuBar.hidden,
                iconSize: menuBar.iconSize,
                labelSize: menuBar.labelSize,
                layout: menuBar.layout.rawValue,
                offscreenItems: MenuBarOverflow.hiddenByMacOS().count
            ),
            voice: VoiceStatusJSON(
                enabled: voice.enabled,
                listening: voice.listening,
                locale: voice.locale,
                hotkey: voice.hotKey.display,
                silenceSeconds: voice.silenceSeconds,
                typesText: voice.typesText,
                vocabulary: voice.vocabulary,
                accessibility: AccessibilityAuth.hasPermission,
                microphone: voice.microphone,
                notice: voice.notice
            ),
            remotes: RemoteCatalog.current().map { server in
                RemoteConfigJSON(
                    id: server.id.uuidString,
                    name: server.name,
                    host: server.host,
                    user: server.user,
                    port: server.port,
                    identity: server.identityPath
                )
            },
            location: locationStatus(),
            mac: includeMac ? macStatus() : nil
        )
    }

    static func locationStatus(_ snapshot: NetworkLocationSnapshot = NetworkLocations.snapshot()) -> LocationStatusJSON {
        let state = ToolStateStore.shared.current
        func name(_ id: String?, fallback: String?) -> String? {
            guard let id else { return nil }
            return snapshot.locations.first { $0.id == id }?.name ?? fallback
        }
        return LocationStatusJSON(
            current: snapshot.current?.name,
            locations: snapshot.locations.map { location in
                LocationJSON(
                    id: location.id,
                    name: location.name,
                    current: location.id == snapshot.currentID,
                    services: location.services.map {
                        LocationServiceJSON(
                            name: $0.name,
                            enabled: $0.enabled,
                            dnsServers: $0.servers,
                            searchDomains: $0.searchDomains
                        )
                    }
                )
            },
            dns: snapshot.dns.map { dns in
                DNSInUseJSON(
                    service: dns.serviceName,
                    interface: dns.interface,
                    servers: dns.servers,
                    searchDomains: dns.searchDomains,
                    source: dns.setByLocation ? "location" : "network",
                    resolverServers: dns.resolverServers,
                    resolverSearchDomains: dns.resolverSearchDomains
                )
            },
            auto: LocationAutoJSON(
                enabled: state.locationAutoSwitch,
                rules: state.locationRules.map {
                    LocationRuleJSON(
                        wifi: $0.wifi,
                        location: name($0.locationID, fallback: $0.locationName) ?? $0.locationName,
                        locationId: $0.locationID
                    )
                },
                otherwise: name(state.locationOtherwiseID, fallback: state.locationOtherwiseName),
                otherwiseId: state.locationOtherwiseID
            )
        )
    }

    static func macStatus() -> MacStatusJSON {
        let sample = SystemStatsService().sampleOnce()
        return MacStatusJSON(
            cpuPercent: sample.cpuReady ? Int((sample.cpuFraction * 100).rounded()) : 0,
            ramUsedBytes: sample.ramUsed,
            ramTotalBytes: sample.ramTotal,
            ramCompressedBytes: sample.ramCompressed,
            swapUsedBytes: sample.swapUsed,
            swapTotalBytes: sample.swapTotal,
            memoryPressure: sample.memoryPressure.label.lowercased(),
            thermal: StatsFormat.thermal(sample.thermal).lowercased(),
            uptimeSeconds: Int(sample.uptimeSeconds.rounded(.down)),
            powerWatts: roundWatts(sample.powerWatts),
            batteryPercent: sample.battery.map { Int(($0.percent * 100).rounded()) },
            batteryCharging: sample.battery?.isCharging,
            lowPowerMode: sample.battery?.isLowPowerMode,
            diskUsedBytes: sample.bootVolume?.used,
            diskTotalBytes: sample.bootVolume?.total,
            networkKind: sample.network.kind.lowercased(),
            networkIP: sample.network.ipAddress,
            networkDownBytesPerSecond: sample.network.bytesInPerSecond,
            networkUpBytesPerSecond: sample.network.bytesOutPerSecond,
            accessories: sample.accessories.map {
                AccessoryBatteryJSON(name: $0.name, percent: $0.percent)
            },
            processes: sample.topProcesses.map {
                ProcessJSON(
                    name: $0.name,
                    cpuPercent: Int($0.cpuPercent.rounded()),
                    ramBytes: $0.ramBytes
                )
            }
        )
    }

    static func remoteStatus(_ server: RemoteServer, sample: RemoteSample) -> RemoteStatusJSON {
        let live = sample.status == .ok
        return RemoteStatusJSON(
            id: server.id.uuidString,
            name: server.name,
            host: server.host,
            status: sample.status.rawValue,
            notice: sample.notice,
            cpuPercent: live && sample.cpuReady ? Int((sample.cpuFraction * 100).rounded()) : nil,
            ramUsedBytes: live && sample.ramTotal > 0 ? sample.ramUsed : nil,
            ramTotalBytes: live && sample.ramTotal > 0 ? sample.ramTotal : nil,
            load1: live ? sample.load1 : nil,
            load5: live ? sample.load5 : nil,
            load15: live ? sample.load15 : nil,
            uptimeSeconds: live && sample.uptimeSeconds > 0 ? Int(sample.uptimeSeconds.rounded(.down)) : nil,
            diskUsedBytes: live && sample.diskTotal > 0 ? sample.diskUsed : nil,
            diskTotalBytes: live && sample.diskTotal > 0 ? sample.diskTotal : nil,
            powerWatts: live ? roundWatts(sample.powerWatts) : nil
        )
    }

    static func jsonString(_ snapshot: ToolsSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func roundWatts(_ watts: Double?) -> Double? {
        watts.map { ($0 * 10).rounded() / 10 }
    }
}
