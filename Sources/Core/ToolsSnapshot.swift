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
    var batteryPercent: Int?
    var batteryCharging: Bool?
    var diskUsedBytes: UInt64?
    var diskTotalBytes: UInt64?
    var networkKind: String
    var networkIP: String?
    var networkDownBytesPerSecond: UInt64
    var networkUpBytesPerSecond: UInt64
    var accessories: [AccessoryBatteryJSON]
    var processes: [ProcessJSON]
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
    var mac: MacStatusJSON?
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
            mac: includeMac ? macStatus() : nil
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
            batteryPercent: sample.battery.map { Int(($0.percent * 100).rounded()) },
            batteryCharging: sample.battery?.isCharging,
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

    static func jsonString(_ snapshot: ToolsSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
