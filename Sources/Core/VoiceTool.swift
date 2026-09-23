import AppKit
import Foundation

/// The app installs one of these so the tool can drive a live session.
/// The CLI has no driver and asks the app over a distributed notification.
protocol VoiceDriver: AnyObject {
    var isListening: Bool { get }
    func setListening(_ listening: Bool) throws
}

/// Speech to text that types into the frontmost app.
///
/// Two separate switches. **Enabled** is the persisted master switch: it
/// arms the global shortcut and allows sessions. **Listening** is one live
/// session, started by the shortcut, the panel, or `yeobun voice start`.
/// Turning the tool off ends any session and unregisters the shortcut.
///
/// Only the menu-bar app captures audio, so the microphone prompt is
/// attributed to Yeobun and not to whichever terminal ran the CLI. The
/// persisted state carries the session flag, the preferences, and the last
/// failure reason so the CLI can report them.
final class VoiceTool: ToggleTool {
    let id: ToolID = .voice

    static let defaultSilenceSeconds = 30
    static let silenceChoices = [0, 15, 30, 60]

    weak var driver: VoiceDriver?

    struct Snapshot {
        var enabled: Bool
        var listening: Bool
        var locale: String
        var hotKey: HotKey
        var silenceSeconds: Int
        var typesText: Bool
        var vocabulary: [VoiceTerm]
        var notice: String
        var microphone: String
    }

    func snapshot() throws -> ToggleSnapshot {
        ToggleSnapshot(
            isOn: ToolStateStore.shared.current.voiceEnabled,
            remainingSeconds: nil,
            remainingMinutes: nil
        )
    }

    func hardwareSnapshot() -> Snapshot {
        let state = ToolStateStore.shared.current
        return Snapshot(
            enabled: state.voiceEnabled,
            listening: driver?.isListening ?? state.voiceListening,
            locale: state.voiceLocale,
            hotKey: state.voiceHotKey,
            silenceSeconds: state.voiceSilenceSeconds,
            typesText: state.voiceTypesText,
            vocabulary: state.voiceVocabulary,
            notice: state.voiceNotice,
            microphone: state.voiceMicrophone
        )
    }

    func setEnabled(_ enabled: Bool, options _: ToolOptions) throws {
        turn(enabled)
    }

    /// The master switch. The app watches the store and arms or drops the shortcut.
    func turn(_ enabled: Bool) {
        if !enabled {
            try? driver?.setListening(false)
        }
        ToolStateStore.shared.update { state in
            state.voiceEnabled = enabled
            if !enabled {
                state.voiceNotice = ""
            }
        }
        ToolStateStore.shared.notifyChange()
    }

    /// One live session. Only works while the tool is enabled.
    func setListening(_ listening: Bool) throws {
        if listening, !ToolStateStore.shared.current.voiceEnabled {
            throw ToolError.failed("Voice typing is off. Turn it on first: yeobun voice on")
        }
        if let driver {
            try driver.setListening(listening)
            return
        }
        try askApp(listening)
    }

    /// The app watches the store and hands the new list to a live session.
    func setVocabulary(_ terms: [VoiceTerm]) {
        ToolStateStore.shared.update { $0.voiceVocabulary = VoiceVocabulary.clean(terms) }
        ToolStateStore.shared.notifyChange()
    }

    func restore() {
        // Never resume listening on launch. Clear a flag a crash left behind.
        guard driver != nil, ToolStateStore.shared.current.voiceListening else { return }
        ToolStateStore.shared.update { $0.voiceListening = false }
    }

    static var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: YeobunPaths.appBundleIdentifier).isEmpty
    }

    private func askApp(_ enabled: Bool) throws {
        guard Self.isAppRunning else {
            throw ToolError.failed("Yeobun is not running. Open it from the menu bar, then try again.")
        }
        ToolStateStore.shared.update { $0.voiceNotice = "" }
        DistributedNotificationCenter.default().postNotificationName(
            YeobunPaths.voiceCommandNotification,
            object: enabled ? "on" : "off",
            userInfo: nil,
            deliverImmediately: true
        )
        // Permission prompts and model downloads take longer than this;
        // the tile keeps reporting progress after the CLI returns.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            usleep(100_000)
            ToolStateStore.shared.reload()
            let state = ToolStateStore.shared.current
            if state.voiceListening == enabled { return }
            if !state.voiceNotice.isEmpty {
                if state.voiceMicrophone == "denied" || state.voiceNotice.localizedCaseInsensitiveContains("allow") {
                    throw ToolError.permission(state.voiceNotice)
                }
                throw ToolError.failed(state.voiceNotice)
            }
        }
        if enabled {
            throw ToolError.failed("Yeobun has not started listening yet. Check Voice typing.")
        }
        throw ToolError.failed("Yeobun did not stop listening.")
    }
}
