import Darwin
import Foundation

struct ToolState: Codable, Equatable {
    var autoUnlockMinutes: Int = 0
    var dimKeyboardWhenLocked: Bool = true
    var keyboardLocked: Bool = false
    var keyboardLockBoot: TimeInterval = 0
    var scrollReverseEnabled: Bool = false
    var scrollReverseByDevice: [String: Bool] = [:]
    var lidSleepDisabled: Bool = false
    var awakeEnabled: Bool = false
    var awakeMinutes: Int = 0
    var awakeDeadline: TimeInterval?
    var caffeinatePID: Int = 0
    var scrollHelperPID: Int = 0
    var menuBarHideEnabled: Bool = false
    var menuBarHidden: Bool = true
    var menuBarStripIconSize: Int = 24
    var menuBarStripLabelSize: Int = 9
    var menuBarStripLayout: MenuBarStripLayout = .grid
    /// Written by the app while a voice session is live; the CLI only reads it.
    var voiceListening: Bool = false
    /// Locale identifier, empty for the system language.
    var voiceLocale: String = ""
    var voiceHotKey: HotKey = .defaultVoice
    var voiceSilenceSeconds: Int = VoiceTool.defaultSilenceSeconds
    var voiceTypesText: Bool = true
    /// Last reason a session could not start, for the CLI. Empty when fine.
    var voiceNotice: String = ""
    /// "granted", "denied", or "" while unknown. The app writes it; the CLI
    /// cannot ask TCC on Yeobun's behalf.
    var voiceMicrophone: String = ""
    var keyboardBacklightDidForce: Bool = false
    var keyboardBacklightSavedBrightness: Float = 0
    var keyboardBacklightSavedAuto: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoUnlockMinutes = try container.decodeIfPresent(Int.self, forKey: .autoUnlockMinutes) ?? 0
        dimKeyboardWhenLocked = try container.decodeIfPresent(Bool.self, forKey: .dimKeyboardWhenLocked) ?? true
        keyboardLocked = try container.decodeIfPresent(Bool.self, forKey: .keyboardLocked) ?? false
        keyboardLockBoot = try container.decodeIfPresent(TimeInterval.self, forKey: .keyboardLockBoot) ?? 0
        scrollReverseEnabled = try container.decodeIfPresent(Bool.self, forKey: .scrollReverseEnabled) ?? false
        scrollReverseByDevice = try container.decodeIfPresent([String: Bool].self, forKey: .scrollReverseByDevice) ?? [:]
        lidSleepDisabled = try container.decodeIfPresent(Bool.self, forKey: .lidSleepDisabled) ?? false
        awakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .awakeEnabled) ?? false
        awakeMinutes = try container.decodeIfPresent(Int.self, forKey: .awakeMinutes) ?? 0
        awakeDeadline = try container.decodeIfPresent(TimeInterval.self, forKey: .awakeDeadline)
        caffeinatePID = try container.decodeIfPresent(Int.self, forKey: .caffeinatePID) ?? 0
        scrollHelperPID = try container.decodeIfPresent(Int.self, forKey: .scrollHelperPID) ?? 0
        menuBarHideEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarHideEnabled) ?? false
        menuBarHidden = try container.decodeIfPresent(Bool.self, forKey: .menuBarHidden) ?? true
        menuBarStripIconSize = try container.decodeIfPresent(Int.self, forKey: .menuBarStripIconSize) ?? 24
        menuBarStripLabelSize = try container.decodeIfPresent(Int.self, forKey: .menuBarStripLabelSize) ?? 9
        menuBarStripLayout = try container.decodeIfPresent(MenuBarStripLayout.self, forKey: .menuBarStripLayout) ?? .grid
        let sizes = MenuBarTool.resolvedSizes(icon: menuBarStripIconSize, label: menuBarStripLabelSize)
        menuBarStripIconSize = sizes.icon
        menuBarStripLabelSize = sizes.label
        voiceListening = try container.decodeIfPresent(Bool.self, forKey: .voiceListening) ?? false
        voiceLocale = try container.decodeIfPresent(String.self, forKey: .voiceLocale) ?? ""
        voiceHotKey = try container.decodeIfPresent(HotKey.self, forKey: .voiceHotKey) ?? .defaultVoice
        let silence = try container.decodeIfPresent(Int.self, forKey: .voiceSilenceSeconds) ?? VoiceTool.defaultSilenceSeconds
        voiceSilenceSeconds = VoiceTool.silenceChoices.contains(silence) ? silence : VoiceTool.defaultSilenceSeconds
        voiceTypesText = try container.decodeIfPresent(Bool.self, forKey: .voiceTypesText) ?? true
        voiceNotice = try container.decodeIfPresent(String.self, forKey: .voiceNotice) ?? ""
        voiceMicrophone = try container.decodeIfPresent(String.self, forKey: .voiceMicrophone) ?? ""
        keyboardBacklightDidForce = try container.decodeIfPresent(Bool.self, forKey: .keyboardBacklightDidForce) ?? false
        keyboardBacklightSavedBrightness = try container.decodeIfPresent(Float.self, forKey: .keyboardBacklightSavedBrightness) ?? 0
        keyboardBacklightSavedAuto = try container.decodeIfPresent(Bool.self, forKey: .keyboardBacklightSavedAuto) ?? false
        if menuBarHideEnabled {
            menuBarHidden = true
        }
    }
}

final class ToolStateStore {
    static let shared = ToolStateStore()

    private let lock = NSLock()
    private var state: ToolState

    private init() {
        YeobunPaths.migrateLegacySupportIfNeeded()
        state = Self.loadFromDisk()
        Self.ensureDirectory()
        if !FileManager.default.fileExists(atPath: YeobunPaths.stateFile.path) {
            Self.write(state)
        }
    }

    var current: ToolState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func reload() {
        let loaded = Self.loadFromDisk()
        lock.lock()
        state = loaded
        lock.unlock()
    }

    /// Read-modify-write against the file, so the app and the CLI cannot
    /// overwrite each other's fields with a stale in-memory copy.
    func update(_ body: (inout ToolState) -> Void) {
        lock.lock()
        if let fresh = Self.decodeFromDisk() {
            state = fresh
        }
        body(&state)
        let snapshot = state
        lock.unlock()
        Self.write(snapshot)
    }

    func notifyChange() {
        let pid = "\(getpid())"
        DistributedNotificationCenter.default().postNotificationName(
            YeobunPaths.stateDidChangeNotification,
            object: pid,
            userInfo: nil,
            deliverImmediately: true
        )
        DistributedNotificationCenter.default().postNotificationName(
            YeobunPaths.scrollReloadNotification,
            object: pid,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: YeobunPaths.applicationSupport,
            withIntermediateDirectories: true
        )
    }

    private static func loadFromDisk() -> ToolState {
        decodeFromDisk() ?? migrateFromUserDefaults()
    }

    private static func decodeFromDisk() -> ToolState? {
        guard let data = try? Data(contentsOf: YeobunPaths.stateFile) else { return nil }
        return try? JSONDecoder().decode(ToolState.self, from: data)
    }

    private static func write(_ state: ToolState) {
        ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: YeobunPaths.stateFile, options: .atomic)
    }

    private static func migrateFromUserDefaults() -> ToolState {
        let defaults = UserDefaults.standard
        var state = ToolState()
        if defaults.object(forKey: "autoUnlockMinutes") != nil {
            state.autoUnlockMinutes = defaults.integer(forKey: "autoUnlockMinutes")
        }
        if defaults.object(forKey: "dimKeyboardWhenLocked") != nil {
            state.dimKeyboardWhenLocked = defaults.bool(forKey: "dimKeyboardWhenLocked")
        }
        state.keyboardLocked = defaults.bool(forKey: "keyboardLocked")
        state.keyboardLockBoot = defaults.double(forKey: "keyboardLockBoot")
        state.scrollReverseEnabled = defaults.bool(forKey: "scrollReverseEnabled")
        if let stored = defaults.dictionary(forKey: "scrollReverseByDevice") {
            state.scrollReverseByDevice = stored.reduce(into: [:]) { result, pair in
                if let flag = pair.value as? Bool {
                    result[pair.key] = flag
                } else if let number = pair.value as? NSNumber {
                    result[pair.key] = number.boolValue
                }
            }
        }
        state.lidSleepDisabled = defaults.bool(forKey: "lidSleepDisabled")
        state.awakeEnabled = defaults.bool(forKey: "awakeEnabled")
        let storedAwakeMinutes = defaults.object(forKey: "awakeMinutes") as? Int ?? 0
        state.awakeMinutes = [0, 5, 10, 15, 30, 60, 120, 300].contains(storedAwakeMinutes)
            ? storedAwakeMinutes
            : 0
        let deadline = defaults.double(forKey: "awakeDeadline")
        state.awakeDeadline = deadline > 0 ? deadline : nil
        state.caffeinatePID = defaults.integer(forKey: "caffeinatePID")
        state.keyboardBacklightDidForce = defaults.bool(forKey: "keyboardBacklightDidForce")
        if let number = defaults.object(forKey: "keyboardBacklightSavedBrightness") as? NSNumber {
            state.keyboardBacklightSavedBrightness = number.floatValue
        }
        state.keyboardBacklightSavedAuto = defaults.bool(forKey: "keyboardBacklightSavedAuto")
        return state
    }
}
