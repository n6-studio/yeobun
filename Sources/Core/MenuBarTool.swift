import Foundation

enum MenuBarStripLayout: String, CaseIterable, Identifiable, Codable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        }
    }
}

/// Hides menu-bar icons behind a chevron, the way Ice and Hidden Bar do.
///
/// The status items themselves live in the menu-bar app (`MenuBarHider`);
/// this tool only owns the persisted intent so the CLI and the app agree.
/// Turning it on from the CLI writes the state and pings the app, which
/// creates the chevron and the off-screen spacer.
final class MenuBarTool: ToggleTool {
    let id: ToolID = .menuBar

    static let hiddenSize = 0
    static let iconSizeChoices = [20, 24, 32, hiddenSize]
    static let labelSizeChoices = [9, 11, 13, hiddenSize]
    static let defaultIconSize = 32
    static let defaultLabelSize = 13

    /// `0` hides that part. Icons and labels cannot both be hidden.
    static func resolvedSizes(icon: Int, label: Int) -> (icon: Int, label: Int) {
        let icon = iconSizeChoices.contains(icon) ? icon : defaultIconSize
        var label = labelSizeChoices.contains(label) ? label : defaultLabelSize
        if icon == hiddenSize && label == hiddenSize {
            label = defaultLabelSize
        }
        return (icon, label)
    }

    struct Snapshot {
        var enabled: Bool
        var hidden: Bool
        var iconSize: Int
        var labelSize: Int
        var layout: MenuBarStripLayout
    }

    func snapshot() throws -> ToggleSnapshot {
        ToggleSnapshot(
            isOn: ToolStateStore.shared.current.menuBarHideEnabled,
            remainingSeconds: nil,
            remainingMinutes: nil
        )
    }

    func hardwareSnapshot() -> Snapshot {
        let state = ToolStateStore.shared.current
        return Snapshot(
            enabled: state.menuBarHideEnabled,
            hidden: state.menuBarHidden,
            iconSize: state.menuBarStripIconSize,
            labelSize: state.menuBarStripLabelSize,
            layout: state.menuBarStripLayout
        )
    }

    func setEnabled(_ enabled: Bool, options _: ToolOptions) throws {
        turn(enabled)
    }

    func turn(_ enabled: Bool) {
        ToolStateStore.shared.update { state in
            state.menuBarHideEnabled = enabled
            if enabled {
                state.menuBarHidden = true
            }
        }
        ToolStateStore.shared.notifyChange()
    }

    func setStripIconSize(_ size: Int) {
        ToolStateStore.shared.update { state in
            let resolved = Self.resolvedSizes(icon: size, label: state.menuBarStripLabelSize)
            state.menuBarStripIconSize = resolved.icon
            state.menuBarStripLabelSize = resolved.label
        }
        ToolStateStore.shared.notifyChange()
    }

    func setStripLabelSize(_ size: Int) {
        ToolStateStore.shared.update { state in
            let resolved = Self.resolvedSizes(icon: state.menuBarStripIconSize, label: size)
            state.menuBarStripIconSize = resolved.icon
            state.menuBarStripLabelSize = resolved.label
        }
        ToolStateStore.shared.notifyChange()
    }

    func setStripLayout(_ layout: MenuBarStripLayout) {
        ToolStateStore.shared.update { $0.menuBarStripLayout = layout }
        ToolStateStore.shared.notifyChange()
    }

    func restore() {
        // Nothing to re-apply here: the app rebuilds its status items from the store.
    }
}
