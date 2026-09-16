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
        var listening: Bool
        var locale: String
        var hotKey: HotKey
        var silenceSeconds: Int
        var typesText: Bool
        var notice: String
        var microphone: String
    }

    func snapshot() throws -> ToggleSnapshot {
        ToggleSnapshot(
            isOn: driver?.isListening ?? ToolStateStore.shared.current.voiceListening,
            remainingSeconds: nil,
            remainingMinutes: nil
        )
    }

    func hardwareSnapshot() -> Snapshot {
        let state = ToolStateStore.shared.current
        return Snapshot(
            listening: driver?.isListening ?? state.voiceListening,
            locale: state.voiceLocale,
            hotKey: state.voiceHotKey,
            silenceSeconds: state.voiceSilenceSeconds,
            typesText: state.voiceTypesText,
            notice: state.voiceNotice,
            microphone: state.voiceMicrophone
        )
    }

    func setEnabled(_ enabled: Bool, options _: ToolOptions) throws {
        if let driver {
            try driver.setListening(enabled)
            return
        }
        try askApp(enabled)
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
            throw ToolError.failed("Yeobun has not started listening yet. Check the Voice typing tile.")
        }
        throw ToolError.failed("Yeobun did not stop listening.")
    }
}
