import AppKit
import SwiftUI

/// Contents of the peek strip: one tile per icon macOS hid.
///
/// Hover lives in an object rather than `@State`: with the Command Line
/// Tools SDK, `@State` in this file resolves to a macro that is not shipped.
final class HoverFlag: ObservableObject {
    @Published var on = false
}

struct OverflowStrip: View {
    static let columns = 4
    static let largeColumns = 3
    static let gutter: CGFloat = 4

    let items: [OverflowItem]
    var accessibility = true
    var layout: MenuBarStripLayout = .grid
    var iconSize: CGFloat = 24
    var labelSize: CGFloat = 9
    let onPress: (OverflowItem) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                Text(accessibility ? "No hidden icons" : "Allow Accessibility to list hidden icons")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .frame(width: panelWidth)
                    .frame(minHeight: emptyHeight)
            } else if layout == .list {
                list
            } else {
                grid
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .padding(6)
        .fixedSize()
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: Self.gutter) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.gutter) {
                    ForEach(row) { item in
                        OverflowTile(
                            item: item,
                            layout: .grid,
                            iconSize: iconSize,
                            labelSize: labelSize,
                            width: tileWidth,
                            height: tileHeight
                        ) { onPress(item) }
                    }
                }
            }
        }
        .frame(width: contentWidth, alignment: .leading)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                OverflowTile(
                    item: item,
                    layout: .list,
                    iconSize: iconSize,
                    labelSize: labelSize,
                    width: panelWidth,
                    height: listRowHeight
                ) { onPress(item) }
            }
        }
        .frame(width: panelWidth, alignment: .leading)
    }

    private var columnCount: Int {
        iconSize >= 32 ? Self.largeColumns : Self.columns
    }

    /// Small and Medium keep a four-column width. Large uses that same Medium
    /// width and fits three tiles into it. Hidden icons use the Medium width.
    private var contentWidth: CGFloat {
        let baseIcon: CGFloat
        if iconSize <= 0 || iconSize >= 32 {
            baseIcon = CGFloat(MenuBarTool.defaultIconSize)
        } else {
            baseIcon = iconSize
        }
        let baseTile = max(baseIcon + 24, 44)
        return CGFloat(Self.columns) * baseTile + CGFloat(Self.columns - 1) * Self.gutter
    }

    private var panelWidth: CGFloat {
        layout == .list ? max(contentWidth, 220) : contentWidth
    }

    private var tileWidth: CGFloat {
        let gaps = CGFloat(columnCount - 1) * Self.gutter
        return (contentWidth - gaps) / CGFloat(columnCount)
    }

    private var tileHeight: CGFloat {
        var height: CGFloat = 8
        if iconSize > 0 { height += iconSize }
        if labelSize > 0 { height += labelSize }
        if iconSize > 0 && labelSize > 0 { height += 3 }
        return max(height, 24)
    }

    private var listRowHeight: CGFloat {
        max(iconSize > 0 ? iconSize + 8 : 0, labelSize > 0 ? labelSize + 12 : 0, 28)
    }

    private var emptyHeight: CGFloat {
        layout == .list ? listRowHeight : tileHeight
    }

    private var rows: [[OverflowItem]] {
        stride(from: 0, to: items.count, by: columnCount).map { start in
            Array(items[start ..< min(start + columnCount, items.count)])
        }
    }
}

struct OverflowTile: View {
    let item: OverflowItem
    var layout: MenuBarStripLayout = .grid
    let iconSize: CGFloat
    let labelSize: CGFloat
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = HoverFlag()

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, layout == .list ? 6 : 2)
                .frame(width: width, height: height, alignment: layout == .list ? .leading : .center)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hover.on ? Color.primary.opacity(0.12) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(reduceMotion ? nil : Motion.hover, value: hover.on)
        .help(item.element == nil ? "\(item.label) — Allow Accessibility to use this icon" : item.tooltip)
        .accessibilityLabel(item.label)
    }

    private var caption: String {
        if let appName = item.appName, !appName.isEmpty { return appName }
        if let detail = item.detail, !detail.isEmpty { return detail }
        return "Hidden"
    }

    @ViewBuilder
    private var content: some View {
        if layout == .list {
            HStack(spacing: 8) {
                if iconSize > 0 {
                    OverflowItemIcon(item: item, iconSize: iconSize)
                }
                if labelSize > 0 {
                    Text(caption)
                        .font(.system(size: max(labelSize, 11), weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: iconSize > 0 && labelSize > 0 ? 3 : 0) {
                if iconSize > 0 {
                    OverflowItemIcon(item: item, iconSize: iconSize)
                }
                if labelSize > 0 {
                    Text(caption)
                        .font(.system(size: labelSize, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
            }
        }
    }
}

private struct OverflowItemIcon: View {
    let item: OverflowItem
    let iconSize: CGFloat

    var body: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
        } else if let glyph = item.appIcon {
            Image(nsImage: glyph)
                .resizable()
                .interpolation(.high)
                .frame(width: iconSize, height: iconSize)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: max(12, iconSize * 0.6), weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: iconSize, height: iconSize)
        }
    }
}
