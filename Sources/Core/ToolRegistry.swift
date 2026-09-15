import Foundation

final class ToolRegistry {
    static let shared = ToolRegistry()

    let keyboard = KeyboardTool()
    let scroll = ScrollTool()
    let lid = LidTool()
    let awake = AwakeTool()
    let menuBar = MenuBarTool()

    var toggles: [any ToggleTool] {
        [keyboard, scroll, lid, awake, menuBar]
    }

    func toggle(_ id: ToolID) -> any ToggleTool {
        switch id {
        case .keyboard: keyboard
        case .scroll: scroll
        case .lid: lid
        case .awake: awake
        case .menuBar: menuBar
        case .machine, .battery, .network, .storage:
            preconditionFailure("\(id.rawValue) is informational")
        }
    }

    func restoreAll() {
        for tool in toggles {
            tool.restore()
        }
    }
}
