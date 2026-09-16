import AppKit
import CoreGraphics
import Foundation

/// Types text into the frontmost app by pasting it, then puts the
/// pasteboard back. Needs Accessibility to post the ⌘V keystroke.
enum VoiceTextInserter {
    static var canType: Bool {
        AccessibilityAuth.hasPermission
    }

    /// `true` when Yeobun itself is in front, where a paste has nowhere to go.
    static var frontIsYeobun: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    private static var saved: [NSPasteboardItem]?
    private static var restoreWork: DispatchWorkItem?
    private static let restoreDelay: TimeInterval = 0.5

    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard canType, !text.isEmpty, !frontIsYeobun else { return false }
        let pasteboard = NSPasteboard.general
        restoreWork?.cancel()
        if saved == nil {
            saved = pasteboard.pasteboardItems?.compactMap(copy) ?? []
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        postPaste()
        let work = DispatchWorkItem { restoreSaved() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: work)
        return true
    }

    private static func restoreSaved() {
        guard let items = saved else { return }
        saved = nil
        restoreWork = nil
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func copy(_ item: NSPasteboardItem) -> NSPasteboardItem? {
        let copy = NSPasteboardItem()
        var any = false
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(data, forType: type)
                any = true
            }
        }
        return any ? copy : nil
    }

    private static func postPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
