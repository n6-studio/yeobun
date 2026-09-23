import AppKit
import SwiftUI

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case logoOnly
    case activeIcons
    case logoAndActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logoOnly: "Logo only"
        case .activeIcons: "Active icons"
        case .logoAndActive: "Logo and active icons"
        }
    }
}

enum MenuBarStats: String, CaseIterable, Identifiable {
    case off
    case cpu
    case battery
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .cpu: "CPU"
        case .battery: "Battery"
        case .network: "Network"
        }
    }

    /// Tiny caption drawn above the menu-bar value. `nil` when stats are off.
    var caption: String? {
        switch self {
        case .off: nil
        case .cpu, .battery, .network: title
        }
    }
}

/// Menu-bar template of the Yeobun Y Wrench mark, optionally followed by active-tool symbols.
///
/// A PDF representation stays sharp after display scale changes (unplugging a
/// monitor, moving the menu bar between 1x and 2x screens). Cached bitmaps do not.
enum MenuBarIcon {
    static let pointSize = NSSize(width: 18, height: 18)
    /// Two rows of tiny glyphs, filling a column then growing to the right.
    private static let gridCell: CGFloat = 8
    private static let gridGap: CGFloat = 2
    private static let logoToGridGap: CGFloat = 4

    static func makeImage(
        mode: MenuBarDisplay,
        tools: [ToolID],
        statsText: String? = nil,
        statsCaption: String? = nil
    ) -> NSImage {
        let stats = statsText.flatMap { $0.isEmpty ? nil : $0 }
        if stats == nil {
            switch mode {
            case .logoOnly:
                return makeLogoImage()
            case .activeIcons:
                return tools.isEmpty ? makeLogoImage() : makeCompositeImage(showLogo: false, tools: tools)
            case .logoAndActive:
                return tools.isEmpty ? makeLogoImage() : makeCompositeImage(showLogo: true, tools: tools)
            }
        }
        switch mode {
        case .logoOnly:
            return makeCompositeImage(showLogo: true, tools: [], statsText: stats, statsCaption: statsCaption)
        case .activeIcons:
            return tools.isEmpty
                ? makeCompositeImage(showLogo: true, tools: [], statsText: stats, statsCaption: statsCaption)
                : makeCompositeImage(showLogo: false, tools: tools, statsText: stats, statsCaption: statsCaption)
        case .logoAndActive:
            return tools.isEmpty
                ? makeCompositeImage(showLogo: true, tools: [], statsText: stats, statsCaption: statsCaption)
                : makeCompositeImage(showLogo: true, tools: tools, statsText: stats, statsCaption: statsCaption)
        }
    }

    static func statusItemLength(mode: MenuBarDisplay, tools: [ToolID], statsText: String? = nil) -> CGFloat {
        let stats = statsText.flatMap { $0.isEmpty ? nil : $0 }
        if stats == nil, mode == .logoOnly || tools.isEmpty {
            return NSStatusItem.squareLength
        }
        return NSStatusItem.variableLength
    }

    static func tooltip(tools: [ToolID], statsText: String? = nil, statsCaption: String? = nil) -> String {
        var parts = ["Yeobun"]
        if let statsText, !statsText.isEmpty {
            if let statsCaption, !statsCaption.isEmpty {
                parts.append("\(statsCaption) \(statsText)")
            } else {
                parts.append(statsText)
            }
        }
        if !tools.isEmpty {
            parts.append(tools.map(\.title).joined(separator: ", "))
        }
        return parts.joined(separator: " — ")
    }

    private static func makeLogoImage() -> NSImage {
        let image = NSImage(data: pdfData()) ?? rasterFallback()
        image.size = pointSize
        image.isTemplate = true
        image.cacheMode = .never
        image.accessibilityDescription = "Yeobun"
        return image
    }

    private static func gridSize(toolCount: Int) -> NSSize {
        let columns = (toolCount + 1) / 2
        let width = CGFloat(columns) * gridCell + CGFloat(max(0, columns - 1)) * gridGap
        return NSSize(width: width, height: pointSize.height)
    }

    private static let statsValueFontSize: CGFloat = 10
    private static let statsCaptionFontSize: CGFloat = 7
    private static let logoToStatsGap: CGFloat = 4

    private static func statsValueAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: statsValueFontSize, weight: .medium),
            .foregroundColor: NSColor.black
        ]
    }

    private static func statsCaptionAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: statsCaptionFontSize, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
    }

    private static func statsSize(value: String, caption: String?) -> NSSize {
        let valueWidth = (value as NSString).size(withAttributes: statsValueAttributes()).width
        let captionWidth = caption.map { ($0 as NSString).size(withAttributes: statsCaptionAttributes()).width } ?? 0
        return NSSize(width: ceil(max(valueWidth, captionWidth)) + 1, height: pointSize.height)
    }

    private static func makeCompositeImage(
        showLogo: Bool,
        tools: [ToolID],
        statsText: String? = nil,
        statsCaption: String? = nil
    ) -> NSImage {
        let grid = tools.isEmpty ? NSSize.zero : gridSize(toolCount: tools.count)
        let stats = statsText.map { statsSize(value: $0, caption: statsCaption) } ?? .zero
        var width: CGFloat = 0
        if showLogo { width += pointSize.width }
        if !tools.isEmpty {
            if width > 0 { width += logoToGridGap }
            width += grid.width
        }
        if stats.width > 0 {
            if width > 0 { width += logoToStatsGap }
            width += stats.width
        }
        if width == 0 { width = pointSize.width }
        let size = NSSize(width: width, height: pointSize.height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setShouldAntialias(true)
            ctx.interpolationQuality = .high
            var originX: CGFloat = 0
            if showLogo {
                drawMark(ctx, in: pointSize)
                originX = pointSize.width
            }
            if !tools.isEmpty {
                if showLogo { originX += logoToGridGap }
                for (index, tool) in tools.enumerated() {
                    let col = index / 2
                    let isTop = index % 2 == 0
                    let frame = CGRect(
                        x: originX + CGFloat(col) * (gridCell + gridGap),
                        y: isTop ? gridCell + gridGap : 0,
                        width: gridCell,
                        height: gridCell
                    )
                    drawSymbol(tool, in: frame)
                }
                originX += grid.width
            }
            if let statsText {
                if originX > 0 { originX += logoToStatsGap }
                drawStats(value: statsText, caption: statsCaption, at: originX)
            }
            return true
        }
        image.isTemplate = true
        image.cacheMode = .never
        image.accessibilityDescription = tooltip(
            tools: tools,
            statsText: statsText,
            statsCaption: statsCaption
        )
        return image
    }

    private static func drawStats(value: String, caption: String?, at originX: CGFloat) {
        let valueText = value as NSString
        if let caption, !caption.isEmpty {
            (caption as NSString).draw(
                at: NSPoint(x: originX, y: 9),
                withAttributes: statsCaptionAttributes()
            )
            valueText.draw(
                at: NSPoint(x: originX, y: -0.5),
                withAttributes: statsValueAttributes()
            )
            return
        }
        valueText.draw(
            at: NSPoint(x: originX, y: (pointSize.height - statsValueFontSize) / 2 - 1),
            withAttributes: statsValueAttributes()
        )
    }

    private static func drawSymbol(_ tool: ToolID, in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(GlyphLibrary.art(tool.glyph, filled: true).cgPath(in: rect, yDown: false))
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fillPath(using: .winding)
    }

    private static func pdfData() -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pointSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }
        ctx.beginPDFPage(nil)
        drawMark(ctx, in: pointSize)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func rasterFallback() -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawMark(ctx, in: rect.size)
            return true
        }
        image.isTemplate = true
        image.cacheMode = .never
        image.accessibilityDescription = "Yeobun"
        return image
    }

    static func drawMark(_ ctx: CGContext, in size: CGSize) {
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        let padding = size.width * 0.06
        let drawable = size.width - padding * 2
        ctx.saveGState()
        ctx.translateBy(x: padding, y: size.height - padding)
        ctx.scaleBy(x: drawable / YeobunMark.canvas, y: -drawable / YeobunMark.canvas)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))

        ctx.addPath(YeobunMark.cgPath())
        ctx.clip()

        let relievedFill = CGMutablePath()
        relievedFill.addRect(CGRect(x: 0, y: 0, width: YeobunMark.canvas, height: YeobunMark.canvas))
        relievedFill.addPath(YeobunMark.reliefPath())
        ctx.addPath(relievedFill)
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
    }
}

enum YeobunMark {
    static let canvas: CGFloat = 24

    static func cgPath() -> CGPath {
        let silhouette = CGMutablePath()
        silhouette.move(to: CGPoint(x: 3, y: 2.75))
        silhouette.addLine(to: CGPoint(x: 7, y: 2.75))
        silhouette.addLine(to: CGPoint(x: 9.85, y: 7.9))
        silhouette.addLine(to: CGPoint(x: 14.15, y: 7.9))
        silhouette.addLine(to: CGPoint(x: 17, y: 2.75))
        silhouette.addLine(to: CGPoint(x: 21, y: 2.75))
        silhouette.addLine(to: CGPoint(x: 19.25, y: 8.85))
        silhouette.addLine(to: CGPoint(x: 15, y: 11.7))
        silhouette.addLine(to: CGPoint(x: 15, y: 18.75))
        silhouette.addCurve(
            to: CGPoint(x: 12, y: 22),
            control1: CGPoint(x: 15, y: 20.68),
            control2: CGPoint(x: 13.66, y: 22)
        )
        silhouette.addCurve(
            to: CGPoint(x: 9, y: 18.75),
            control1: CGPoint(x: 10.34, y: 22),
            control2: CGPoint(x: 9, y: 20.68)
        )
        silhouette.addLine(to: CGPoint(x: 9, y: 11.7))
        silhouette.addLine(to: CGPoint(x: 4.75, y: 8.85))
        silhouette.closeSubpath()

        let result = CGMutablePath()
        result.addPath(silhouette)
        result.addPath(silhouette.copy(
            strokingWithWidth: 0.65,
            lineCap: .butt,
            lineJoin: .round,
            miterLimit: 10
        ))
        return result
    }

    static func reliefPath() -> CGPath {
        let result = CGMutablePath()
        result.addEllipse(in: CGRect(x: 10.85, y: 17.6, width: 2.3, height: 2.3))
        return result
    }
}

struct YeobunN: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / YeobunMark.canvas
        let sy = rect.height / YeobunMark.canvas
        var transform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rect.minX, ty: rect.minY)
        return Path(YeobunMark.cgPath().copy(using: &transform) ?? YeobunMark.cgPath())
    }
}
