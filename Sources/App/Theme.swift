import AppKit
import SwiftUI

enum Brand {
    static let product = "Yeobun"
    static let studio = "N6 Studio"
    static let studioURL = URL(string: "https://n6.studio/")!
}

final class PanelPresentation: ObservableObject {
    @Published var generation = 0
    @Published var route: PanelRoute = .home
    @Published var isEditingHome = false

    func menuDidOpen() {
        generation += 1
    }

    func menuDidClose() {
        route = .home
        isEditingHome = false
        generation = 0
    }

    func open(_ route: PanelRoute) {
        isEditingHome = false
        self.route = route
        generation += 1
    }

    func back() {
        isEditingHome = false
        route = .home
        generation += 1
    }
}

enum PanelRoute: Equatable, Hashable {
    case home
    case keyboard
    case scroll
    case lid
    case awake
    case menuBar
    case voice
    case machine
    case battery
    case network
    case storage
    case remote(UUID)
    case settings

    var title: String {
        switch self {
        case .home: Brand.product
        case .keyboard: ToolID.keyboard.title
        case .scroll: ToolID.scroll.title
        case .lid: ToolID.lid.title
        case .awake: ToolID.awake.title
        case .menuBar: ToolID.menuBar.title
        case .voice: ToolID.voice.title
        case .machine: ToolID.machine.title
        case .battery: ToolID.battery.title
        case .network: ToolID.network.title
        case .storage: ToolID.storage.title
        case .remote: "Remote"
        case .settings: "Settings"
        }
    }
}

enum HomeItem: Hashable, Identifiable {
    case tool(ToolID)
    case remote(UUID)

    var id: String { token }

    var token: String {
        switch self {
        case .tool(let id): id.rawValue
        case .remote(let id): "remote:\(id.uuidString)"
        }
    }

    init?(token: String) {
        if token.hasPrefix("remote:") {
            let raw = String(token.dropFirst("remote:".count))
            guard let id = UUID(uuidString: raw) else { return nil }
            self = .remote(id)
            return
        }
        guard let tool = ToolID(rawValue: token) else { return nil }
        self = .tool(tool)
    }

    /// Storage, battery, and network live on the Mac page, not as their own rows.
    var showsOnHome: Bool {
        switch self {
        case .tool(.storage), .tool(.battery), .tool(.network):
            false
        default:
            true
        }
    }

    var isToggle: Bool {
        switch self {
        case .tool(let id): !id.isInformational
        case .remote: false
        }
    }

    var route: PanelRoute {
        switch self {
        case .tool(let id): id.route
        case .remote(let id): .remote(id)
        }
    }

    var glyph: GlyphID {
        switch self {
        case .tool(let id): id.glyph
        case .remote: .hardDrives
        }
    }

    var accent: Color {
        switch self {
        case .tool(let id): id.accent
        case .remote: ModuleColor.machine
        }
    }

    static var builtins: [HomeItem] {
        ToolID.allCases.map { .tool($0) }
    }
}

typealias HomeTool = HomeItem

extension ToolID {
    var title: String {
        switch self {
        case .keyboard: "Built-in keyboard"
        case .scroll: "Scroll reverse"
        case .lid: "Lid awake"
        case .awake: "Keep awake"
        case .menuBar: "Hidden icons"
        case .voice: "Voice typing"
        case .machine: "This MacBook"
        case .battery: "Battery"
        case .network: "Network"
        case .storage: "Storage"
        }
    }

    var glyph: GlyphID {
        switch self {
        case .keyboard: .lock
        case .scroll: .mouse
        case .lid: .moonStars
        case .awake: .coffee
        case .menuBar: .eyeSlash
        case .voice: .microphone
        case .machine: .laptop
        case .battery: .batteryFull
        case .network: .wifiHigh
        case .storage: .hardDrive
        }
    }

    var accent: Color {
        switch self {
        case .keyboard: ModuleColor.keyboard
        case .scroll: ModuleColor.scroll
        case .lid: ModuleColor.lid
        case .awake: ModuleColor.awake
        case .menuBar: ModuleColor.menuBar
        case .voice: ModuleColor.voice
        case .machine, .battery, .network, .storage: ModuleColor.machine
        }
    }

    var isInformational: Bool {
        kind == .informational
    }

    var route: PanelRoute {
        switch self {
        case .keyboard: .keyboard
        case .scroll: .scroll
        case .lid: .lid
        case .awake: .awake
        case .menuBar: .menuBar
        case .voice: .voice
        case .machine: .machine
        case .battery: .battery
        case .network: .network
        case .storage: .storage
        }
    }
}

enum Motion {
    static let enter = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.3)
    static let press = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.15)
    static let hover = press
    static let stagger: TimeInterval = 0.1
    static let enterOffset: CGFloat = 8
    static let pressScale: CGFloat = 0.96
    static let hoverScale: CGFloat = 1.06
}

enum Radius {
    static let group: CGFloat = 16
    static let groupPadding: CGFloat = 14
    static let panelPadding: CGFloat = 18
    static let panelWidth: CGFloat = 320
    static let row: CGFloat = 12
    static let chrome: CGFloat = 28
}

enum ModuleColor {
    static let keyboard = Color.orange
    static let scroll = Color.accentColor
    static let lid = Color.purple
    static let awake = Color.brown
    static let menuBar = Color.teal
    static let voice = Color.red
    static let machine = Color.secondary
    static let offFill = Color.primary.opacity(0.08)
    static let offFillHover = Color.primary.opacity(0.13)
    static let glyphOffFill = Color.primary.opacity(0.14)
    /// On-state wash behind primary text. Dark enough that orange and brown stay readable.
    static let onFill = 0.18
    static let onFillHover = 0.28
    static let groupFill = Color.primary.opacity(0.06)
    static let usageWarning = Color.orange
    static let usageCritical = Color.red
}

enum UsageLevel: Equatable {
    case normal
    case warning
    case critical

    static let warningAt: Double = 0.70
    static let criticalAt: Double = 0.90

    init(fraction: Double) {
        if fraction >= Self.criticalAt {
            self = .critical
        } else if fraction >= Self.warningAt {
            self = .warning
        } else {
            self = .normal
        }
    }

    static func remaining(_ fraction: Double) -> UsageLevel {
        UsageLevel(fraction: 1 - fraction)
    }

    var tint: Color? {
        switch self {
        case .normal: nil
        case .warning: ModuleColor.usageWarning
        case .critical: ModuleColor.usageCritical
        }
    }
}

struct PressScaleButtonStyle: ButtonStyle {
    var isStatic = false

    func makeBody(configuration: Configuration) -> some View {
        PressScaleButtonBody(configuration: configuration, isStatic: isStatic)
    }
}

private struct PressScaleButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var isStatic: Bool
    @State private var cursorPushed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .scaleEffect(isStatic || !configuration.isPressed ? 1 : Motion.pressScale)
            .animation(isStatic ? nil : Motion.press, value: configuration.isPressed)
            .onHover { inside in
                setCursor(inside && isEnabled && !isStatic)
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { setCursor(false) }
            }
            .onDisappear { setCursor(false) }
    }

    private func setCursor(_ on: Bool) {
        if on, !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !on, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

struct ChromeButton: View {
    let systemName: String
    let label: String
    var opticalNudge: CGSize = .zero
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .offset(opticalNudge)
                .foregroundStyle(.primary)
                .frame(width: Radius.chrome, height: Radius.chrome)
                .background(ModuleColor.offFill, in: Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

struct StateSymbol: View {
    let glyph: GlyphID
    let isActive: Bool
    var size: CGFloat = GlyphSlot.detail

    var body: some View {
        GlyphIcon(id: glyph, filled: isActive)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StaggeredEntrance: ViewModifier {
    let index: Int
    let generation: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var played = 0

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : Motion.enterOffset)
            .onAppear { sync() }
            .onChange(of: generation) { _, _ in
                sync()
            }
    }

    private func sync() {
        if generation == 0 {
            var snap = Transaction()
            snap.disablesAnimations = true
            withTransaction(snap) {
                shown = false
                played = 0
            }
            return
        }
        replay()
    }

    private func replay() {
        guard generation != played else { return }
        played = generation
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { shown = false }
        if reduceMotion {
            shown = true
            return
        }
        withAnimation(Motion.enter.delay(Double(index) * Motion.stagger)) {
            shown = true
        }
    }
}

extension View {
    func stagger(index: Int, generation: Int) -> some View {
        modifier(StaggeredEntrance(index: index, generation: generation))
    }
}
