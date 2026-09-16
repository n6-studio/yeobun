import AppKit
import Carbon
import SwiftUI

/// One system-wide shortcut through Carbon's hot-key API. No permission needed.
final class VoiceHotKeyService {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x5945_4F42 // 'YEOB'

    func register(_ hotKey: HotKey) {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(hotKey.keyCode),
            UInt32(hotKey.modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard id.signature == VoiceHotKeyService.signature else { return noErr }
                let service = Unmanaged<VoiceHotKeyService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.onPress?()
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &handlerRef
        )
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

extension HotKey {
    /// A recorded key press, or nil when it is a bare letter with no modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers = 0
        if flags.contains(.command) { modifiers |= HotKey.command }
        if flags.contains(.shift) { modifiers |= HotKey.shift }
        if flags.contains(.option) { modifiers |= HotKey.option }
        if flags.contains(.control) { modifiers |= HotKey.control }
        let code = Int(event.keyCode)
        guard modifiers != 0 || HotKey.isStandaloneKey(code) else { return nil }
        self.init(keyCode: code, modifiers: modifiers)
    }
}

/// A button that shows the shortcut and records a new one on click.
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey
    var onRecordingChanged: (Bool) -> Void = { _ in }

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if hotKey != .defaultVoice, !recording {
                Button("Reset") {
                    hotKey = .defaultVoice
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Button(recording ? "Press keys…" : hotKey.display) {
                if recording {
                    end()
                } else {
                    begin()
                }
            }
            .controlSize(.small)
            .frame(minWidth: 72)
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(hotKey.display)")
        }
        .onDisappear { end() }
    }

    private func begin() {
        recording = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                end()
                return nil
            }
            if let key = HotKey(event: event) {
                hotKey = key
                end()
            }
            return nil
        }
    }

    private func end() {
        guard recording else { return }
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        onRecordingChanged(false)
    }
}
