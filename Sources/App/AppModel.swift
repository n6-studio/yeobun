import AppKit
import Darwin
import Foundation
import ServiceManagement
import SwiftUI

final class AppModel: ObservableObject {
    @Published var keyboardLocked = false
    @Published var keyboardStatus = "Checking lock…"
    @Published var keyboardError: String?
    @Published var autoUnlockMinutes: Int {
        didSet { ToolStateStore.shared.update { $0.autoUnlockMinutes = autoUnlockMinutes } }
    }
    @Published var dimKeyboardWhenLocked: Bool {
        didSet { ToolStateStore.shared.update { $0.dimKeyboardWhenLocked = dimKeyboardWhenLocked } }
    }

    @Published var scrollReverseByDevice: [String: Bool] = [:]

    @Published var scrollReverseEnabled: Bool = false
    @Published var mouseConnected = false
    @Published var mouseNames: [String] = []
    @Published var mice: [MouseDevice] = []
    @Published var accessibilityTrusted = false
    @Published var scrollStatus = "Follows System Settings"

    @Published var lidSleepDisabled = false
    @Published var lidStatus = "Checking lid close…"
    @Published var lidError: String?
    @Published var lidBusy = false

    @Published var awakeActive = false
    @Published var awakeStatus = "Sleeps on idle"
    @Published var awakeError: String?
    @Published var awakeRemainingSeconds: Int?
    @Published var awakeMinutes: Int {
        didSet {
            ToolStateStore.shared.update { $0.awakeMinutes = awakeMinutes }
            if suppressAwakeRestart { return }
            if awakeActive {
                startAwake()
            }
        }
    }

    @Published var menuBarHideEnabled = false
    /// `true` while the icons left of the chevron are tucked away.
    @Published var menuBarHidden = true
    @Published var menuBarStatus = "Icons stay in the menu bar"
    @Published var menuBarNotice: String?
    @Published var menuBarStripIconSize: Int {
        didSet {
            guard menuBarStripIconSize != oldValue, !suppressMenuBarPersist else { return }
            if menuBarStripIconSize == MenuBarTool.hiddenSize,
               menuBarStripLabelSize == MenuBarTool.hiddenSize {
                menuBarStripLabelSize = MenuBarTool.defaultLabelSize
            }
            tools.menuBar.setStripIconSize(menuBarStripIconSize)
        }
    }
    @Published var menuBarStripLabelSize: Int {
        didSet {
            guard menuBarStripLabelSize != oldValue, !suppressMenuBarPersist else { return }
            if menuBarStripLabelSize == MenuBarTool.hiddenSize,
               menuBarStripIconSize == MenuBarTool.hiddenSize {
                menuBarStripIconSize = MenuBarTool.defaultIconSize
            }
            tools.menuBar.setStripLabelSize(menuBarStripLabelSize)
        }
    }
    @Published var menuBarStripLayout: MenuBarStripLayout {
        didSet {
            guard menuBarStripLayout != oldValue, !suppressMenuBarPersist else { return }
            tools.menuBar.setStripLayout(menuBarStripLayout)
        }
    }
    @Published var overflowStripOpen = false

    /// Master switch: arms the shortcut and allows sessions.
    @Published var voiceEnabled = false
    /// One live session. Only possible while `voiceEnabled`.
    @Published var voiceListening = false
    @Published var voiceBusy = false
    @Published var voiceStatus = "Off"
    @Published var voiceTranscript = ""
    @Published var voicePartial = ""
    @Published var voiceError: String?
    @Published var voiceMicrophoneDenied = false
    @Published var voiceLocaleChoices: [VoiceLocaleChoice] = []
    @Published var voiceLocale: String {
        didSet {
            guard voiceLocale != oldValue else { return }
            ToolStateStore.shared.update { $0.voiceLocale = voiceLocale }
            voiceSession.localeIdentifier = voiceLocale
        }
    }
    @Published var voiceHotKey: HotKey {
        didSet {
            guard voiceHotKey != oldValue else { return }
            ToolStateStore.shared.update { $0.voiceHotKey = voiceHotKey }
            syncVoiceHotKey()
            refreshVoiceStatus()
        }
    }
    @Published var voiceSilenceSeconds: Int {
        didSet {
            guard voiceSilenceSeconds != oldValue else { return }
            ToolStateStore.shared.update { $0.voiceSilenceSeconds = voiceSilenceSeconds }
            voiceSession.silenceSeconds = voiceSilenceSeconds
        }
    }
    @Published var voiceTypesText: Bool {
        didSet {
            guard voiceTypesText != oldValue else { return }
            ToolStateStore.shared.update { $0.voiceTypesText = voiceTypesText }
            voiceSession.typesText = voiceTypesText
            refreshVoiceStatus()
        }
    }
    @Published var voiceVocabulary: [VoiceTerm] {
        didSet {
            guard voiceVocabulary != oldValue else { return }
            ToolStateStore.shared.update { $0.voiceVocabulary = voiceVocabulary }
            voiceSession.vocabulary = voiceVocabulary
        }
    }
    let voiceSilenceChoices = VoiceTool.silenceChoices

    /// Icons macOS pushed out of the bar, found on the last peek.
    @Published var overflowItems: [OverflowItem] = []
    @Published var overflowScanned = false
    @Published var screenRecordingGranted = MenuBarOverflowResolver.screenRecordingGranted

    /// Set by the status-item controller so the chevron's menu can open the panel.
    /// The optional view is a visible anchor when the main icon is off the bar.
    var openPanel: ((NSView?) -> Void)?
    /// True when the wrench is not in the visible menu bar.
    var isMainStatusItemHidden: (() -> Bool)?

    @Published var loginItemNotice: String?
    @Published var statusCheckNotice: String?
    @Published var statusCheckBusy = false
    @Published var updateCheckNotice: String?
    @Published var updateCheckBusy = false
    @Published var newerVersion: String?
    @Published var keyboardBusy = false
    @Published var stats = SystemSample()
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin()
        }
    }
    @Published var menuBarDisplay: MenuBarDisplay {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: Keys.menuBarDisplay) }
    }
    @Published var menuBarStats: MenuBarStats {
        didSet {
            UserDefaults.standard.set(menuBarStats.rawValue, forKey: Keys.menuBarStats)
            syncStatsSampling()
        }
    }
    @Published var visibleHomeTools: [HomeItem]
    @Published var hiddenHomeTools: [HomeItem]
    @Published var pins: [HomePin] {
        didSet {
            guard pins != oldValue else { return }
            UserDefaults.standard.set(pins.map(\.token), forKey: Keys.homePins)
        }
    }
    @Published var remotes: [RemoteServer] {
        didSet {
            guard remotes != oldValue else { return }
            ToolStateStore.shared.update { $0.remotes = remotes }
            reconcileRemoteHomeItems()
            syncRemoteSampling()
        }
    }
    @Published var remoteSamples: [UUID: RemoteSample] = [:]
    @Published var remoteAddNotice: String?
    @Published var remoteTestingID: UUID?
    @Published var remoteTestNotice: [UUID: String] = [:]
    let timeoutChoices = [0, 5, 10, 15, 30, 60]
    let awakeDurationChoices = [0, 5, 10, 15, 30, 60, 120, 300]
    let menuBarStripIconSizeChoices = MenuBarTool.iconSizeChoices
    let menuBarStripLabelSizeChoices = MenuBarTool.labelSizeChoices

    private let tools = ToolRegistry.shared
    private let keyboardQueue = DispatchQueue(label: "naf.tools.keyboard", qos: .userInitiated)
    private var keyboardEpoch = 0
    private let lidQueue = DispatchQueue(label: "naf.tools.lid", qos: .userInitiated)
    private var lidEpoch = 0
    private var awakeTick: Timer?
    private let devices = DeviceMonitor()
    private let statsService = SystemStatsService()
    private let remoteStatsService = RemoteStatsService()
    private var wakeObserver: NSObjectProtocol?
    private var accessibilityTimer: Timer?
    private var updateCheckTask: URLSessionDataTask?
    private var updateCheckEpoch = 0
    private var latestReleaseURL: URL?
    private var stateObserver: NSObjectProtocol?
    private var suppressAwakeRestart = false
    private var suppressMenuBarPersist = false
    private var overflowEpoch = 0
    private let overflowQueue = DispatchQueue(label: "studio.n6.yeobun.overflow", qos: .userInitiated)

    private var panelWantsStats = false
    private let voiceSession = VoiceSession()
    private let voiceHotKeys = VoiceHotKeyService()
    private var voiceObserver: NSObjectProtocol?

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let menuBarDisplay = "menuBarDisplay"
        static let menuBarStats = "menuBarStats"
        static let visibleHomeTools = "visibleHomeTools"
        static let hiddenHomeTools = "hiddenHomeTools"
        static let homePins = "homePins"
        static let didLaunch = "didCompleteFirstLaunch"
    }

    init() {
        let defaults = UserDefaults.standard
        let state = ToolStateStore.shared.current
        autoUnlockMinutes = state.autoUnlockMinutes
        dimKeyboardWhenLocked = state.dimKeyboardWhenLocked
        scrollReverseEnabled = state.scrollReverseEnabled
        scrollReverseByDevice = state.scrollReverseByDevice
        lidSleepDisabled = state.lidSleepDisabled
        let storedAwakeMinutes = state.awakeMinutes
        awakeMinutes = [0, 5, 10, 15, 30, 60, 120, 300].contains(storedAwakeMinutes) ? storedAwakeMinutes : 0
        awakeActive = state.awakeEnabled
        keyboardLocked = state.keyboardLocked && Self.isCurrentBoot(state.keyboardLockBoot)
        menuBarHideEnabled = state.menuBarHideEnabled
        menuBarHidden = state.menuBarHidden
        let sizes = MenuBarTool.resolvedSizes(
            icon: state.menuBarStripIconSize,
            label: state.menuBarStripLabelSize
        )
        menuBarStripIconSize = sizes.icon
        menuBarStripLabelSize = sizes.label
        menuBarStripLayout = state.menuBarStripLayout
        voiceEnabled = state.voiceEnabled
        voiceLocale = state.voiceLocale
        voiceHotKey = state.voiceHotKey
        voiceSilenceSeconds = state.voiceSilenceSeconds
        voiceTypesText = state.voiceTypesText
        voiceVocabulary = state.voiceVocabulary
        remotes = RemoteCatalog.clean(state.remotes)
        if defaults.object(forKey: Keys.launchAtLogin) == nil {
            launchAtLogin = true
            defaults.set(true, forKey: Keys.launchAtLogin)
        } else {
            launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        }
        if let raw = defaults.string(forKey: Keys.menuBarDisplay),
           let stored = MenuBarDisplay(rawValue: raw) {
            menuBarDisplay = stored
        } else {
            menuBarDisplay = .logoOnly
        }
        if let raw = defaults.string(forKey: Keys.menuBarStats),
           let stored = MenuBarStats(rawValue: raw) {
            menuBarStats = stored
        } else {
            menuBarStats = .off
        }
        let layout = Self.loadHomeLayout(defaults: defaults)
        visibleHomeTools = layout.visible
        hiddenHomeTools = layout.hidden
        if let stored = defaults.stringArray(forKey: Keys.homePins) {
            var seen = Set<HomePin>()
            pins = stored.compactMap(HomePin.init(token:)).filter { seen.insert($0).inserted }
        } else {
            pins = HomePin.defaults
        }
        migrateHiddenIconDefaults(defaults)
        reconcileRemoteHomeItems()
    }

    /// One-time move from the old Grid / Medium / Medium strip to List / Large / Large.
    private func migrateHiddenIconDefaults(_ defaults: UserDefaults) {
        let key = "menuBarStripLargeListDefault"
        if defaults.bool(forKey: key) { return }
        defaults.set(true, forKey: key)
        guard menuBarStripIconSize == 24,
              menuBarStripLabelSize == 9,
              menuBarStripLayout == .grid else { return }
        menuBarStripIconSize = MenuBarTool.defaultIconSize
        menuBarStripLabelSize = MenuBarTool.defaultLabelSize
        menuBarStripLayout = .list
        tools.menuBar.setStripIconSize(MenuBarTool.defaultIconSize)
        tools.menuBar.setStripLabelSize(MenuBarTool.defaultLabelSize)
        tools.menuBar.setStripLayout(.list)
    }

    /// Home rows. Storage is part of the Mac page, not its own row.
    var listedHomeTools: [HomeItem] {
        visibleHomeTools.filter(\.showsOnHome)
    }

    var listedHiddenHomeTools: [HomeItem] {
        hiddenHomeTools.filter(\.showsOnHome)
    }

    func moveListedHomeTool(_ tool: HomeItem, to destination: Int) {
        var listed = listedHomeTools
        guard let from = listed.firstIndex(of: tool) else { return }
        let dest = min(max(destination, 0), listed.count - 1)
        guard from != dest else { return }
        let item = listed.remove(at: from)
        listed.insert(item, at: dest)
        var next: [HomeItem] = []
        var placed = false
        for existing in visibleHomeTools {
            if existing.showsOnHome {
                if !placed {
                    next.append(contentsOf: listed)
                    placed = true
                }
            } else {
                next.append(existing)
            }
        }
        if !placed {
            next.append(contentsOf: listed)
        }
        visibleHomeTools = next
        persistHomeLayout()
    }

    func hideHomeTool(_ tool: HomeItem) {
        guard let index = visibleHomeTools.firstIndex(of: tool) else { return }
        visibleHomeTools.remove(at: index)
        if !hiddenHomeTools.contains(tool) {
            hiddenHomeTools.append(tool)
        }
        persistHomeLayout()
    }

    func showHomeTool(_ tool: HomeItem) {
        guard let index = hiddenHomeTools.firstIndex(of: tool) else { return }
        hiddenHomeTools.remove(at: index)
        if !visibleHomeTools.contains(tool) {
            visibleHomeTools.append(tool)
        }
        persistHomeLayout()
    }

    func moveVisibleHomeTool(_ tool: HomeItem, to destination: Int) {
        moveListedHomeTool(tool, to: destination)
    }

    private func persistHomeLayout() {
        UserDefaults.standard.set(visibleHomeTools.map(\.token), forKey: Keys.visibleHomeTools)
        UserDefaults.standard.set(hiddenHomeTools.map(\.token), forKey: Keys.hiddenHomeTools)
    }

    private static func loadHomeLayout(defaults: UserDefaults) -> (visible: [HomeItem], hidden: [HomeItem]) {
        let storedVisible = defaults.stringArray(forKey: Keys.visibleHomeTools)
        let storedHidden = defaults.stringArray(forKey: Keys.hiddenHomeTools)
        guard storedVisible != nil || storedHidden != nil else {
            return (HomeItem.builtins, [])
        }
        var visible = uniqued((storedVisible ?? []).compactMap(HomeItem.init(token:)))
        var hidden = uniqued((storedHidden ?? []).compactMap(HomeItem.init(token:)))
        hidden.removeAll(where: visible.contains)
        let known = Set(visible).union(hidden)
        for item in HomeItem.builtins where !known.contains(item) {
            visible.append(item)
        }
        if visible.isEmpty, hidden.isEmpty {
            return (HomeItem.builtins, [])
        }
        return (visible, hidden)
    }

    private static func uniqued(_ tools: [HomeItem]) -> [HomeItem] {
        var seen = Set<HomeItem>()
        return tools.filter { seen.insert($0).inserted }
    }

    private func reconcileRemoteHomeItems() {
        let ids = Set(remotes.map(\.id))
        pins.removeAll { pin in
            if case .remote(let id) = pin.source { return !ids.contains(id) }
            return false
        }
        visibleHomeTools.removeAll { item in
            if case .remote(let id) = item { return !ids.contains(id) }
            return false
        }
        hiddenHomeTools.removeAll { item in
            if case .remote(let id) = item { return !ids.contains(id) }
            return false
        }
        let known = Set(visibleHomeTools).union(hiddenHomeTools)
        for remote in remotes {
            let item = HomeItem.remote(remote.id)
            if !known.contains(item) {
                visibleHomeTools.append(item)
            }
        }
        persistHomeLayout()
    }

    var activeMenuBarTools: [ToolID] {
        var tools: [ToolID] = []
        if keyboardLocked { tools.append(.keyboard) }
        if scrollReverseEnabled { tools.append(.scroll) }
        if lidSleepDisabled { tools.append(.lid) }
        if awakeActive { tools.append(.awake) }
        if menuBarHideEnabled { tools.append(.menuBar) }
        if voiceListening { tools.append(.voice) }
        return tools
    }

    var mouseSummary: String {
        if mouseNames.isEmpty { return "No mouse connected" }
        if mouseNames.count == 1 { return mouseNames[0] }
        return "\(mouseNames.count) mice connected"
    }

    var cpuPercentLabel: String {
        stats.cpuReady ? StatsFormat.percent(stats.cpuFraction) : "…"
    }

    var ramShortLabel: String {
        guard stats.ramTotal > 0 else { return "…" }
        return "\(StatsFormat.gigabytes(stats.ramUsed)) / \(StatsFormat.gigabytes(stats.ramTotal))"
    }

    var ramGlanceLabel: String {
        guard stats.ramTotal > 0 else { return "…" }
        return StatsFormat.percent(ramFraction)
    }

    var networkGlanceLabel: String {
        networkDownLabel
    }

    var networkDownLabel: String {
        networkRate(stats.network.bytesInPerSecond, arrow: "↓")
    }

    var networkUpLabel: String {
        networkRate(stats.network.bytesOutPerSecond, arrow: "↑")
    }

    var networkBothLabel: String {
        if !stats.network.connected { return "Off" }
        guard stats.network.ratesReady else { return "…" }
        return "\(networkDownLabel)  \(networkUpLabel)"
    }

    private func networkRate(_ bytes: UInt64, arrow: String) -> String {
        if !stats.network.connected { return "Off" }
        guard stats.network.ratesReady else { return "…" }
        return "\(StatsFormat.rate(bytes, compact: true))\(arrow)"
    }

    var ramFraction: Double {
        guard stats.ramTotal > 0 else { return 0 }
        return min(max(Double(stats.ramUsed) / Double(stats.ramTotal), 0), 1)
    }

    var cpuUsageLevel: UsageLevel {
        stats.cpuReady ? UsageLevel(fraction: stats.cpuFraction) : .normal
    }

    var ramUsageLevel: UsageLevel {
        stats.ramTotal > 0 ? UsageLevel(fraction: ramFraction) : .normal
    }

    var memoryPressureLevel: UsageLevel {
        switch stats.memoryPressure {
        case .normal: .normal
        case .warning: .warning
        case .urgent, .critical: .critical
        }
    }

    var thermalLevel: UsageLevel {
        switch stats.thermal {
        case .nominal: .normal
        case .fair: .warning
        case .serious, .critical: .critical
        @unknown default: .normal
        }
    }

    var batteryPercentLabel: String {
        guard let battery = stats.battery else { return "—" }
        return StatsFormat.percent(battery.percent)
    }

    var batteryStatusLabel: String {
        guard let battery = stats.battery else { return "No battery" }
        if battery.isFull { return "Full" }
        if battery.isCharging {
            if let minutes = battery.minutesToFull {
                return "\(StatsFormat.durationMinutes(minutes)) to full"
            }
            return "Charging"
        }
        if let minutes = battery.minutesToEmpty {
            return "\(StatsFormat.durationMinutes(minutes)) left"
        }
        return battery.isPluggedIn ? "Plugged in" : "On battery"
    }

    var batteryUsageLevel: UsageLevel {
        guard let battery = stats.battery, !battery.isCharging, !battery.isFull else { return .normal }
        return .remaining(battery.percent)
    }

    var networkPrimaryLabel: String {
        if !stats.network.connected { return "Offline" }
        if stats.network.ratesReady {
            return "\(StatsFormat.rate(stats.network.bytesInPerSecond, compact: true))↓ \(StatsFormat.rate(stats.network.bytesOutPerSecond, compact: true))↑"
        }
        return stats.network.ssid ?? stats.network.kind
    }

    var networkSecondaryLabel: String {
        if !stats.network.connected { return "No connection" }
        if stats.network.ratesReady {
            return stats.network.ssid ?? stats.network.ipAddress ?? stats.network.kind
        }
        return stats.network.ipAddress ?? stats.network.kind
    }

    var diskFreeLabel: String {
        guard let volume = stats.bootVolume else { return "…" }
        return StatsFormat.gigabytes(volume.free)
    }

    var diskUsedLabel: String {
        guard let volume = stats.bootVolume else { return "…" }
        return StatsFormat.percent(volume.usedFraction)
    }

    var diskUsageLevel: UsageLevel {
        guard let volume = stats.bootVolume else { return .normal }
        return UsageLevel(fraction: volume.usedFraction)
    }

    var powerLabel: String? {
        stats.powerWatts.map(StatsFormat.watts)
    }

    var macRowStats: [MacRowStat] {
        var rows = [
            MacRowStat(label: "CPU", value: cpuPercentLabel, level: cpuUsageLevel),
            MacRowStat(label: "RAM", value: ramGlanceLabel, level: ramUsageLevel)
        ]
        if let power = powerLabel {
            rows.append(MacRowStat(label: "PWR", value: power, level: .normal))
        }
        rows.append(MacRowStat(label: "STO", value: diskUsedLabel, level: diskUsageLevel))
        if stats.network.connected || stats.network.ratesReady {
            rows.append(MacRowStat(label: "NET", value: networkGlanceLabel, level: .normal))
        }
        return rows
    }

    func remoteRowStats(_ id: UUID) -> [MacRowStat] {
        [
            MacRowStat(label: "CPU", value: remoteCPULabel(id), level: remoteCPULevel(id)),
            MacRowStat(label: "RAM", value: remoteRAMGlanceLabel(id), level: remoteRAMLevel(id)),
            MacRowStat(label: "STO", value: remoteDiskGlanceLabel(id), level: remoteDiskLevel(id)),
            MacRowStat(label: "PWR", value: remotePowerLabel(id) ?? "—", level: .normal)
        ]
    }

    var macRowLine: String {
        macRowStats.map { "\($0.label) \($0.value)" }.joined(separator: "  ")
    }

    func title(for item: HomeItem) -> String {
        switch item {
        case .tool(let id): id.title
        case .remote(let id): remotes.first(where: { $0.id == id })?.name ?? "Remote"
        }
    }

    func isPinned(_ pin: HomePin) -> Bool {
        pins.contains(pin)
    }

    func togglePin(_ pin: HomePin) {
        if let index = pins.firstIndex(of: pin) {
            pins.remove(at: index)
            return
        }
        guard pins.count < HomePin.maxCount else { return }
        pins.append(pin)
    }

    func unpin(_ pin: HomePin) {
        pins.removeAll { $0 == pin }
    }

    func glyph(for item: HomeItem) -> GlyphID {
        switch item {
        case .remote(let id):
            GlyphID(remoteSymbol: remote(for: id)?.symbol ?? RemoteSymbol.fallback)
        case .tool(let id):
            id.glyph
        }
    }

    func pinDisplay(_ pin: HomePin) -> PinDisplay? {
        switch pin.source {
        case .mac:
            return PinDisplay(
                pin: pin,
                caption: pin.metric.title,
                value: macPinValue(pin.metric),
                level: macPinLevel(pin.metric),
                glyph: .laptop,
                route: macPinRoute(pin.metric),
                accessibility: "Mac \(pin.metric.title) \(macPinValue(pin.metric))"
            )
        case .remote(let id):
            guard let server = remote(for: id) else { return nil }
            return PinDisplay(
                pin: pin,
                caption: pin.metric.title,
                value: remotePinValue(id, pin.metric),
                level: remotePinLevel(id, pin.metric),
                glyph: GlyphID(remoteSymbol: server.symbol),
                route: .remote(id),
                accessibility: "\(server.name) \(pin.metric.title) \(remotePinValue(id, pin.metric))"
            )
        }
    }

    private func macPinValue(_ metric: PinMetric) -> String {
        switch metric {
        case .cpu: cpuPercentLabel
        case .memory: ramGlanceLabel
        case .storage: diskUsedLabel
        case .network: networkBothLabel
        case .down: networkDownLabel
        case .up: networkUpLabel
        case .power: powerLabel ?? "—"
        case .battery: batteryPercentLabel
        }
    }

    private func macPinLevel(_ metric: PinMetric) -> UsageLevel {
        switch metric {
        case .cpu: cpuUsageLevel
        case .memory: ramUsageLevel
        case .storage: diskUsageLevel
        case .battery: batteryUsageLevel
        case .network, .down, .up, .power: .normal
        }
    }

    private func macPinRoute(_ metric: PinMetric) -> PanelRoute {
        switch metric {
        case .cpu, .memory, .storage, .power, .network, .down, .up, .battery: .machine
        }
    }

    private func remotePinValue(_ id: UUID, _ metric: PinMetric) -> String {
        switch metric {
        case .cpu: remoteCPULabel(id)
        case .memory: remoteRAMGlanceLabel(id)
        case .storage: remoteDiskGlanceLabel(id)
        case .power: remotePowerLabel(id) ?? "—"
        case .network, .down, .up, .battery: "—"
        }
    }

    private func remotePinLevel(_ id: UUID, _ metric: PinMetric) -> UsageLevel {
        switch metric {
        case .cpu: remoteCPULevel(id)
        case .memory: remoteRAMLevel(id)
        case .storage: remoteDiskLevel(id)
        default: .normal
        }
    }

    func remote(for id: UUID) -> RemoteServer? {
        remotes.first(where: { $0.id == id })
    }

    func remoteSample(_ id: UUID) -> RemoteSample {
        remoteSamples[id] ?? .connecting()
    }

    func remoteAvailabilityLabel(_ id: UUID) -> String {
        switch remoteSample(id).status {
        case .connecting: "Connecting..."
        case .offline: "Offline"
        case .auth: "Needs a key"
        case .unsupported: "Needs Linux"
        case .ok: ""
        }
    }

    func remoteCPULabel(_ id: UUID) -> String {
        let sample = remoteSample(id)
        switch sample.status {
        case .connecting: return "…"
        case .ok: return sample.cpuReady ? StatsFormat.percent(sample.cpuFraction) : "…"
        case .auth: return "Needs key"
        case .unsupported: return "Needs Linux"
        case .offline: return "Offline"
        }
    }

    func remoteRAMLabel(_ id: UUID) -> String {
        let sample = remoteSample(id)
        switch sample.status {
        case .connecting: return "…"
        case .ok:
            guard sample.ramTotal > 0 else { return "…" }
            return "\(StatsFormat.gigabytes(sample.ramUsed)) / \(StatsFormat.gigabytes(sample.ramTotal))"
        case .auth, .unsupported, .offline:
            return "—"
        }
    }

    func remoteCPULevel(_ id: UUID) -> UsageLevel {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.cpuReady else { return .normal }
        return UsageLevel(fraction: sample.cpuFraction)
    }

    func remoteRAMLevel(_ id: UUID) -> UsageLevel {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.ramTotal > 0 else { return .normal }
        return UsageLevel(fraction: sample.ramFraction)
    }

    func remotePowerLabel(_ id: UUID) -> String? {
        let sample = remoteSample(id)
        guard sample.status == .ok, let watts = sample.powerWatts else { return nil }
        return StatsFormat.watts(watts)
    }

    struct RemotePowerNote: Equatable {
        var message: String
        var untilReboot: String?
        var keep: String?
    }

    func remotePowerNote(_ id: UUID) -> RemotePowerNote? {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.powerWatts == nil else { return nil }
        switch sample.powerHint {
        case "chmod":
            return RemotePowerNote(
                message: "This user cannot read the power counters.",
                untilReboot: "sudo chmod a+r /sys/class/powercap/intel-rapl:*/energy_uj",
                keep: "printf '%s\\n' 'SUBSYSTEM==\"powercap\", ACTION==\"add\", RUN+=\"/bin/chmod a+r /sys/class/powercap/intel-rapl:*/energy_uj\"' | sudo tee /etc/udev/rules.d/99-rapl.rules >/dev/null && sudo udevadm control --reload-rules && sudo udevadm trigger"
            )
        case "none":
            return RemotePowerNote(message: "This host does not report power.", untilReboot: nil, keep: nil)
        default:
            return nil
        }
    }

    func remoteDiskLevel(_ id: UUID) -> UsageLevel {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.diskTotal > 0 else { return .normal }
        return UsageLevel(fraction: sample.diskFraction)
    }

    func remoteRAMGlanceLabel(_ id: UUID) -> String {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.ramTotal > 0 else {
            return sample.status == .connecting ? "…" : "—"
        }
        return StatsFormat.percent(sample.ramFraction)
    }

    func remoteDiskGlanceLabel(_ id: UUID) -> String {
        let sample = remoteSample(id)
        guard sample.status == .ok, sample.diskTotal > 0 else {
            return sample.status == .connecting ? "…" : "—"
        }
        return StatsFormat.percent(sample.diskFraction)
    }

    func setRemoteSymbol(_ id: UUID, _ symbol: String) {
        remotes = remotes.map { server in
            guard server.id == id else { return server }
            var copy = server
            copy.symbol = RemoteSymbol.resolve(symbol)
            return copy
        }
    }

    func addRemote(name: String, host: String, user: String, port: String, identity: String) -> String? {
        do {
            let parsedPort = try parsePort(port)
            let server = try RemoteCatalog.make(
                host: host,
                name: name,
                user: user,
                port: parsedPort,
                identityPath: identity
            )
            remotes = try RemoteCatalog.adding(server, to: remotes)
            remoteAddNotice = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func updateRemote(id: UUID, name: String, host: String, user: String, port: String, identity: String) -> String? {
        do {
            let parsedPort = try parsePort(port)
            let server = try RemoteCatalog.make(
                host: host,
                name: name,
                user: user,
                port: parsedPort,
                identityPath: identity
            )
            remotes = try RemoteCatalog.replacing(id, with: server, in: remotes)
            remoteAddNotice = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeRemote(_ server: RemoteServer) {
        remotes = remotes.filter { $0.id != server.id }
        remoteSamples[server.id] = nil
        remoteTestNotice[server.id] = nil
        if remoteTestingID == server.id {
            remoteTestingID = nil
        }
    }

    func testRemote(_ server: RemoteServer) {
        remoteTestingID = server.id
        remoteTestNotice[server.id] = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let sample = try RemoteProbe.sampleOnce(server)
                let cpu = sample.cpuReady ? StatsFormat.percent(sample.cpuFraction) : "…"
                let ram: String
                if sample.ramTotal > 0 {
                    ram = "\(StatsFormat.gigabytes(sample.ramUsed)) / \(StatsFormat.gigabytes(sample.ramTotal))"
                } else {
                    ram = "—"
                }
                let notice: String
                if let watts = sample.powerWatts {
                    notice = "CPU \(cpu), RAM \(ram), \(StatsFormat.watts(watts))"
                } else {
                    notice = "CPU \(cpu), RAM \(ram)"
                }
                DispatchQueue.main.async {
                    guard self?.remoteTestingID == server.id else { return }
                    self?.remoteTestingID = nil
                    self?.remoteTestNotice[server.id] = notice
                    self?.remoteSamples[server.id] = sample
                }
            } catch {
                DispatchQueue.main.async {
                    guard self?.remoteTestingID == server.id else { return }
                    self?.remoteTestingID = nil
                    self?.remoteTestNotice[server.id] = error.localizedDescription
                }
            }
        }
    }

    private func parsePort(_ text: String) throws -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let value = Int(trimmed) else {
            throw ToolError.failed("Port must be a number.")
        }
        return value
    }

    var menuBarStatsText: String? {
        switch menuBarStats {
        case .off:
            return nil
        case .cpu:
            return stats.cpuReady ? StatsFormat.percent(stats.cpuFraction) : "…"
        case .battery:
            return stats.battery.map { StatsFormat.percent($0.percent) } ?? "—"
        case .network:
            if !stats.network.connected { return "Offline" }
            guard stats.network.ratesReady else { return "…" }
            return "\(StatsFormat.rate(stats.network.bytesInPerSecond, compact: true))↓ \(StatsFormat.rate(stats.network.bytesOutPerSecond, compact: true))↑"
        }
    }

    @Published var appVersion = UpdateCheckService.currentVersion

    static func gigabytes(_ bytes: UInt64) -> String {
        StatsFormat.gigabytes(bytes)
    }

    func start() {
        refreshAccessibility()
        tools.keyboard.onTimerExpired = { [weak self] in
            DispatchQueue.main.async {
                self?.refreshKeyboardStatus()
            }
        }
        devices.onChange = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.mice = snapshot.mice
                self?.mouseConnected = snapshot.hasExternalMouse
                self?.mouseNames = snapshot.mouseNames
                self?.seedMouseDefaults()
                self?.refreshScrollReverseState()
                if self?.keyboardBusy != true {
                    self?.restoreKeyboardIfNeeded()
                }
            }
        }
        devices.start()
        startVoice()
        restorePersistedTools()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWake()
        }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshAccessibility()
        }

        stateObserver = DistributedNotificationCenter.default().addObserver(
            forName: YeobunPaths.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if (notification.object as? String) == "\(getpid())" { return }
            self?.handleExternalStateChange()
        }

        if !UserDefaults.standard.bool(forKey: Keys.didLaunch) {
            UserDefaults.standard.set(true, forKey: Keys.didLaunch)
            applyLaunchAtLogin()
        } else if launchAtLogin {
            applyLaunchAtLogin()
        }
        syncStatsSampling()
    }

    func stop() {
        accessibilityTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let stateObserver {
            DistributedNotificationCenter.default().removeObserver(stateObserver)
        }
        if let voiceObserver {
            DistributedNotificationCenter.default().removeObserver(voiceObserver)
        }
        voiceSession.stop()
        voiceHotKeys.unregister()
        statsService.stop()
        remoteStatsService.stop()
        updateCheckEpoch += 1
        updateCheckTask?.cancel()
        updateCheckTask = nil
        stopAwakeTick()
        // Leave keyboard mapping, lid sleep, caffeinate, and the scroll helper
        // running so CLI and a quit of the menu-bar app stay independent.
        devices.stop()
    }

    func startStats() {
        panelWantsStats = true
        syncStatsSampling()
    }

    func stopStats() {
        panelWantsStats = false
        syncStatsSampling()
    }

    private func syncStatsSampling() {
        let menuWantsStats = menuBarStats != .off
        if panelWantsStats || menuWantsStats {
            statsService.onUpdate = { [weak self] sample in
                DispatchQueue.main.async {
                    self?.stats = sample
                }
            }
            statsService.start(
                interval: panelWantsStats ? 1.0 : 2.0,
                detail: panelWantsStats
            )
        } else {
            statsService.stop()
        }
        syncRemoteSampling()
    }

    private func syncRemoteSampling() {
        guard panelWantsStats, !remotes.isEmpty else {
            remoteStatsService.stop()
            if !panelWantsStats {
                remoteSamples = [:]
            }
            return
        }
        remoteStatsService.onUpdate = { [weak self] samples in
            DispatchQueue.main.async {
                self?.remoteSamples = samples
            }
        }
        remoteStatsService.start(servers: remotes, interval: 2.0)
    }

    func toggleKeyboard() {
        setKeyboardLocked(!keyboardLocked)
    }

    func toggleLidSleep() {
        setLidSleepDisabled(!lidSleepDisabled)
    }

    func toggleAwake() {
        setAwakeActive(!awakeActive)
    }

    var awakeTileStatus: String {
        if !awakeActive { return "Off" }
        if let remaining = awakeRemainingSeconds {
            return Self.formatAwakeRemaining(remaining, compact: true)
        }
        return "On"
    }

    static func awakeDurationLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: return "Indefinitely"
        case 60: return "1 hour"
        case 120: return "2 hours"
        case 300: return "5 hours"
        default: return "\(minutes) minutes"
        }
    }

    func toggleScrollReverse() {
        setScrollReverseEnabled(!scrollReverseEnabled)
    }

    // MARK: - Menu bar

    var menuBarTileStatus: String {
        if !menuBarHideEnabled { return "Off" }
        return "On"
    }

    static func menuBarIconSizeLabel(_ points: Int) -> String {
        switch points {
        case MenuBarTool.hiddenSize: return "None"
        case 20: return "Small"
        case 32: return "Large"
        default: return "Medium"
        }
    }

    static func menuBarLabelSizeLabel(_ points: Int) -> String {
        switch points {
        case MenuBarTool.hiddenSize: return "None"
        case 9: return "Small"
        case 13: return "Large"
        default: return "Medium"
        }
    }

    func toggleMenuBarHide() {
        setMenuBarHideEnabled(!menuBarHideEnabled)
    }

    func setMenuBarHideEnabled(_ enabled: Bool) {
        guard enabled != menuBarHideEnabled else { return }
        menuBarNotice = nil
        menuBarHideEnabled = enabled
        if enabled {
            menuBarHidden = true
        }
        try? tools.menuBar.setEnabled(enabled, options: ToolOptions())
        clearOverflow()
        updateMenuBarStatus()
    }

    /// Left click on the chevron always opens or closes the strip.
    func chevronClicked() {
        toggleOverflowStrip()
    }

    // MARK: Icons not in the bar

    func toggleOverflowStrip() {
        if overflowStripOpen {
            closeOverflowStrip()
        } else {
            openOverflowStrip()
        }
    }

    func openOverflowStrip() {
        guard menuBarHideEnabled else { return }
        overflowStripOpen = true
        overflowScanned = false
        scanOverflow()
    }

    func closeOverflowStrip() {
        guard overflowStripOpen else { return }
        overflowStripOpen = false
        clearOverflow()
    }

    func scanOverflow() {
        guard menuBarHideEnabled, overflowStripOpen else { return }
        overflowEpoch += 1
        let epoch = overflowEpoch
        screenRecordingGranted = MenuBarOverflowResolver.screenRecordingGranted
        overflowQueue.async { [weak self] in
            let windows = MenuBarOverflow.hiddenByMacOS()
            let identified = MenuBarOverflowResolver.identify(windows: windows)
            DispatchQueue.main.async {
                guard let self, epoch == self.overflowEpoch else { return }
                self.overflowItems = self.prefixedOverflow(identified)
                self.overflowScanned = true
            }
            guard MenuBarOverflowResolver.screenRecordingGranted, !identified.isEmpty else { return }
            Task { [weak self] in
                let captured = await MenuBarOverflowResolver.capture(identified)
                await MainActor.run { [weak self] in
                    guard let self, epoch == self.overflowEpoch else { return }
                    self.overflowItems = self.prefixedOverflow(captured)
                }
            }
        }
    }

    private func clearOverflow() {
        overflowEpoch += 1
        overflowItems = []
        overflowScanned = false
    }

    /// Yeobun first when our own icon is off the bar, so the chevron still opens the panel.
    private func prefixedOverflow(_ items: [OverflowItem]) -> [OverflowItem] {
        let rest = items.filter { !$0.opensYeobun }
        guard isMainStatusItemHidden?() == true else { return rest }
        return [OverflowItem.yeobunPanel()] + rest
    }

    /// Press the real item. Falls back to bringing its app forward.
    func activateOverflowItem(_ item: OverflowItem) {
        if item.opensYeobun {
            requestOpenPanel()
            return
        }
        if MenuBarOverflowResolver.press(item) { return }
        if let name = item.appName,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            app.activate()
        }
    }

    func requestScreenRecording() {
        MenuBarOverflowResolver.requestScreenRecording()
        MenuBarOverflowResolver.openScreenRecordingSettings()
        screenRecordingGranted = MenuBarOverflowResolver.screenRecordingGranted
    }

    /// Called by the status items after they measure themselves.
    func noteMenuBarLayout(valid: Bool) {
        let notice = valid ? nil : "⌘-drag the chevron to the right of the hidden icons"
        if notice != menuBarNotice {
            menuBarNotice = notice
        }
        updateMenuBarStatus()
    }

    func requestOpenPanel(from view: NSView? = nil) {
        openPanel?(view)
    }

    private func refreshMenuBarStatus() {
        let snapshot = tools.menuBar.hardwareSnapshot()
        suppressMenuBarPersist = true
        menuBarHideEnabled = snapshot.enabled
        menuBarHidden = snapshot.hidden
        let sizes = MenuBarTool.resolvedSizes(icon: snapshot.iconSize, label: snapshot.labelSize)
        menuBarStripIconSize = sizes.icon
        menuBarStripLabelSize = sizes.label
        menuBarStripLayout = snapshot.layout
        suppressMenuBarPersist = false
        if !menuBarHideEnabled {
            closeOverflowStrip()
        }
        updateMenuBarStatus()
    }

    private func updateMenuBarStatus() {
        if !menuBarHideEnabled {
            menuBarStatus = "Icons stay in the menu bar"
        } else if menuBarNotice != nil {
            menuBarStatus = "Chevron is on the wrong side"
        } else {
            menuBarStatus = "Hidden icons sit left of the chevron"
        }
    }

    func setScrollReverseEnabled(_ enabled: Bool) {
        guard enabled != scrollReverseEnabled else { return }
        scrollReverseEnabled = enabled
        do {
            try tools.scroll.setEnabled(enabled, mice: mice)
        } catch {
            // Store is on; helper may still be down — surface that in scrollStatus.
        }
        accessibilityTrusted = AccessibilityAuth.hasPermission || ScrollHelperController.shared.isRunning
        updateScrollStatus()
    }

    func unlockKeyboard() {
        setKeyboardLocked(false)
    }

    func setKeyboardLocked(_ locked: Bool) {
        guard !keyboardBusy, locked != keyboardLocked else { return }
        keyboardError = nil
        keyboardLocked = locked
        keyboardBusy = true
        keyboardStatus = locked ? "Locking keyboard…" : "Unlocking keyboard…"
        keyboardEpoch += 1
        let epoch = keyboardEpoch
        keyboardQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.tools.keyboard.setEnabled(locked, options: ToolOptions())
                let snapshot = try self.tools.keyboard.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch else { return }
                    self.keyboardBusy = false
                    self.applyKeyboardSnapshot(snapshot)
                }
            } catch {
                let snapshot = try? self.tools.keyboard.hardwareSnapshot()
                if let snapshot {
                    self.tools.keyboard.syncBacklight(locked: snapshot.locked)
                }
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch else { return }
                    self.keyboardBusy = false
                    if let snapshot {
                        self.applyKeyboardSnapshot(snapshot, persist: true)
                        if snapshot.locked != locked {
                            self.keyboardError = error.localizedDescription
                        }
                    } else {
                        self.tools.keyboard.invalidateIDs()
                        self.keyboardError = error.localizedDescription
                        self.keyboardLocked = false
                        self.tools.keyboard.persistLocked(false)
                        self.keyboardStatus = error.localizedDescription
                    }
                }
            }
        }
    }

    func refreshKeyboardStatus(alignBacklight: Bool = false) {
        let epoch = keyboardEpoch
        keyboardQueue.async { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try self.tools.keyboard.hardwareSnapshot()
                if snapshot.locked {
                    self.tools.keyboard.resumeUITimerIfNeeded()
                    if alignBacklight {
                        self.tools.keyboard.syncBacklight(locked: true)
                    }
                } else {
                    self.tools.keyboard.restoreBacklightIfNeeded()
                }
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch, !self.keyboardBusy else { return }
                    self.applyKeyboardSnapshot(snapshot)
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch, !self.keyboardBusy else { return }
                    self.keyboardLocked = false
                    self.keyboardStatus = message
                }
            }
        }
    }

    func setDimKeyboardWhenLocked(_ enabled: Bool) {
        dimKeyboardWhenLocked = enabled
        syncBacklightWithLock()
    }

    private func syncBacklightWithLock() {
        guard keyboardLocked, !keyboardBusy else { return }
        keyboardQueue.async { [weak self] in
            self?.tools.keyboard.syncBacklight(locked: true)
        }
    }

    private func applyKeyboardSnapshot(_ snapshot: KeyboardLockService.Snapshot, persist: Bool = false) {
        keyboardLocked = snapshot.locked
        if persist {
            tools.keyboard.persistLocked(snapshot.locked)
        }
        if snapshot.locked {
            if let remaining = snapshot.remainingMinutes {
                keyboardStatus = "Locked · unlocks in \(remaining) min"
            } else {
                keyboardStatus = "Locked until you unlock or restart"
            }
        } else {
            keyboardStatus = "Unlocked"
        }
    }

    func setLidSleepDisabled(_ disabled: Bool) {
        guard !lidBusy, disabled != lidSleepDisabled else { return }
        lidError = nil
        lidSleepDisabled = disabled
        lidBusy = true
        lidStatus = disabled ? "Ignoring lid close…" : "Allowing lid sleep…"
        lidEpoch += 1
        let epoch = lidEpoch
        lidQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.tools.lid.setEnabled(disabled, options: ToolOptions())
                let snapshot = self.tools.lid.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.lidEpoch else { return }
                    self.lidBusy = false
                    self.applyLidSnapshot(snapshot)
                }
            } catch {
                let snapshot = self.tools.lid.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.lidEpoch else { return }
                    self.lidBusy = false
                    self.lidError = error.localizedDescription
                    self.applyLidSnapshot(snapshot)
                }
            }
        }
    }

    func refreshLidStatus() {
        let epoch = lidEpoch
        lidQueue.async { [weak self] in
            guard let self else { return }
            self.tools.lid.restore()
            let snapshot = self.tools.lid.hardwareSnapshot()
            DispatchQueue.main.async {
                guard epoch == self.lidEpoch, !self.lidBusy else { return }
                self.applyLidSnapshot(snapshot)
            }
        }
    }

    private func applyLidSnapshot(_ snapshot: LidSleepService.Snapshot) {
        lidSleepDisabled = snapshot.disabled
        if snapshot.disabled {
            lidStatus = "Stays on with the lid closed"
        } else {
            lidStatus = "Sleeps when the lid closes"
        }
    }

    func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func isScrollReverseOn(for id: String) -> Bool {
        scrollReverseByDevice[id] ?? true
    }

    func setScrollReverse(for id: String, enabled: Bool) {
        scrollReverseByDevice[id] = enabled
        tools.scroll.setDevice(id: id, enabled: enabled, mice: mice)
        accessibilityTrusted = AccessibilityAuth.hasPermission || ScrollHelperController.shared.isRunning
        updateScrollStatus()
    }

    func scrollReverseBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.isScrollReverseOn(for: id) },
            set: { self.setScrollReverse(for: id, enabled: $0) }
        )
    }

    private func seedMouseDefaults() {
        if tools.scroll.seedMouseDefaults(mice) {
            scrollReverseByDevice = ToolStateStore.shared.current.scrollReverseByDevice
        }
    }

    private func refreshScrollReverseState() {
        tools.scroll.apply(mice: mice)
        accessibilityTrusted = AccessibilityAuth.hasPermission || ScrollHelperController.shared.isRunning
        updateScrollStatus()
    }

    private func handleWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.devices.refresh()
            self.refreshScrollReverseState()
            if self.keyboardLocked {
                self.reapplyKeyboardLock()
            } else {
                self.keyboardQueue.async {
                    self.tools.keyboard.invalidateIDs()
                    DispatchQueue.main.async {
                        self.refreshKeyboardStatus(alignBacklight: true)
                    }
                }
            }
        }
    }

    /// Re-apply last-on tools after a relaunch, then read lid sleep from `pmset`.
    /// Keyboard lock is only restored for the same boot — a reboot always
    /// unlocks, so you cannot trap yourself out of the built-in keys.
    func restorePersistedTools() {
        restoreKeyboardIfNeeded()
        refreshLidStatus()
        restoreAwakeIfNeeded()
        refreshScrollReverseState()
        refreshMenuBarStatus()
    }

    /// Read each tool from the Mac and restore anything that dropped.
    func checkStatus() {
        guard !statusCheckBusy else { return }
        statusCheckBusy = true
        statusCheckNotice = nil
        restorePersistedTools()
        devices.refresh()
        refreshAccessibility()
        refreshScrollReverseState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.statusCheckBusy = false
            self.statusCheckNotice = "Status updated"
        }
    }

    func checkLatestVersion() {
        guard !updateCheckBusy else { return }
        updateCheckBusy = true
        updateCheckNotice = nil
        newerVersion = nil
        latestReleaseURL = nil
        updateCheckEpoch += 1
        let epoch = updateCheckEpoch
        updateCheckTask?.cancel()
        updateCheckTask = UpdateCheckService.fetchLatest { [weak self] result in
            DispatchQueue.main.async {
                guard let self, epoch == self.updateCheckEpoch else { return }
                self.updateCheckBusy = false
                self.updateCheckTask = nil
                switch result {
                case .success(let release):
                    self.latestReleaseURL = release.pageURL
                    switch UpdateCheckService.compare(latest: release.version, current: self.appVersion) {
                    case .orderedDescending:
                        self.newerVersion = release.version
                        self.updateCheckNotice = "\(release.version) is available"
                    case .orderedSame:
                        self.updateCheckNotice = "Up to date"
                    case .orderedAscending:
                        self.updateCheckNotice = "This build is newer than the latest release"
                    }
                case .failure(let error):
                    self.updateCheckNotice = error.localizedDescription
                }
            }
        }
    }

    func openLatestRelease() {
        let url = latestReleaseURL ?? UpdateCheckService.releasesPageURL
        NSWorkspace.shared.open(url)
    }

    private func restoreKeyboardIfNeeded() {
        let epoch = keyboardEpoch
        keyboardQueue.async { [weak self] in
            guard let self else { return }
            self.tools.keyboard.restore()
            do {
                let snapshot = try self.tools.keyboard.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch, !self.keyboardBusy else { return }
                    self.applyKeyboardSnapshot(snapshot)
                }
            } catch {
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch, !self.keyboardBusy else { return }
                    self.keyboardLocked = false
                    self.keyboardStatus = error.localizedDescription
                }
            }
        }
    }

    private func reapplyKeyboardLock() {
        keyboardError = nil
        keyboardBusy = true
        keyboardStatus = "Locking keyboard…"
        keyboardEpoch += 1
        let epoch = keyboardEpoch
        keyboardQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.tools.keyboard.reapplyLock()
                let snapshot = try self.tools.keyboard.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch else { return }
                    self.keyboardBusy = false
                    self.applyKeyboardSnapshot(snapshot)
                }
            } catch {
                let snapshot = try? self.tools.keyboard.hardwareSnapshot()
                DispatchQueue.main.async {
                    guard epoch == self.keyboardEpoch else { return }
                    self.keyboardBusy = false
                    self.keyboardError = error.localizedDescription
                    if let snapshot {
                        self.applyKeyboardSnapshot(snapshot, persist: true)
                    } else {
                        self.keyboardStatus = error.localizedDescription
                    }
                }
            }
        }
    }

    func setAwakeActive(_ active: Bool) {
        awakeError = nil
        if active {
            if awakeActive, tools.awake.hardwareSnapshot().active { return }
            startAwake()
        } else {
            if !awakeActive, !tools.awake.hardwareSnapshot().active { return }
            stopAwake()
        }
    }

    private func startAwake() {
        awakeError = nil
        do {
            try tools.awake.setEnabled(true, options: ToolOptions(minutes: awakeMinutes))
        } catch {
            stopAwakeTick()
            awakeActive = false
            awakeRemainingSeconds = nil
            awakeError = error.localizedDescription
            awakeStatus = error.localizedDescription
            return
        }
        applyAwakeSnapshot(tools.awake.hardwareSnapshot())
        startAwakeTick()
    }

    private func stopAwake() {
        stopAwakeTick()
        try? tools.awake.setEnabled(false, options: ToolOptions())
        awakeActive = false
        awakeRemainingSeconds = nil
        awakeStatus = "Sleeps on idle"
    }

    private func handleAwakeExpired() {
        stopAwakeTick()
        tools.awake.noteExpired()
        awakeActive = false
        awakeRemainingSeconds = nil
        awakeStatus = "Sleeps on idle"
    }

    private func restoreAwakeIfNeeded() {
        tools.awake.restore()
        let snapshot = tools.awake.hardwareSnapshot()
        if snapshot.active {
            applyAwakeSnapshot(snapshot)
            startAwakeTick()
        } else if awakeActive {
            stopAwakeTick()
            awakeActive = false
            awakeRemainingSeconds = nil
            awakeStatus = "Sleeps on idle"
        }
    }

    private func applyAwakeSnapshot(_ snapshot: CaffeinateService.Snapshot) {
        awakeActive = snapshot.active
        awakeRemainingSeconds = snapshot.remainingSeconds
        if snapshot.active {
            if let remaining = snapshot.remainingSeconds {
                awakeStatus = "Won't sleep · \(Self.formatAwakeRemaining(remaining, compact: false)) left"
            } else {
                awakeStatus = "Won't sleep until you turn it off"
            }
        } else {
            awakeStatus = "Sleeps on idle"
        }
    }

    private func startAwakeTick() {
        guard awakeTick == nil else { return }
        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshAwakeRemaining()
        }
        tick.tolerance = 0.25
        RunLoop.main.add(tick, forMode: .common)
        awakeTick = tick
    }

    private func stopAwakeTick() {
        awakeTick?.invalidate()
        awakeTick = nil
    }

    private func refreshAwakeRemaining() {
        let snapshot = tools.awake.hardwareSnapshot()
        if snapshot.active {
            applyAwakeSnapshot(snapshot)
        } else if awakeActive {
            handleAwakeExpired()
        }
    }

    private static func formatAwakeRemaining(_ seconds: Int, compact: Bool) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            if compact {
                return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
            }
            if minutes > 0 {
                return "\(hours) hr \(minutes) min"
            }
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            if compact { return "\(minutes) min" }
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }
        return compact ? "\(seconds)s" : "\(seconds) sec"
    }

    private static func currentBootTime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return TimeInterval(boot.tv_sec)
    }

    private static func isCurrentBoot(_ saved: TimeInterval) -> Bool {
        guard saved > 0 else { return false }
        return abs(saved - currentBootTime()) < 1
    }

    func refreshAccessibility() {
        let recording = MenuBarOverflowResolver.screenRecordingGranted
        if recording != screenRecordingGranted {
            screenRecordingGranted = recording
        }
        let trusted = AccessibilityAuth.hasPermission || ScrollHelperController.shared.isRunning
        let changed = trusted != accessibilityTrusted
        accessibilityTrusted = trusted
        if changed {
            refreshScrollReverseState()
            refreshVoiceStatus()
        } else {
            updateScrollStatus()
        }
        let microphoneDenied = VoiceMicrophone.permission == .denied
        if microphoneDenied != voiceMicrophoneDenied {
            voiceMicrophoneDenied = microphoneDenied
        }
    }

    // MARK: - Voice typing

    var voiceTileStatus: String {
        if !voiceEnabled { return "Off" }
        return voiceListening ? "Listening" : "On"
    }

    func toggleVoiceEnabled() {
        setVoiceEnabled(!voiceEnabled)
    }

    /// The master switch. Off ends any session and drops the global shortcut.
    func setVoiceEnabled(_ enabled: Bool) {
        voiceError = nil
        if !enabled {
            voiceSession.stop()
        }
        voiceEnabled = enabled
        tools.voice.turn(enabled)
        syncVoiceHotKey()
        refreshVoiceStatus()
    }

    var voiceHasTranscript: Bool {
        !voiceTranscript.isEmpty || !voicePartial.isEmpty
    }

    func toggleVoice() {
        guard voiceEnabled else { return }
        voiceError = nil
        voiceSession.toggle()
    }

    func setVoiceListening(_ listening: Bool) {
        guard voiceEnabled || !listening else { return }
        voiceError = nil
        if listening {
            voiceSession.start()
        } else {
            voiceSession.stop()
        }
    }

    func clearVoiceTranscript() {
        voiceTranscript = ""
        voicePartial = ""
    }

    func copyVoiceTranscript() {
        let text = [voiceTranscript, voicePartial]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// `soundsLike` is a comma-separated list of what the recognizer writes instead.
    func addVoiceTerm(_ text: String, soundsLike: String) {
        let term = VoiceTerm(text: VoiceVocabulary.tidy(text), soundsLike: VoiceVocabulary.aliases(from: soundsLike))
        guard !term.text.isEmpty else { return }
        voiceVocabulary = VoiceVocabulary.adding(term, to: voiceVocabulary)
    }

    func removeVoiceTerm(_ term: VoiceTerm) {
        voiceVocabulary = VoiceVocabulary.removing(term.text, from: voiceVocabulary)
    }

    /// The recorder swallows the next key press, so the live shortcut steps aside.
    func setVoiceShortcutRecording(_ recording: Bool) {
        if recording {
            voiceHotKeys.unregister()
        } else {
            syncVoiceHotKey()
        }
    }

    /// The shortcut exists only while the tool is on.
    private func syncVoiceHotKey() {
        if voiceEnabled {
            voiceHotKeys.register(voiceHotKey)
        } else {
            voiceHotKeys.unregister()
        }
    }

    func openMicrophoneSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    static func voiceSilenceLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Never"
        case 60: return "1 minute"
        default: return "\(seconds) seconds"
        }
    }

    private func startVoice() {
        tools.voice.driver = voiceSession
        tools.voice.restore()
        voiceSession.localeIdentifier = voiceLocale
        voiceSession.silenceSeconds = voiceSilenceSeconds
        voiceSession.typesText = voiceTypesText
        voiceSession.vocabulary = voiceVocabulary
        voiceSession.onPhase = { [weak self] phase in
            self?.applyVoicePhase(phase)
        }
        voiceSession.onPartial = { [weak self] text in
            self?.voicePartial = text
        }
        voiceSession.onPhrase = { [weak self] text in
            guard let self else { return }
            voiceTranscript = voiceTranscript.isEmpty ? text : voiceTranscript + " " + text
        }
        voiceHotKeys.onPress = { [weak self] in
            self?.toggleVoice()
        }
        syncVoiceHotKey()
        voiceObserver = DistributedNotificationCenter.default().addObserver(
            forName: YeobunPaths.voiceCommandNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.setVoiceListening((notification.object as? String) == "on")
        }
        voiceMicrophoneDenied = VoiceMicrophone.permission == .denied
        refreshVoiceStatus()
        loadVoiceLocales()
    }

    private func applyVoicePhase(_ phase: VoiceSession.Phase) {
        switch phase {
        case .idle:
            voiceListening = false
            voiceBusy = false
        case .requestingMicrophone:
            voiceBusy = true
        case .preparing:
            voiceBusy = true
        case .listening:
            voiceListening = true
            voiceBusy = false
        case .failed(let message):
            voiceListening = false
            voiceBusy = false
            voiceError = message
        }
        voiceMicrophoneDenied = VoiceMicrophone.permission == .denied
        refreshVoiceStatus()
    }

    private func refreshVoiceStatus() {
        guard voiceEnabled else {
            voiceStatus = "Off. The shortcut and microphone are not in use"
            return
        }
        switch voiceSession.phase {
        case .idle, .failed:
            voiceStatus = "Press \(voiceHotKey.display) anywhere to start"
        case .requestingMicrophone:
            voiceStatus = "Waiting for microphone access…"
        case .preparing(let message):
            voiceStatus = message
        case .listening:
            if !voiceTypesText {
                voiceStatus = "Listening. Text stays in this panel"
            } else if !accessibilityTrusted {
                voiceStatus = "Listening. Allow Accessibility to type into apps"
            } else {
                voiceStatus = "Listening. Typing into the front app"
            }
        }
    }

    private func loadVoiceLocales() {
        let stored = voiceLocale
        Task { @MainActor [weak self] in
            let engine = VoiceEngineFactory.make()
            let locales = await engine.supportedLocales()
            var choices = locales
                .map { VoiceLocaleChoice(id: $0.identifier, name: VoiceEngineFactory.localeName($0)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if !stored.isEmpty, !choices.contains(where: { $0.id == stored }) {
                choices.append(VoiceLocaleChoice(id: stored, name: VoiceEngineFactory.localeName(Locale(identifier: stored))))
            }
            let system = VoiceEngineFactory.localeName(.current)
            choices.insert(VoiceLocaleChoice(id: "", name: "System (\(system))"), at: 0)
            self?.voiceLocaleChoices = choices
        }
    }

    private func updateScrollStatus() {
        if mice.isEmpty {
            scrollStatus = "Connect a mouse to reverse its wheel"
            return
        }
        if !scrollReverseEnabled {
            scrollStatus = "Follows System Settings"
            return
        }
        if !mice.contains(where: { isScrollReverseOn(for: $0.id) }) {
            scrollStatus = "No mouse selected"
            return
        }
        if ScrollHelperController.shared.isRunning {
            scrollStatus = "Mouse wheel is reversed"
        } else if !accessibilityTrusted {
            scrollStatus = "Allow Accessibility to reverse scroll"
        } else {
            scrollStatus = "Unable to reverse scroll. Turn Yeobun off and on in Accessibility, then reopen Yeobun."
        }
    }

    private func handleExternalStateChange() {
        ToolStateStore.shared.reload()
        let state = ToolStateStore.shared.current
        suppressAwakeRestart = true
        autoUnlockMinutes = state.autoUnlockMinutes
        dimKeyboardWhenLocked = state.dimKeyboardWhenLocked
        scrollReverseEnabled = state.scrollReverseEnabled
        scrollReverseByDevice = state.scrollReverseByDevice
        awakeMinutes = [0, 5, 10, 15, 30, 60, 120, 300].contains(state.awakeMinutes)
            ? state.awakeMinutes
            : awakeMinutes
        suppressAwakeRestart = false
        if state.voiceEnabled != voiceEnabled {
            if !state.voiceEnabled {
                voiceSession.stop()
            }
            voiceEnabled = state.voiceEnabled
            syncVoiceHotKey()
            refreshVoiceStatus()
        }
        voiceLocale = state.voiceLocale
        voiceHotKey = state.voiceHotKey
        voiceSilenceSeconds = state.voiceSilenceSeconds
        voiceTypesText = state.voiceTypesText
        voiceVocabulary = state.voiceVocabulary
        let nextRemotes = RemoteCatalog.clean(state.remotes)
        if nextRemotes != remotes {
            remotes = nextRemotes
        }
        refreshKeyboardStatus(alignBacklight: true)
        refreshLidStatus()
        restoreAwakeIfNeeded()
        refreshScrollReverseState()
        refreshAccessibility()
        refreshMenuBarStatus()
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginItemNotice = "Unable to update Open at login"
        }
    }
}

struct VoiceLocaleChoice: Identifiable, Hashable {
    let id: String
    let name: String
}
