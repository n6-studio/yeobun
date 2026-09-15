import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// One icon that is not in the menu bar right now, ready to draw and use.
struct OverflowItem: Identifiable, Equatable {
    var id: String
    /// Where the item reports itself, in CG screen coordinates.
    var bounds: CGRect
    var placement: MenuBarOverflow.Placement
    /// The window that draws it, when one exists.
    var captureWindow: MenuBarItemWindow?
    /// Snapshot of the real item, when Screen Recording is allowed.
    var image: NSImage?
    /// The owning app, when Accessibility lets us find it.
    var appName: String?
    /// What the item calls itself, when that differs from the app name.
    var detail: String?
    var appIcon: NSImage?
    var pid: pid_t?
    var element: AXUIElement?

    var label: String {
        if let appName { return appName }
        return "Hidden menu bar item"
    }

    var tooltip: String {
        var parts = [label]
        if let detail, detail.caseInsensitiveCompare(label) != .orderedSame { parts.append(detail) }
        parts.append(placementLabel.lowercased())
        return parts.joined(separator: " — ")
    }

    var placementLabel: String {
        switch placement {
        case .visible: return "In the menu bar"
        case .offscreen: return "Hidden"
        case .removed: return "Removed"
        }
    }

    static func == (lhs: OverflowItem, rhs: OverflowItem) -> Bool {
        lhs.id == rhs.id
            && lhs.bounds == rhs.bounds
            && (lhs.image == nil) == (rhs.image == nil)
            && lhs.appName == rhs.appName
    }
}

/// An entry of a hidden item's menu, read through Accessibility.
struct OverflowMenuEntry {
    var title: String
    var isEnabled: Bool
    var isSeparator: Bool
    var element: AXUIElement?
    var children: [OverflowMenuEntry]
}

/// Finds and drives menu bar items that are not in the bar.
///
/// On macOS 26 status items are proxied by Control Centre and the off-screen
/// ones are not even in the window list, so the source of truth is each
/// app's own `AXExtrasMenuBar`: every item reports a frame there. Items a
/// hider tucked away sit at a negative x; items an app removed from the bar
/// report a frame outside any menu bar row.
enum MenuBarOverflowResolver {
    static var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Everything that is not in the bar, left to right. Runs on a background
    /// queue: every app is an IPC round trip.
    ///
    /// Without Accessibility only the window list is available, which on
    /// macOS 26 misses off-screen items entirely.
    static func identify(windows: [MenuBarItemWindow]) -> [OverflowItem] {
        guard AccessibilityAuth.hasPermission else {
            return windows.map { window in
                OverflowItem(
                    id: "window-\(window.id)",
                    bounds: window.bounds,
                    placement: .offscreen,
                    captureWindow: window
                )
            }
        }
        var items: [OverflowItem] = []
        for extra in extrasByApp() {
            let placement = MenuBarOverflow.placement(of: extra.frame)
            guard placement != .visible else { continue }
            let window = windows.first { $0.bounds.intersects(extra.frame.insetBy(dx: 2, dy: 2)) }
            items.append(OverflowItem(
                id: "app-\(extra.app.processIdentifier)-\(extra.index)",
                bounds: extra.frame,
                placement: placement,
                captureWindow: window,
                appName: extra.app.localizedName ?? extra.title,
                detail: extra.title,
                appIcon: extra.app.icon,
                pid: extra.app.processIdentifier,
                element: extra.element
            ))
        }
        return items.sorted { lhs, rhs in
            if lhs.placement != rhs.placement { return lhs.placement == .offscreen }
            if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
            return lhs.label < rhs.label
        }
    }

    /// Snapshot each item that still has a window. Needs Screen Recording.
    static func capture(_ items: [OverflowItem]) async -> [OverflowItem] {
        guard screenRecordingGranted, !items.isEmpty else { return items }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return items }
        var result = items
        for index in result.indices {
            let item = result[index]
            let match = content.windows.first { window in
                if let capture = item.captureWindow, window.windowID == capture.id { return true }
                guard let pid = item.pid, window.owningApplication?.processID == pid else { return false }
                return window.frame.intersects(item.bounds.insetBy(dx: 2, dy: 2))
                    && window.frame.height <= 48
            }
            guard let match, let image = await snapshot(match) else { continue }
            result[index].image = NSImage(cgImage: image, size: match.frame.size)
        }
        return result
    }

    /// The item's menu, if it has one. Read fresh at click time.
    static func menuEntries(for item: OverflowItem) -> [OverflowMenuEntry] {
        guard let element = item.element, let menu = child(of: element, role: kAXMenuRole as String)
        else { return [] }
        return entries(of: menu, depth: 0)
    }

    static func press(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func press(_ item: OverflowItem) -> Bool {
        press(item.element)
    }

    // MARK: - Private

    private struct Extra {
        var app: NSRunningApplication
        var element: AXUIElement
        var frame: CGRect
        var title: String?
        var index: Int
    }

    private static func extrasByApp() -> [Extra] {
        var result: [Extra] = []
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy != .prohibited
            && app.processIdentifier != me
            && app.bundleIdentifier != "com.apple.controlcenter" {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.25)
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barValue) == .success,
                  let barRef = barValue
            else { continue }
            let bar = barRef as! AXUIElement
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement]
            else { continue }
            for (index, child) in children.enumerated() {
                // Zero-size entries are proxies or stale buttons, not items.
                guard let frame = frame(of: child), frame.width > 0.5, frame.height > 0.5 else { continue }
                let title = title(of: child)
                let generic = title.map { $0.caseInsensitiveCompare("status menu") == .orderedSame } ?? true
                result.append(Extra(
                    app: app,
                    element: child,
                    frame: frame,
                    title: generic ? nil : title,
                    index: index
                ))
            }
        }
        return result
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue, let sizeRef = sizeValue
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func title(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
               let text = value as? String, !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func child(of element: AXUIElement, role: String) -> AXUIElement? {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return nil }
        return children.first { child in
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleValue)
            return (roleValue as? String) == role
        }
    }

    private static func entries(of menu: AXUIElement, depth: Int) -> [OverflowMenuEntry] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return [] }
        return children.prefix(60).map { child in
            let title = title(of: child)
            var enabledValue: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXEnabledAttribute as CFString, &enabledValue)
            let enabled = (enabledValue as? Bool) ?? true
            let submenu = depth < 2 ? self.child(of: child, role: kAXMenuRole as String) : nil
            return OverflowMenuEntry(
                title: title ?? "",
                isEnabled: enabled,
                isSeparator: title == nil,
                element: child,
                children: submenu.map { entries(of: $0, depth: depth + 1) } ?? []
            )
        }
    }

    private static func snapshot(_ window: SCWindow) async -> CGImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width * scale))
        config.height = max(1, Int(window.frame.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Pops up a native menu that mirrors a hidden item's menu. Choosing an
/// entry presses the real one through Accessibility, so the item works
/// without ever being on screen.
final class MenuBarOverflowMenu: NSObject, NSMenuDelegate {
    private var completion: (() -> Void)?

    /// Returns `false` when the item has no menu; callers then press it directly.
    func present(_ entries: [OverflowMenuEntry], title: String, completion: @escaping () -> Void) -> Bool {
        guard !entries.isEmpty else { return false }
        self.completion = completion
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.delegate = self
        fill(menu, with: entries)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return true
    }

    private func fill(_ menu: NSMenu, with entries: [OverflowMenuEntry]) {
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.isEnabled
            item.representedObject = entry.element
            if !entry.children.isEmpty {
                let submenu = NSMenu(title: entry.title)
                submenu.autoenablesItems = false
                fill(submenu, with: entry.children)
                item.submenu = submenu
            }
            menu.addItem(item)
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let element = sender.representedObject else { return }
        _ = MenuBarOverflowResolver.press((element as! AXUIElement))
    }

    func menuDidClose(_ menu: NSMenu) {
        let done = completion
        completion = nil
        DispatchQueue.main.async { done?() }
    }
}

/// Floating strip under the chevron that shows the icons macOS hid.
final class MenuBarOverflowPanel {
    private var panel: NSPanel?
    private var outsideClick: Any?
    private var escape: Any?
    private let onPress: (OverflowItem) -> Void
    private let onDismiss: () -> Void

    init(onPress: @escaping (OverflowItem) -> Void, onDismiss: @escaping () -> Void) {
        self.onPress = onPress
        self.onDismiss = onDismiss
    }

    var isShown: Bool { panel?.isVisible ?? false }

    func show(
        items: [OverflowItem],
        accessibility: Bool,
        layout: MenuBarStripLayout,
        iconSize: CGFloat,
        labelSize: CGFloat,
        anchor: NSRect
    ) {
        let host = NSHostingView(rootView: OverflowStrip(
            items: items,
            accessibility: accessibility,
            layout: layout,
            iconSize: iconSize,
            labelSize: labelSize,
            onPress: { [weak self] item in
                self?.onPress(item)
            }
        ))
        host.sizingOptions = [.intrinsicContentSize]
        let size = host.fittingSize
        let panel = self.panel ?? makePanel()
        panel.contentView = host
        var frame = NSRect(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - 4,
            width: size.width,
            height: size.height
        )
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            frame.origin.x = min(max(frame.minX, screen.frame.minX + 6), screen.frame.maxX - size.width - 6)
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        startMonitors()
    }

    func dismiss() {
        stopMonitors()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        onDismiss()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func startMonitors() {
        stopMonitors()
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        escape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss()
                return nil
            }
            return event
        }
    }

    private func stopMonitors() {
        if let outsideClick {
            NSEvent.removeMonitor(outsideClick)
            self.outsideClick = nil
        }
        if let escape {
            NSEvent.removeMonitor(escape)
            self.escape = nil
        }
    }
}
