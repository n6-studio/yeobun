import SwiftUI

enum HomeMetrics {
    static let row: CGFloat = 52
    static let statRow: CGFloat = 76
    static let gap: CGFloat = 8
    static let maxScroll: CGFloat = 640
}

struct HomeList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation

    @State private var dragging: HomeItem?
    @State private var dragStartIndex = 0
    @State private var dragLocation: CGPoint = .zero
    @State private var dragGrab: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            stack
        }
        .scrollDisabled(presentation.isEditingHome)
        .frame(maxHeight: presentation.isEditingHome ? .infinity : HomeMetrics.maxScroll)
        .animation(nil, value: presentation.isEditingHome)
        .onChange(of: presentation.isEditingHome) { _, editing in
            if !editing { cancelDrag() }
        }
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: HomeMetrics.gap) {
            if !model.pins.isEmpty {
                PinStrip(editing: presentation.isEditingHome)
            }

            if rows.isEmpty {
                if !presentation.isEditingHome, model.pins.isEmpty {
                    Text("Nothing on Home")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            } else {
                rowStack
            }

            if presentation.isEditingHome, !model.listedHiddenHomeTools.isEmpty {
                Text("Hidden")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)

                GroupedPanel {
                    ForEach(Array(model.listedHiddenHomeTools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 {
                            Divider()
                        }
                        HiddenHomeRow(glyph: model.glyph(for: tool), title: model.title(for: tool)) {
                            model.showHomeTool(tool)
                        }
                    }
                }
            }
        }
    }

    private var rowStack: some View {
        VStack(spacing: HomeMetrics.gap) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, tool in
                row(tool)
                    .stagger(index: index, generation: presentation.generation)
            }
        }
        .coordinateSpace(name: "homeList")
        .overlay(alignment: .topLeading) {
            GeometryReader { geo in
                if let dragging {
                    ConsoleRow(
                        item: dragging,
                        title: model.title(for: dragging),
                        status: status(for: dragging),
                        isOn: isOn(dragging),
                        isBusy: false,
                        editing: true
                    )
                    .frame(width: geo.size.width, height: rowHeight(for: dragging))
                    .offset(y: dragCardY(in: geo.size.height))
                    .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
        .overlay {
            if presentation.isEditingHome {
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .highPriorityGesture(rowReorder)
                        .help("Drag to reorder")
                    Color.clear
                        .frame(width: 36)
                        .allowsHitTesting(false)
                }
            }
        }
        .clipShape(Rectangle())
    }

    private var rows: [HomeItem] {
        model.listedHomeTools
    }

    private func row(_ tool: HomeItem) -> some View {
        ZStack(alignment: .trailing) {
            if dragging == tool {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(ModuleColor.offFill)
                    .frame(maxWidth: .infinity)
                    .frame(height: rowHeight(for: tool))
            } else {
                ConsoleRow(
                    item: tool,
                    title: model.title(for: tool),
                    status: status(for: tool),
                    isOn: isOn(tool),
                    isBusy: isBusy(tool),
                    editing: presentation.isEditingHome
                )
                .allowsHitTesting(!presentation.isEditingHome)
            }

            if presentation.isEditingHome, dragging != tool {
                HideBadge(label: "Hide \(model.title(for: tool))") {
                    cancelDrag()
                    model.hideHomeTool(tool)
                }
                .padding(.trailing, 8)
            }
        }
    }

    private func status(for tool: HomeItem) -> String {
        switch tool {
        case .tool(.keyboard): model.keyboardLocked ? "On" : "Off"
        case .tool(.scroll): model.scrollReverseEnabled ? "On" : "Off"
        case .tool(.lid): model.lidSleepDisabled ? "On" : "Off"
        case .tool(.awake): model.awakeTileStatus
        case .tool(.menuBar): model.menuBarTileStatus
        case .tool(.voice): model.voiceTileStatus
        case .tool(.machine): model.macRowLine
        case .tool(.battery): model.batteryPercentLabel
        case .tool(.network): model.networkGlanceLabel
        case .tool(.storage): model.diskUsedLabel
        case .remote(let id):
            model.remoteSample(id).status == .ok
                ? model.remoteRowStats(id).map { "\($0.label) \($0.value)" }.joined(separator: ", ")
                : model.remoteAvailabilityLabel(id)
        }
    }

    private func isOn(_ tool: HomeItem) -> Bool {
        switch tool {
        case .tool(.keyboard): model.keyboardLocked
        case .tool(.scroll): model.scrollReverseEnabled
        case .tool(.lid): model.lidSleepDisabled
        case .tool(.awake): model.awakeActive
        case .tool(.menuBar): model.menuBarHideEnabled
        case .tool(.voice): model.voiceEnabled
        default: false
        }
    }

    private func isBusy(_ tool: HomeItem) -> Bool {
        switch tool {
        case .tool(.keyboard): model.keyboardBusy
        case .tool(.lid): model.lidBusy
        case .tool(.voice): model.voiceBusy
        default: false
        }
    }

    private var rowReorder: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("homeList"))
            .onChanged { value in
                guard presentation.isEditingHome else { return }
                if dragging == nil {
                    guard let index = index(at: value.startLocation), rows.indices.contains(index) else { return }
                    dragging = rows[index]
                    dragStartIndex = index
                    dragGrab = value.startLocation.y - originY(of: index)
                }
                dragLocation = value.location
                guard let tool = dragging, let current = rows.firstIndex(of: tool) else { return }
                let finger = value.location.y
                if current > 0 {
                    let above = originY(of: current - 1) + rowHeight(for: rows[current - 1]) / 2
                    if finger < above {
                        model.moveListedHomeTool(tool, to: current - 1)
                        return
                    }
                }
                if current + 1 < rows.count {
                    let below = originY(of: current + 1) + rowHeight(for: rows[current + 1]) / 2
                    if finger > below {
                        model.moveListedHomeTool(tool, to: current + 1)
                    }
                }
            }
            .onEnded { _ in
                cancelDrag()
            }
    }

    private func rowHeight(for item: HomeItem) -> CGFloat {
        switch item {
        case .tool(.machine):
            HomeMetrics.statRow
        case .remote(let id):
            model.remoteSample(id).status == .ok ? HomeMetrics.statRow : HomeMetrics.row
        default:
            HomeMetrics.row
        }
    }

    private func index(at point: CGPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        var y: CGFloat = 0
        for (index, item) in rows.enumerated() {
            let height = rowHeight(for: item) + HomeMetrics.gap
            if point.y < y + height { return index }
            y += height
        }
        return rows.count - 1
    }

    private func originY(of index: Int) -> CGFloat {
        rows.prefix(index).reduce(0) { partial, item in
            partial + rowHeight(for: item) + HomeMetrics.gap
        }
    }

    private func dragCardY(in height: CGFloat) -> CGFloat {
        let card = dragging.map { rowHeight(for: $0) } ?? HomeMetrics.row
        let proposed = dragLocation.y - dragGrab
        let limit = max(0, height - card)
        return min(max(0, proposed), limit)
    }

    private func cancelDrag() {
        dragging = nil
        dragLocation = .zero
        dragGrab = 0
    }
}

struct PinStrip: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation
    var editing: Bool

    private var cells: [PinDisplay] {
        model.pins.compactMap { model.pinDisplay($0) }
    }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: HomeMetrics.gap),
            count: min(4, max(cells.count, 1))
        )
        LazyVGrid(columns: columns, spacing: HomeMetrics.gap) {
            ForEach(cells) { cell in
                ZStack(alignment: .topTrailing) {
                    Button {
                        presentation.open(cell.route)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                GlyphIcon(id: cell.glyph)
                                    .frame(width: GlyphSlot.pin, height: GlyphSlot.pin)
                                    .foregroundStyle(.secondary)
                                Text(cell.caption)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(cell.value)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(cell.level.tint ?? Color.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(ModuleColor.offFill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .disabled(editing)
                    .accessibilityLabel(cell.accessibility)

                    if editing {
                        Button {
                            model.unpin(cell.pin)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.red)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Unpin \(cell.caption)")
                    }
                }
            }
        }
    }
}

struct GlanceCell: Identifiable {
    let id: String
    let caption: String
    let value: String
    let level: UsageLevel
    let route: PanelRoute
    let accessibility: String
}

struct GlanceStrip: View {
    @EnvironmentObject private var presentation: PanelPresentation
    let cells: [GlanceCell]

    var body: some View {
        HStack(spacing: HomeMetrics.gap) {
            ForEach(cells) { cell in
                Button {
                    presentation.open(cell.route)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cell.caption)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(cell.value)
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(cell.level.tint ?? Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(ModuleColor.offFill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                }
                .buttonStyle(PressScaleButtonStyle())
                .accessibilityLabel(cell.accessibility)
            }
        }
    }
}

struct ConsoleRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var presentation: PanelPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: HomeItem
    let title: String
    let status: String
    let isOn: Bool
    let isBusy: Bool
    var editing = false

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    RowGlyph(
                        glyph: model.glyph(for: item),
                        isOn: isOn,
                        accent: item.accent
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let columns = statColumns {
                            HStack(alignment: .top, spacing: 6) {
                                ForEach(columns) { stat in
                                    Color.clear
                                        .frame(height: 26)
                                        .frame(maxWidth: .infinity)
                                        .overlay(alignment: .topLeading) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(stat.label)
                                                    .font(.system(size: 9, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                                Text(stat.value)
                                                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                                    .foregroundStyle(stat.level.tint ?? Color.primary)
                                            }
                                            .lineLimit(1)
                                        }
                                        .clipped()
                                }
                            }
                        } else {
                            Text(status)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScaleButtonStyle())
            .disabled(editing)
            .accessibilityLabel(title)
            .accessibilityValue(isBusy ? "Working, \(status)" : status)
            .accessibilityHint(item.isToggle ? "Shows options" : "Shows details")

            if !editing {
                trailing
            } else {
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(ConsoleRowBackdrop(isOn: isOn, hovering: hovering, accent: item.accent))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: hovering)
        .animation(reduceMotion ? nil : Motion.enter, value: isOn)
    }

    @ViewBuilder
    private var trailing: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Working")
        } else if item.isToggle {
            Toggle(title, isOn: toggleBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var toggleBinding: Binding<Bool> {
        switch item {
        case .tool(.keyboard):
            Binding(get: { model.keyboardLocked }, set: { model.setKeyboardLocked($0) })
        case .tool(.scroll):
            Binding(get: { model.scrollReverseEnabled }, set: { model.setScrollReverseEnabled($0) })
        case .tool(.lid):
            Binding(get: { model.lidSleepDisabled }, set: { model.setLidSleepDisabled($0) })
        case .tool(.awake):
            Binding(get: { model.awakeActive }, set: { model.setAwakeActive($0) })
        case .tool(.menuBar):
            Binding(get: { model.menuBarHideEnabled }, set: { model.setMenuBarHideEnabled($0) })
        case .tool(.voice):
            Binding(get: { model.voiceEnabled }, set: { model.setVoiceEnabled($0) })
        default:
            .constant(false)
        }
    }

    private var rowHeight: CGFloat {
        switch item {
        case .tool(.machine):
            HomeMetrics.statRow
        case .remote(let id):
            model.remoteSample(id).status == .ok ? HomeMetrics.statRow : HomeMetrics.row
        default:
            HomeMetrics.row
        }
    }

    private var statColumns: [MacRowStat]? {
        switch item {
        case .tool(.machine):
            model.macRowStats
        case .remote(let id):
            model.remoteSample(id).status == .ok ? model.remoteRowStats(id) : nil
        default:
            nil
        }
    }

    private func open() {
        presentation.open(item.route)
    }
}

struct ConsoleRowBackdrop: View {
    var isOn: Bool
    var hovering: Bool
    var accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(fill)
            .overlay {
                if isOn {
                    HStack(spacing: 0) {
                        accent.frame(width: 3)
                        Spacer(minLength: 0)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
    }

    private var fill: Color {
        if isOn {
            return accent.opacity(hovering ? ModuleColor.onFillHover : ModuleColor.onFill)
        }
        return hovering ? ModuleColor.offFillHover : ModuleColor.offFill
    }
}

struct RowGlyph: View {
    let glyph: GlyphID
    let isOn: Bool
    let accent: Color

    var body: some View {
        StateSymbol(glyph: glyph, isActive: isOn, size: GlyphSlot.row)
            .foregroundStyle(isOn ? accent : Color.primary)
            .frame(width: 28, height: 28)
            .background(isOn ? accent.opacity(0.22) : ModuleColor.glyphOffFill, in: Circle())
            .accessibilityHidden(true)
    }
}

struct ListeningBars: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<16, id: \.self) { index in
                    Capsule()
                        .fill(ModuleColor.voice.opacity(active ? 0.9 : 0.35))
                        .frame(width: 3, height: height(index: index, time: t))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        }
        .accessibilityHidden(true)
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard active else { return 4 }
        let wave = abs(sin(time * 4 + Double(index) * 0.45))
        return 4 + 14 * wave
    }
}

struct AwakeDurationChips: View {
    @Binding var minutes: Int
    let choices: [Int]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duration")
                .font(.system(size: 13))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(choices, id: \.self) { choice in
                    let selected = minutes == choice
                    Button {
                        minutes = choice
                    } label: {
                        Text(label(choice))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(selected ? ModuleColor.awake : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                selected ? ModuleColor.awake.opacity(0.2) : ModuleColor.offFill,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(AppModel.awakeDurationLabel(choice))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private func label(_ minutes: Int) -> String {
        switch minutes {
        case 0: "∞"
        case 60: "1h"
        case 120: "2h"
        case 300: "5h"
        default: "\(minutes)m"
        }
    }
}

private struct HideBadge: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.red)
                .font(.system(size: 16, weight: .semibold))
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct HiddenHomeRow: View {
    let glyph: GlyphID
    let title: String
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: 10) {
                GlyphIcon(id: glyph)
                    .foregroundStyle(.primary)
                    .frame(width: GlyphSlot.row, height: GlyphSlot.row)
                    .frame(width: 28, height: 28)
                    .background(ModuleColor.offFill, in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.green)
                    .font(.system(size: 16, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel("Show \(title)")
    }
}
