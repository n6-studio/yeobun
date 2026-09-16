import AppKit
import Combine

/// Two extra status items that tuck other apps' icons away, the way Ice and
/// Hidden Bar do.
///
/// An off-screen **spacer** sits to the left of a **chevron**. Anything the
/// user ⌘-drags to the left of the chevron is hidden: the spacer stretches to
/// 10 000 pt, which pushes every item left of it off the screen. Clicking the
/// chevron opens a strip of those icons.
///
/// The items are created the first time the tool turns on and kept for the
/// life of the app; turning the tool off only hides them so their positions
/// survive (`autosaveName`).
final class MenuBarHider {
    private static let hiddenLength: CGFloat = 10_000
    private static let gapLength: CGFloat = 4
    private static let chevronAutosave = "Yeobun.MenuBar.Chevron"
    private static let dividerAutosave = "Yeobun.MenuBar.Divider"

    private let model: AppModel
    private var chevron: NSStatusItem?
    private var divider: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var moveObservers: [NSObjectProtocol] = []
    private var layoutCheck: DispatchWorkItem?
    private var spinTimer: Timer?
    private var spinAngle: CGFloat = 0
    private var chevronVisibleObserver: NSKeyValueObservation?
    private var overflow: MenuBarOverflowPanel!
    private let overflowMenu = MenuBarOverflowMenu()
    private let overflowQueue = DispatchQueue(label: "studio.n6.yeobun.overflow.menu", qos: .userInitiated)

    init(model: AppModel) {
        self.model = model
        overflow = MenuBarOverflowPanel(
            onPress: { [weak self] item in
                self?.useOverflowItem(item)
            },
            onDismiss: { [weak model] in
                model?.closeOverflowStrip()
            }
        )
        Publishers.CombineLatest(
            Publishers.CombineLatest3(model.$overflowItems, model.$overflowStripOpen, model.$overflowScanned),
            Publishers.CombineLatest3(
                model.$menuBarStripIconSize,
                model.$menuBarStripLabelSize,
                model.$menuBarStripLayout
            )
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] overflow, appearance in
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
                layout: layout
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
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Spacer fully left of the chevron. When the user drags the chevron to
    /// the wrong side, stretching the spacer would push the chevron itself off
    /// screen, so we refuse to hide until the two are back in order.
    var layoutIsValid: Bool {
        guard let dividerFrame = divider?.button?.window?.frame,
              let chevronFrame = chevron?.button?.window?.frame
        else { return true }
        return dividerFrame.maxX <= chevronFrame.minX + 0.5
    }

    // MARK: - Apply

    private func apply(enabled: Bool) {
        guard enabled else {
            chevronVisibleObserver = nil
            overflow.dismiss()
            chevron?.isVisible = false
            divider?.isVisible = false
            return
        }
        ensureItems()
        guard let chevron, let divider else { return }
        chevron.isVisible = true
        divider.isVisible = true
        observeChevronVisibility()

        let tuck = layoutIsValid
        if tuck {
            divider.length = Self.hiddenLength
            divider.button?.image = nil
        } else {
            divider.length = Self.gapLength
            divider.button?.image = nil
        }
        divider.button?.toolTip = "⌘-drag icons left of the chevron to hide them"

        if spinTimer == nil {
            chevron.button?.image = Self.chevronImage(stripOpen: model.overflowStripOpen)
        }
        chevron.button?.toolTip = model.overflowStripOpen ? "Close hidden icons" : "Show hidden icons"
        chevron.button?.setAccessibilityLabel(model.overflowStripOpen ? "Close hidden icons" : "Show hidden icons")

        scheduleLayoutCheck()
    }

    private func ensureItems() {
        guard chevron == nil || divider == nil else { return }
        // New status items land at the left of the existing ones, so create the
        // chevron first and the spacer second to get [spacer][chevron].
        let chevronItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        chevronItem.autosaveName = Self.chevronAutosave
        chevronItem.behavior = []
        if let button = chevronItem.button {
            button.target = self
            button.action = #selector(chevronClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
        }
        chevron = chevronItem

        let dividerItem = NSStatusBar.system.statusItem(withLength: Self.gapLength)
        dividerItem.autosaveName = Self.dividerAutosave
        dividerItem.behavior = []
        if let button = dividerItem.button {
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Yeobun hidden icons")
        }
        divider = dividerItem

        observeMoves()
        observeChevronVisibility()
    }

    /// The chevron is the fallback way to open Yeobun; do not let a ⌘-drag hide it.
    private func observeChevronVisibility() {
        guard model.menuBarHideEnabled else {
            chevronVisibleObserver = nil
            return
        }
        chevronVisibleObserver = chevron?.observe(\.isVisible, options: [.new]) { [weak self] item, _ in
            guard let self, self.model.menuBarHideEnabled, !item.isVisible else { return }
            DispatchQueue.main.async {
                guard self.model.menuBarHideEnabled else { return }
                self.chevron?.isVisible = true
            }
        }
    }

    private func observeMoves() {
        for observer in moveObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        moveObservers = [chevron, divider].compactMap { item in
            guard let window = item?.button?.window else { return nil }
            return NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleLayoutCheck()
            }
        }
    }

    private func scheduleLayoutCheck() {
        layoutCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.checkLayout()
        }
        layoutCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func checkLayout() {
        guard model.menuBarHideEnabled else { return }
        let valid = layoutIsValid
        model.noteMenuBarLayout(valid: valid)
        if valid, divider?.length != Self.hiddenLength {
            apply(enabled: true)
        }
    }

    /// Show the item's own menu under the pointer; items without a menu are
    /// pressed directly, which is all a popover-style item can offer.
    /// Yeobun's own tile opens the panel from the chevron, on screen.
    private func useOverflowItem(_ item: OverflowItem) {
        if item.opensYeobun {
            let anchor = chevron?.button
            overflow.dismiss()
            DispatchQueue.main.async { [weak self] in
                self?.model.requestOpenPanel(from: anchor)
            }
            return
        }
        overflowQueue.async { [weak self] in
            let entries = MenuBarOverflowResolver.menuEntries(for: item)
            DispatchQueue.main.async {
                guard let self else { return }
                let shown = self.overflowMenu.present(entries, title: item.label) { [weak self] in
                    self?.overflow.dismiss()
                }
                if !shown {
                    self.overflow.dismiss()
                    self.model.activateOverflowItem(item)
                }
            }
        }
    }

    private func presentOverflow(
        _ items: [OverflowItem],
        open: Bool,
        scanned: Bool,
        iconSize: Int,
        labelSize: Int,
        layout: MenuBarStripLayout
    ) {
        guard model.menuBarHideEnabled, open, scanned,
              let anchor = chevron?.button?.window?.frame
        else {
            overflow.dismiss()
            return
        }
        overflow.show(
            items: items,
            accessibility: model.accessibilityTrusted,
            layout: layout,
            iconSize: CGFloat(iconSize),
            labelSize: CGFloat(labelSize),
            anchor: anchor
        )
    }

    // MARK: - Actions

    @objc private func chevronClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
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
        let off = NSMenuItem(title: "Turn off \(HomeTool.menuBar.title)", action: #selector(turnOffFromMenu), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        chevron.menu = menu
        chevron.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, let chevron = self.chevron else { return }
            chevron.menu = nil
            chevron.button?.target = self
            chevron.button?.action = #selector(self.chevronClicked(_:))
            chevron.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
