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
    private static let panelAutosave = "Yeobun.Panel"

    init(model: AppModel) {
        self.model = model
        statusItem = Self.makeStatusItem()
        super.init()
        model.openPanel = { [weak self] view in self?.showPopover(from: view) }
        model.isMainStatusItemHidden = { [weak self] in
            guard let self else { return false }
            return MenuBarOverflow.isOffMenuBar(self.statusItem)
        }

        let host = NSHostingController(
            rootView: ToolsPanel()
                .environmentObject(model)
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
    }

    deinit {
        displayRefreshWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func showPopover(from view: NSView? = nil) {
        statusItem.isVisible = true
        guard let button = view ?? preferredPanelAnchor else { return }
        model.restorePersistedTools()
        model.refreshAccessibility()
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
            stopEventMonitor()
            return
        }
        showPopover()
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(withTitle: "Open Yeobun", action: #selector(openFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(toggleItem(
            title: HomeTool.keyboard.title,
            action: #selector(toggleKeyboardFromMenu),
            isOn: model.keyboardLocked,
            isEnabled: !model.keyboardBusy
        ))
        menu.addItem(toggleItem(
            title: HomeTool.scroll.title,
            action: #selector(toggleScrollFromMenu),
            isOn: model.scrollReverseEnabled,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: HomeTool.lid.title,
            action: #selector(toggleLidFromMenu),
            isOn: model.lidSleepDisabled,
            isEnabled: !model.lidBusy
        ))
        menu.addItem(toggleItem(
            title: HomeTool.awake.title,
            action: #selector(toggleAwakeFromMenu),
            isOn: model.awakeActive,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: HomeTool.menuBar.title,
            action: #selector(toggleMenuBarFromMenu),
            isOn: model.menuBarHideEnabled,
            isEnabled: true
        ))
        menu.addItem(toggleItem(
            title: HomeTool.voice.title,
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

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
            self?.statusItem.button?.target = self
            self?.statusItem.button?.action = #selector(self?.togglePopover(_:))
            self?.statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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

    private static func makeStatusItem() -> NSStatusItem {
        NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    }

    private func configureStatusItem() {
        if #available(macOS 13.0, *) {
            statusItem.behavior = []
        }
        statusItem.isVisible = true
        // After showing: assigning autosave first would restore a hidden state
        // from a previous ⌘-drag off the bar, and this app has no Dock icon.
        statusItem.autosaveName = Self.panelAutosave
        observeVisibility()
        applyIcon()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func observeVisibility() {
        visibilityObserver = statusItem.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            guard let self, !item.isVisible else { return }
            DispatchQueue.main.async {
                self.statusItem.isVisible = true
            }
        }
    }

    private func applyIcon() {
        guard let button = statusItem.button else { return }
        let mode = model.menuBarDisplay
        let tools = model.activeMenuBarTools
        let statsText = model.menuBarStatsText
        let statsCaption = model.menuBarStats.caption
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
        .combineLatest(model.$stats)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.applyIcon()
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
            self.popover.performClose(nil)
            self.stopEventMonitor()
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
    }

    func popoverDidClose(_ notification: Notification) {
        presentation.menuDidClose()
        model.stopStats()
        stopEventMonitor()
    }
}
