import AppKit
import Combine

/// A chevron that opens menu-bar icons the user has already removed.
///
/// ⌘-dragging an icon out of the menu bar parks it off the bar. Clicking the
/// chevron lists those icons, plus any an app hid itself. The chevron is
/// created the first time the tool turns on and kept for the life of the app;
/// turning the tool off only hides it so its position survives (`autosaveName`).
final class MenuBarHider {
    /// A removed chevron keeps its autosave slot off the bar on macOS 27.
    private var chevronAutosave: String {
        let slot = UserDefaults.standard.integer(forKey: Self.chevronSlotKey)
        return "Yeobun.Peek.\(slot)"
    }

    private static let chevronSlotKey = "yeobun.statusSlot.peek"

    private let model: AppModel
    private var chevron: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var overflow: MenuBarOverflowPanel!
    private let overflowMenu = MenuBarOverflowMenu()

    init(model: AppModel) {
        self.model = model
        overflow = MenuBarOverflowPanel(
            onClick: { [weak self] item, click in
                self?.useOverflowItem(item, click: click)
            },
            onDismiss: { [weak model] in
                model?.closeOverflowStrip()
            }
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest(
                Publishers.CombineLatest3(model.$overflowItems, model.$overflowStripOpen, model.$overflowScanned),
                Publishers.CombineLatest3(
                    model.$menuBarStripIconSize,
                    model.$menuBarStripLabelSize,
                    model.$menuBarStripLayout
                )
            ),
            model.$mainStatusItemHidden
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] combined, yeobunHidden in
            let (overflow, appearance) = combined
            let (items, open, scanned) = overflow
            let (iconSize, labelSize, layout) = appearance
            self?.setSpinning(open && !scanned)
            self?.refreshChevron()
            self?.presentOverflow(
                items,
                open: open,
                scanned: scanned,
                iconSize: iconSize,
                labelSize: labelSize,
                layout: layout,
                yeobunHidden: yeobunHidden
            )
        }
        .store(in: &cancellables)
        model.$menuBarHideEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                self?.apply(enabled: enabled)
            }
            .store(in: &cancellables)
    }

    /// Visible chevron button, used as a popover anchor when the wrench is off the bar.
    var panelAnchor: NSView? { chevron?.button }

    deinit {
        spinTimer?.invalidate()
    }

    // MARK: - Apply

    private func apply(enabled: Bool) {
        overflow.ignoreOutsideClicks = false
        guard enabled else {
            overflow.dismiss()
            chevron?.isVisible = false
            return
        }
        ensureItems()
        guard let chevron else { return }
        chevron.isVisible = true

        if spinTimer == nil {
            chevron.button?.image = Self.chevronImage(stripOpen: model.overflowStripOpen)
        }
        chevron.button?.toolTip = model.overflowStripOpen ? "Close hidden icons" : "Show hidden icons"
        chevron.button?.setAccessibilityLabel(model.overflowStripOpen ? "Close hidden icons" : "Show hidden icons")
    }

    /// A lower preferred position sits further right. The wrench uses 200.
    func recoverIfOffBar() {
        guard model.menuBarHideEnabled else { return }
        // A zero-height button window is not a position. macOS 27 reports that for
        // a live status item, and removing it clears the saved slot.
        func isPlaced(_ item: NSStatusItem?) -> Bool {
            guard let frame = item?.button?.window?.frame, frame.height > 1 else { return true }
            return !MenuBarOverflow.isOffMenuBar(item!)
        }
        guard !isPlaced(chevron) else { return }
        if let chevron {
            NSStatusBar.system.removeStatusItem(chevron)
        }
        self.chevron = nil
        Self.clearSlot(chevronAutosave)
        apply(enabled: true)
    }

    private func ensureItems() {
        guard chevron == nil else { return }
        let chevronItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        chevronItem.autosaveName = chevronAutosave
        // macOS 27 only hosts a status item Control Center is allowed to remove.
        chevronItem.behavior = .removalAllowed
        if let button = chevronItem.button {
            button.target = self
            button.action = #selector(chevronClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
        }
        chevron = chevronItem
    }

    /// Put the chevron back after Control Center shows the app again.
    /// A saved position is cleared so macOS 27 does not restore the off-bar slot.
    func restoreChevron() {
        guard model.menuBarHideEnabled else { return }
        let next = UserDefaults.standard.integer(forKey: Self.chevronSlotKey) + 1
        UserDefaults.standard.set(next, forKey: Self.chevronSlotKey)
        if let chevron {
            NSStatusBar.system.removeStatusItem(chevron)
        }
        self.chevron = nil
        Self.clearSlot(chevronAutosave)
        apply(enabled: true)
    }

    private static func clearSlot(_ name: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
        defaults.set(true, forKey: "NSStatusItem Visible \(name)")
        defaults.set(true, forKey: "NSStatusItem VisibleCC \(name)")
    }

    /// Show the item's own menu under the pointer; items without a menu are
    /// pressed directly, which is all a popover-style item can offer.
    /// Yeobun's own tile opens the panel from the chevron, on screen.
    /// The strip stays open if the menu is dismissed without choosing an entry.
    private func useOverflowItem(_ item: OverflowItem, click: OverflowClick) {
        if item.opensYeobun {
            let anchor = chevron?.button
            overflow.dismiss()
            DispatchQueue.main.async { [weak self] in
                self?.model.requestOpenPanel(from: anchor)
            }
            return
        }
        // macOS 27 treats the click's mouse-up as a click on the menu and
        // dismisses it at once. Open only after that button is up.
        DispatchQueue.main.async { [weak self] in
            self?.openItemMenu(item, click: click)
        }
    }

    /// Left click opens the item's menu. Right click opens its context menu
    /// when the item has one, and the same menu when a menu-bar click would.
    /// Either menu is shown under the pointer, not at the item's off-screen frame.
    private func openItemMenu(_ item: OverflowItem, click: OverflowClick) {
        if NSEvent.pressedMouseButtons != 0 {
            DispatchQueue.main.async { [weak self] in
                self?.openItemMenu(item, click: click)
            }
            return
        }
        overflow.ignoreOutsideClicks = true
        let entries = MenuBarOverflowResolver.snapshotMenu(for: item, click: click)
        overflow.ignoreOutsideClicks = false
        overflow.lowerForMenu()
        let shown = overflowMenu.present(
            entries,
            title: item.label,
            in: overflow.hostView
        ) { [weak self] in
            self?.overflow.dismiss()
        }
        overflow.restoreLevel()
        if shown { return }
        // No status menu is published (Allow in the Menu Bar is off). Open the app.
        overflow.dismiss()
        model.activateOverflowItem(item)
    }

    private func presentOverflow(
        _ items: [OverflowItem],
        open: Bool,
        scanned: Bool,
        iconSize: Int,
        labelSize: Int,
        layout: MenuBarStripLayout,
        yeobunHidden: Bool
    ) {
        guard model.menuBarHideEnabled, open, scanned,
              let anchor = chevron?.button?.window?.frame
        else {
            overflow.dismiss()
            return
        }
        overflow.show(
            items: items.filter { !$0.opensYeobun },
            accessibility: model.accessibilityTrusted,
            layout: layout,
            iconSize: CGFloat(iconSize),
            labelSize: CGFloat(labelSize),
            yeobunHidden: yeobunHidden,
            onShowYeobun: { [weak model] in
                model?.restoreMenuBarIcon()
            },
            onOpenMenuBarSettings: {
                MenuBarOverflowResolver.openMenuBarSettings()
            },
            onRefresh: { [weak model] in
                model?.refreshOverflowStrip()
            },
            anchor: anchor
        )
    }

    // MARK: - Actions

    @objc private func chevronClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Same as the wrench: the menu has to open after the mouse-up,
            // or that mouse-up dismisses it immediately.
            DispatchQueue.main.async { [weak self] in
                self?.showContextMenu()
            }
            return
        }
        model.chevronClicked()
    }

    private func showContextMenu() {
        guard let chevron else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open Yeobun", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let off = NSMenuItem(title: "Turn off \(ToolID.menuBar.title)", action: #selector(turnOffFromMenu), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        guard let button = chevron.button else { return }
        let y = button.isFlipped ? button.bounds.height : 0
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: button)
    }

    @objc private func openFromMenu() {
        model.requestOpenPanel(from: chevron?.button)
    }

    @objc private func turnOffFromMenu() {
        model.setMenuBarHideEnabled(false)
    }

    // MARK: - Images

    /// Left while the strip is closed, down while it is open.
    private static func chevronImage(stripOpen: Bool) -> NSImage? {
        let name = stripOpen ? "chevron.down" : "chevron.left"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// Down chevron with a sweeping arc around it, for the loading wait.
    private static func loadingChevron(angle: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            if let chevron {
                let glyph = NSSize(width: chevron.size.width, height: chevron.size.height)
                chevron.draw(
                    in: NSRect(
                        x: rect.midX - glyph.width / 2,
                        y: rect.midY - glyph.height / 2,
                        width: glyph.width,
                        height: glyph.height
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -angle * .pi / 180)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.addArc(center: .zero, radius: 7.2, startAngle: 0.05 * .pi, endAngle: 1.35 * .pi, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func refreshChevron() {
        guard spinTimer == nil, let chevron, model.menuBarHideEnabled else { return }
        chevron.button?.image = Self.chevronImage(stripOpen: model.overflowStripOpen)
        chevron.button?.toolTip = model.overflowStripOpen ? "Close hidden icons" : "Show hidden icons"
    }

    /// Sweep an arc around a still chevron while the strip is being filled.
    /// A full turn takes about a second; the scan usually ends before that.
    private func setSpinning(_ spinning: Bool) {
        if spinning {
            guard spinTimer == nil,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            else { return }
            spinAngle = 0
            chevron?.button?.image = Self.loadingChevron(angle: 0)
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.spinAngle = (self.spinAngle + 12).truncatingRemainder(dividingBy: 360)
                self.chevron?.button?.image = Self.loadingChevron(angle: self.spinAngle)
            }
            RunLoop.main.add(timer, forMode: .common)
            spinTimer = timer
        } else if let spinTimer {
            spinTimer.invalidate()
            self.spinTimer = nil
            refreshChevron()
        }
    }
}
