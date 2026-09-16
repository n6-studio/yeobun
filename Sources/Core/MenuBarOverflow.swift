import AppKit
import CoreGraphics
import Foundation

/// A status item window as the window server reports it.
///
/// Coordinates are Core Graphics screen coordinates: origin at the top-left
/// of the primary display, y growing downward.
struct MenuBarItemWindow: Equatable, Identifiable {
    var id: CGWindowID
    var ownerPID: pid_t
    var ownerName: String
    var bounds: CGRect
    var isOnscreen: Bool
}

/// Finds status items that macOS itself has pushed out of the menu bar.
///
/// When the bar runs out of room (a notch display, or a wide app menu) macOS
/// keeps the items' windows but leaves them off screen. They can be listed
/// through the window list without any permission. On macOS 26 every status
/// item window is owned by Control Centre, so the owner name is not the app.
enum MenuBarOverflow {
    /// Items far wider than this are hider dividers (Yeobun, Ice, Hidden Bar).
    private static let maxItemWidth: CGFloat = 600
    private static let minItemWidth: CGFloat = 6
    private static let itemHeightRange: ClosedRange<CGFloat> = 16...48

    /// Every status item window, in menu-bar order (left to right).
    static func statusItemWindows() -> [MenuBarItemWindow] {
        menuBarWindows().filter { $0.bounds.width >= minItemWidth && $0.bounds.width <= maxItemWidth }
    }

    /// Very wide status windows: hider dividers, and on macOS 26 the system's
    /// own off-screen container that holds the icons it tucked away.
    static func overflowContainers() -> [MenuBarItemWindow] {
        menuBarWindows().filter { $0.bounds.width > maxItemWidth }
    }

    private static func menuBarWindows() -> [MenuBarItemWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let bands = topBands()
        var items: [MenuBarItemWindow] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == Int(CGWindowLevelForKey(.statusWindow)),
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            guard itemHeightRange.contains(bounds.height) else { continue }
            // Menu-bar items sit in a screen's top band; skip stray panels.
            guard bands.contains(where: { band in
                bounds.minY >= band.minY - 4 && bounds.maxY <= band.maxY + 8
            }) else { continue }
            items.append(MenuBarItemWindow(
                id: id,
                ownerPID: pid_t(info[kCGWindowOwnerPID as String] as? Int ?? 0),
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bounds: bounds,
                isOnscreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false
            ))
        }
        return items.sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// `true` when a status item is missing, off, or sitting outside the
    /// visible stretch of the menu bar (tucked by macOS or by a hider).
    static func isOffMenuBar(_ item: NSStatusItem) -> Bool {
        guard item.isVisible, let window = item.button?.window, window.frame.width > 0.5 else {
            return true
        }
        return placement(of: toCG(window.frame)) != .visible
    }

    /// Items that are not fully inside a visible stretch of any menu bar.
    static func hiddenByMacOS() -> [MenuBarItemWindow] {
        let bands = visibleBands()
        return statusItemWindows().filter { item in
            if !item.isOnscreen { return true }
            return !bands.contains { band in
                item.bounds.minX >= band.minX - 0.5
                    && item.bounds.maxX <= band.maxX + 0.5
                    && item.bounds.minY < band.maxY
                    && item.bounds.maxY > band.minY
            }
        }
    }

    /// Where a rect sits relative to the menu bars.
    enum Placement {
        /// Inside a stretch of menu bar that can show items.
        case visible
        /// In a menu bar's row but outside the visible stretch: a hider's doing.
        case offscreen
        /// Not in any menu bar row: the app removed the item from the bar.
        case removed
    }

    static func placement(of rect: CGRect) -> Placement {
        guard rect.width > 0.5, rect.height > 0.5 else { return .removed }
        let row = topBands().contains { band in
            rect.minY >= band.minY - 4 && rect.maxY <= band.maxY + 8
        }
        guard row else { return .removed }
        let visible = visibleBands().contains { band in
            rect.minX >= band.minX - 0.5 && rect.maxX <= band.maxX + 0.5
        }
        return visible ? .visible : .offscreen
    }

    // MARK: - Geometry

    /// The full-width menu-bar band of every screen, in CG coordinates.
    private static func topBands() -> [CGRect] {
        NSScreen.screens.map { screen in
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
            let cocoa = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            return toCG(cocoa)
        }
    }

    /// Stretches of menu bar that can actually show items. On a notch display
    /// that is the area right of the notch; the left one holds app menus.
    private static func visibleBands() -> [CGRect] {
        NSScreen.screens.flatMap { screen -> [CGRect] in
            if let right = screen.auxiliaryTopRightArea {
                var bands = [toCG(right)]
                if let left = screen.auxiliaryTopLeftArea {
                    bands.append(toCG(left))
                }
                return bands
            }
            let height = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
            let cocoa = CGRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: screen.frame.width, height: height)
            return [toCG(cocoa)]
        }
    }

    /// Cocoa (bottom-left origin) to CG (top-left origin of the primary display).
    static func toCG(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// CG to Cocoa.
    static func toCocoa(_ rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
