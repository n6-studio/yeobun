import AppKit
import Combine
import SwiftUI

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private let presentation = PanelPresentation()
    private var eventMonitor: Any?
    private var displayRefreshWork: DispatchWorkItem?
    private var iconCancellables = Set<AnyCancellable>()
    private var hider: MenuBarHider?
    private var visibilityObserver: NSKeyValueObservation?
    private var endingExpandedSession = false
    /// The menu is shown after the click, not inside it. A second request while
    /// that is pending or while the menu is up would dismiss it.
    private var contextMenuQueued = false
    private var showingContextMenu = false
    /// The expanded session ends as the click finishes. Closing the panel
    /// there would make a left click look like it did nothing.
    private var panelShownAt: Date?
    /// A removed status item keeps its autosave slot off the bar on macOS 27.
    /// Allow in the Menu Bar turning back on does not reuse that slot, so each
    /// restore takes the next name.
    private var panelAutosave: String {
        let slot = UserDefaults.standard.integer(forKey: Self.markSlotKey)
        return "Yeobun.Now.\(slot)"
    }

    private static let markSlotKey = "yeobun.statusSlot.mark"

    init(model: AppModel) {
        self.model = model
        let slot = UserDefaults.standard.integer(forKey: Self.markSlotKey)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Yeobun.Now.\(slot)"
        statusItem = item
        super.init()
        model.openPanel = { [weak self] view in self?.showPopover(from: view) }
        model.isMainStatusItemHidden = { [weak self] in
            guard let self else { return false }
            return MenuBarOverflow.isOffMenuBar(self.statusItem)
        }
        model.restoreMainStatusItem = { [weak self] in
            self?.showPanelItem()
        }

        let host = NSHostingController(
            rootView: ToolsPanel()
                .environmentObject(model)
                .environmentObject(model.liveStats)
                .environmentObject(presentation)
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        configureStatusItem()
        observeDisplayChanges()
        observeActiveTools()
        hider = MenuBarHider(model: model)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.isVisible = true
        }
        // macOS 27 keeps a removed status item off the bar until it is created
        // again with a preferred position already stored. Check once the windows exist.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.recoverOffBarIcons()
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.restoreIfReallowed()
        }
        RunLoop.main.add(timer, forMode: .common)
        allowanceTimer = timer
    }

    deinit {
        allowanceTimer?.invalidate()
        displayRefreshWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func showPopover(from view: NSView? = nil) {
        statusItem.isVisible = true
        guard let button = view ?? preferredPanelAnchor else { return }
        model.restorePersistedTools()
        model.refreshAccessibility()
        panelShownAt = Date()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        startEventMonitor()
    }

    /// Prefer the wrench; if macOS or the hider tucked it away, open from the chevron.
    private var preferredPanelAnchor: NSView? {
        if !MenuBarOverflow.isOffMenuBar(statusItem), let button = statusItem.button {
            return button
        }
        if let chevron = hider?.panelAnchor,
           let window = chevron.window,
           MenuBarOverflow.placement(of: MenuBarOverflow.toCG(window.frame)) == .visible {
            return chevron
        }
        return statusItem.button ?? hider?.panelAnchor
    }

    @objc private func togglePopover(_ sender: Any?) {
        if Self.isRightClick(NSApp.currentEvent) {
            queueContextMenu()
            return
        }
        if popover.isShown {
            dismissPopover()
            return
        }
        showPopover()
    }

    /// Right-click stays a menu. Any other click, including an accessibility
    /// press, opens the panel. The button action is the only click a press
    /// delivers, so it cannot assume every call is a right-click.
    @objc private func statusItemRightClicked(_ sender: Any?) {
        if Self.isRightClick(NSApp.currentEvent) {
            queueContextMenu()
            return
        }
        guard !showingContextMenu else { return }
        if popover.isShown {
            dismissPopover()
        } else {
            showPopover()
        }
    }

    /// Opening the menu inside the right-click makes macOS 27 treat the mouse-up
    /// as the click that dismisses it, so the menu only flashes. Wait until the
    /// right button is up, then open it.
    private func queueContextMenu() {
        if showingContextMenu || contextMenuQueued { return }
        contextMenuQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.showContextMenuWhenClickEnds()
        }
    }

    private func showContextMenuWhenClickEnds() {
        guard contextMenuQueued, !showingContextMenu else { return }
        let rightButton = 1 << 1
        if NSEvent.pressedMouseButtons & rightButton != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.showContextMenuWhenClickEnds()
            }
            return
        }
        contextMenuQueued = false
        showContextMenu()
    }

    private func dismissPopover() {
        if cancelExpandedSession() { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        stopEventMonitor()
    }

    /// macOS 27's expanded-interface types are newer than the SDK this
    /// project builds with, so the session is reached by key and selector.
    @discardableResult
    private func cancelExpandedSession() -> Bool {
        guard #available(macOS 27, *), !endingExpandedSession else { return false }
        let key = "expandedInterfaceSession"
        guard statusItem.responds(to: NSSelectorFromString(key)),
              let session = statusItem.value(forKey: key) as AnyObject?
        else { return false }
        _ = session.perform(NSSelectorFromString("cancel"))
        if popover.isShown {
            endingExpandedSession = true
            popover.performClose(nil)
            endingExpandedSession = false
        }
        stopEventMonitor()
        return true
    }

    private static func isRightClick(_ event: NSEvent?) -> Bool {
        switch event?.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return true
        default:
            return false
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(withTitle: "Open Yeobun", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: ToolID.keyboard.title,
            action: #selector(toggleKeyboardFromMenu),
            isOn: model.keyboardLocked,
            isEnabled: !model.keyboardBusy
        ))
        menu.addItem(toggleItem(
            title: ToolID.scroll.title,
            action: #selector(toggleScrollFromMenu),
            isOn: model.scrollReverseEnabled,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: ToolID.lid.title,
            action: #selector(toggleLidFromMenu),
            isOn: model.lidSleepDisabled,
            isEnabled: !model.lidBusy
        ))
        menu.addItem(toggleItem(
            title: ToolID.awake.title,
            action: #selector(toggleAwakeFromMenu),
            isOn: model.awakeActive,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: ToolID.menuBar.title,
            action: #selector(toggleMenuBarFromMenu),
            isOn: model.menuBarHideEnabled,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: ToolID.voice.title,
            action: #selector(toggleVoiceFromMenu),
            isOn: model.voiceEnabled,
            isEnabled: true
        ))
        if model.voiceEnabled {
            let listening = model.voiceListening || model.voiceBusy
            let item = NSMenuItem(
                title: listening ? "Stop Listening" : "Start Listening",
                action: #selector(toggleVoiceListeningFromMenu),
                keyEquivalent: ""
            )
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(menuBarDisplayItem())
        menu.addItem(menuBarStatsItem())
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quitFromMenu), keyEquivalent: "q")

        menu.items.forEach { item in
            if item.action != nil {
                item.target = self
            }
        }

        guard let button = statusItem.button else { return }
        if popover.isShown {
            dismissPopover()
        }
        showingContextMenu = true
        button.highlight(true)
        let y = button.isFlipped ? button.bounds.height : 0
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
        button.highlight(false)
        showingContextMenu = false
    }

    private func toggleItem(title: String, action: Selector, isOn: Bool, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.state = isOn ? .on : .off
        item.isEnabled = isEnabled
        return item
    }

    @objc private func openFromMenu() {
        showPopover()
    }

    @objc private func toggleKeyboardFromMenu() {
        model.toggleKeyboard()
    }

    @objc private func toggleScrollFromMenu() {
        model.toggleScrollReverse()
    }

    @objc private func toggleLidFromMenu() {
        model.toggleLidSleep()
    }

    @objc private func toggleAwakeFromMenu() {
        model.toggleAwake()
    }

    @objc private func toggleMenuBarFromMenu() {
        model.toggleMenuBarHide()
    }

    @objc private func toggleVoiceFromMenu() {
        model.toggleVoiceEnabled()
    }

    @objc private func toggleVoiceListeningFromMenu() {
        model.toggleVoice()
    }

    @objc private func quitFromMenu() {
        model.quit()
    }

    private func menuBarDisplayItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Menu bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, mode) in MenuBarDisplay.allCases.enumerated() {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectMenuBarDisplay(_:)), keyEquivalent: "")
            entry.tag = index
            entry.state = model.menuBarDisplay == mode ? .on : .off
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectMenuBarDisplay(_ sender: NSMenuItem) {
        let modes = MenuBarDisplay.allCases
        guard modes.indices.contains(sender.tag) else { return }
        model.menuBarDisplay = modes[sender.tag]
    }

    private func menuBarStatsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Menu bar stats", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (index, mode) in MenuBarStats.allCases.enumerated() {
            let entry = NSMenuItem(title: mode.title, action: #selector(selectMenuBarStats(_:)), keyEquivalent: "")
            entry.tag = index
            entry.state = model.menuBarStats == mode ? .on : .off
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func selectMenuBarStats(_ sender: NSMenuItem) {
        let modes = MenuBarStats.allCases
        guard modes.indices.contains(sender.tag) else { return }
        model.menuBarStats = modes[sender.tag]
    }

    private var didRecoverOffBar = false
    private var allowanceWasOn: Bool?
    private var allowanceTimer: Timer?

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The name has to be set before the item is shown, or macOS 27 leaves
        // a previously removed icon in the off-bar slot and ignores later edits.
        item.autosaveName = panelAutosave
        return item
    }

    /// Drop the saved slot and create the wrench again. A stored position is what
    /// kept a ⌘-dragged icon off the bar on macOS 27.
    private func showPanelItem() {
        didRecoverOffBar = true
        visibilityObserver = nil
        NSStatusBar.system.removeStatusItem(statusItem)
        let defaults = UserDefaults.standard
        let name = panelAutosave
        defaults.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
        defaults.set(true, forKey: "NSStatusItem Visible \(name)")
        defaults.set(true, forKey: "NSStatusItem VisibleCC \(name)")
        statusItem = makeStatusItem()
        configureStatusItem()
    }

    /// Recreate icons macOS parked off the bar. One attempt: a second pass would fight a real ⌘-drag.
    private func recoverOffBarIcons() {
        guard !didRecoverOffBar else { return }
        hider?.recoverIfOffBar()
        guard let frame = statusItem.button?.window?.frame, frame.height > 1, !panelIsOnBar else {
            return
        }
        showPanelItem()
    }

    /// Cocoa coordinates, no flip. The menu bar is the strip above `visibleFrame`.
    private var panelIsOnBar: Bool {
        guard let frame = statusItem.button?.window?.frame, frame.width > 1, frame.height > 1 else {
            return false
        }
        return NSScreen.screens.contains { screen in
            let barBottom = screen.visibleFrame.maxY
            return frame.midY >= barBottom - 4
                && frame.midY <= screen.frame.maxY + 4
                && frame.midX >= screen.frame.minX
                && frame.midX <= screen.frame.maxX
        }
    }

    private func configureStatusItem() {
        // macOS 27 hosts status items as menu-bar scenes. An item that cannot
        // be removed never gets a scene, so the wrench and the chevron stay off
        // the bar even after Allow in the Menu Bar is turned back on.
        if #available(macOS 13.0, *) {
            statusItem.behavior = .removalAllowed
        }
        statusItem.isVisible = true
        observeVisibility()
        applyIcon()
        installStatusItemClick()
    }

    private func installStatusItemClick() {
        guard let button = statusItem.button else { return }
        button.target = self
        if #available(macOS 27, *),
           statusItem.responds(to: NSSelectorFromString("setExpandedInterfaceDelegate:")) {
            statusItem.setValue(self, forKey: "expandedInterfaceDelegate")
            button.action = #selector(statusItemRightClicked(_:))
            button.sendAction(on: [.rightMouseUp])
        } else {
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Control Center's Allow in the Menu Bar hides every status item of this
    /// app, chevron included. Forcing `isVisible` back on leaves the items in
    /// the accessibility tree without drawing them, and turning the switch on
    /// again does not recreate them. Recreate on the false → true edge instead.
    private func restoreIfReallowed() {
        let allowed = MenuBarAllowance.isYeobunAllowed()
        defer { allowanceWasOn = allowed }
        guard allowed, allowanceWasOn == false else { return }
        let next = UserDefaults.standard.integer(forKey: Self.markSlotKey) + 1
        UserDefaults.standard.set(next, forKey: Self.markSlotKey)
        showPanelItem()
        hider?.restoreChevron()
    }

    private func observeVisibility() {
        visibilityObserver = statusItem.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            guard let self, !item.isVisible else { return }
            DispatchQueue.main.async {
                self.restoreIfReallowed()
            }
        }
    }

    private var appliedIconKey: String?

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        let mode = model.menuBarDisplay
        let tools = model.activeMenuBarTools
        let statsText = model.menuBarStatsText
        let statsCaption = model.menuBarStats.caption
        let key = "\(mode.rawValue)|\(tools.map(\.rawValue).joined(separator: ","))|\(statsText ?? "")|\(statsCaption ?? "")"
        if key == appliedIconKey, button.image != nil { return }
        appliedIconKey = key
        statusItem.length = MenuBarIcon.statusItemLength(mode: mode, tools: tools, statsText: statsText)
        button.image = nil
        button.image = MenuBarIcon.makeImage(
            mode: mode,
            tools: tools,
            statsText: statsText,
            statsCaption: statsCaption
        )
        button.imageScaling = .scaleNone
        button.imagePosition = .imageOnly
        button.toolTip = MenuBarIcon.tooltip(
            tools: tools,
            statsText: statsText,
            statsCaption: statsCaption
        )
    }

    private func observeActiveTools() {
        Publishers.CombineLatest4(
            model.$keyboardLocked,
            model.$scrollReverseEnabled,
            model.$lidSleepDisabled,
            model.$awakeActive
        )
        .combineLatest(model.$menuBarHideEnabled)
        .combineLatest(model.$voiceListening)
        .combineLatest(model.$menuBarDisplay)
        .combineLatest(model.$menuBarStats)
        .combineLatest(model.liveStats.$sample)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.applyIcon()
        }
        .store(in: &iconCancellables)

        presentation.$route
            .receive(on: DispatchQueue.main)
            .sink { [weak self] route in
                self?.model.notePanelRoute(route)
            }
            .store(in: &iconCancellables)
    }

    private func observeDisplayChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backingPropertiesChanged),
            name: NSWindow.didChangeBackingPropertiesNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        scheduleIconRefresh()
    }

    @objc private func backingPropertiesChanged(_ notification: Notification) {
        guard (notification.object as? NSWindow) == statusItem.button?.window else { return }
        applyIcon()
    }

    /// Redraw in place. Recreating the status item would drop it at the left
    /// of the bar, which is the hidden side of the chevron.
    private func scheduleIconRefresh() {
        displayRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyIcon()
        }
        displayRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.dismissPopover()
        }
    }

    private func stopEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

extension MenuBarController: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        presentation.menuDidOpen()
        model.startStats()
        model.refreshUpdateIfNeeded()
    }

    func popoverDidClose(_ notification: Notification) {
        panelShownAt = nil
        presentation.menuDidClose()
        model.stopStats()
        stopEventMonitor()
        cancelExpandedSession()
    }
}

extension MenuBarController {
    /// `NSStatusItemExpandedInterfaceDelegate`, bound at runtime on macOS 27.
    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItem(_ statusItem: NSStatusItem, didBeginExpandedInterfaceSession session: AnyObject) {
        if showingContextMenu {
            return
        }
        if Self.isRightClick(NSApp.currentEvent) {
            // This session is the left-click panel. Cancel it and let the
            // mouse-up open the menu once the click is over.
            _ = session.perform(NSSelectorFromString("cancel"))
            queueContextMenu()
            return
        }
        if !popover.isShown {
            showPopover()
        }
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        guard !endingExpandedSession else { return }
        if popover.isShown, let panelShownAt, Date().timeIntervalSince(panelShownAt) < 0.45 {
            return
        }
        endingExpandedSession = true
        if popover.isShown {
            popover.performClose(nil)
        }
        stopEventMonitor()
        endingExpandedSession = false
    }
}
