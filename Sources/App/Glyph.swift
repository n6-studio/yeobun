import CoreGraphics
import SwiftUI

/// Square slot sizes for Phosphor glyphs. The artwork already includes its own
/// padding inside the 256×256 canvas, so the frame is the whole icon.
enum GlyphSlot {
    static let row: CGFloat = 16
    static let pin: CGFloat = 10
    static let detail: CGFloat = 20
}

extension GlyphID {
    init(remoteSymbol raw: String) {
        self = GlyphID(rawValue: RemoteSymbol.resolve(raw)) ?? .hardDrives
    }
}

struct GlyphArt {
    enum Op {
        case move(CGFloat, CGFloat)
        case line(CGFloat, CGFloat)
        case cubic(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case close
    }

    var ops: [Op]

    init(_ ops: [Op]) {
        self.ops = ops
    }

    /// `yDown` matches SwiftUI. Menu-bar images are drawn in a y-up context.
    func cgPath(in rect: CGRect, yDown: Bool) -> CGPath {
        let scale = min(rect.width, rect.height) / 256
        let span = 256 * scale
        let insetX = (rect.width - span) / 2
        let insetY = (rect.height - span) / 2
        let path = CGMutablePath()

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let px = rect.minX + insetX + x * scale
            let py = yDown
                ? rect.minY + insetY + y * scale
                : rect.maxY - insetY - y * scale
            return CGPoint(x: px, y: py)
        }

        for op in ops {
            switch op {
            case .move(let x, let y):
                path.move(to: point(x, y))
            case .line(let x, let y):
                path.addLine(to: point(x, y))
            case .cubic(let x1, let y1, let x2, let y2, let x, let y):
                path.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
            case .close:
                path.closeSubpath()
            }
        }
        return path
    }
}

struct GlyphShape: Shape {
    var art: GlyphArt

    func path(in rect: CGRect) -> Path {
        Path(art.cgPath(in: rect, yDown: true))
    }
}

struct GlyphIcon: View {
    var id: GlyphID
    var filled = false

    var body: some View {
        GlyphShape(art: GlyphLibrary.art(id, filled: filled))
            .fill(style: FillStyle(eoFill: false))
            .accessibilityHidden(true)
    }
}

/// Template images for AppKit menus. A SwiftUI `Menu` drops custom shapes, so the
/// remote icon picker has to hand it an `NSImage`. Representations are stored at
/// 2x and 3x so the menu does not scale up a 1x bitmap.
enum GlyphIconImage {
    private static var cache: [GlyphID: NSImage] = [:]

    static func template(_ id: GlyphID, side: CGFloat = GlyphSlot.row) -> NSImage {
        if let cached = cache[id] { return cached }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.isTemplate = true
        for scale in [2, 3] as [CGFloat] {
            let pixels = Int((side * scale).rounded())
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = NSSize(width: side, height: side)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            if let ctx = NSGraphicsContext.current?.cgContext {
                // This context is in points (the rep's size). The pixel buffer is
                // already scaled, so the path has to use `side`, not the pixel count.
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                ctx.clear(rect)
                ctx.setShouldAntialias(true)
                ctx.addPath(GlyphLibrary.art(id, filled: false).cgPath(in: rect, yDown: false))
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillPath(using: .winding)
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        cache[id] = image
        return image
    }
}
