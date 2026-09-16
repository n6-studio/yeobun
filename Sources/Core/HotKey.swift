import Foundation

/// A global keyboard shortcut, stored as a macOS virtual key code plus
/// Carbon modifier bits so the app can hand it straight to `RegisterEventHotKey`.
struct HotKey: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int

    static let command = 0x0100
    static let shift = 0x0200
    static let option = 0x0800
    static let control = 0x1000

    /// ⌃⌥V. macOS uses ⌃Space and ⌃⌥Space for input sources, so stay clear of those.
    static let defaultVoice = HotKey(keyCode: 9, modifiers: control | option)

    var hasModifier: Bool {
        modifiers & (Self.command | Self.shift | Self.option | Self.control) != 0
    }

    /// `⌃⌥V`, in the order macOS prints modifiers.
    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + Self.keyLabel(keyCode)
    }

    /// Labels for the ANSI layout. Unknown codes print as their number.
    static func keyLabel(_ code: Int) -> String {
        if let label = keyLabels[code] { return label }
        return "Key \(code)"
    }

    /// Keys that make sense on their own, without a modifier.
    static func isStandaloneKey(_ code: Int) -> Bool {
        functionKeys.contains(code)
    }

    private static let functionKeys: Set<Int> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106
    ]

    private static let keyLabels: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋", 76: "⌤",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        117: "⌦", 118: "F4", 120: "F2", 122: "F1", 115: "↖", 116: "⇞", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
