import AppKit
import SwiftUI

/// Reports how bright the canvas is behind any part of the window.
///
/// Glass nodes use it to pick dark or light ink, so a card reads as well over
/// a night sky as over snow. The canvas color answers for plain backgrounds.
/// For an image, the backdrop keeps a small grid of brightness values and
/// averages the cells under the rectangle.
final class CanvasBackdrop {
    static let shared = CanvasBackdrop()

    private var path: String?
    private var grid: [Float] = []
    private var columns = 0
    private var rows = 0
    private var imageSize: CGSize = .zero

    /// The brightness behind `rect`, from 0 (black) to 1 (white).
    ///
    /// - Parameters:
    ///   - rect: A rectangle in window points, with the origin at the top left.
    ///   - viewSize: The size of the canvas.
    func luminance(in rect: CGRect, viewSize: CGSize, settings: SettingsData, scheme: ColorScheme) -> Double {
        let base = Self.luminance(of: settings.canvasColor.flatMap(Color.init(hex:)) ?? Theme.canvasBase(scheme))
        guard settings.canvasStyle == .image, viewSize.width > 0, viewSize.height > 0,
              load(settings.backgroundImagePath), columns > 0 else {
            return base
        }

        // The image fills the window and keeps its aspect ratio, so it
        // overflows on one axis. Map the rectangle into image space.
        let fill = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let shown = CGSize(width: imageSize.width * fill, height: imageSize.height * fill)
        let origin = CGPoint(x: (viewSize.width - shown.width) / 2, y: (viewSize.height - shown.height) / 2)
        let visible = rect.intersection(CGRect(origin: .zero, size: viewSize))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return base }

        func cell(_ value: CGFloat, _ start: CGFloat, _ length: CGFloat, _ count: Int) -> Int {
            min(max(Int((value - start) / length * CGFloat(count)), 0), count - 1)
        }
        let firstColumn = cell(visible.minX, origin.x, shown.width, columns)
        let lastColumn = cell(visible.maxX, origin.x, shown.width, columns)
        let firstRow = cell(visible.minY, origin.y, shown.height, rows)
        let lastRow = cell(visible.maxY, origin.y, shown.height, rows)

        var total: Float = 0
        var count: Float = 0
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                total += grid[row * columns + column]
                count += 1
            }
        }
        let image = Double(total / max(count, 1))
        // The canvas color sits over the image at the dim setting's opacity.
        return image * (1 - settings.imageDim) + base * settings.imageDim
    }

    /// Reads the image into a brightness grid. Returns false when there's no image.
    private func load(_ newPath: String?) -> Bool {
        guard let newPath, !newPath.isEmpty else { return false }
        if newPath == path { return !grid.isEmpty }
        path = newPath
        grid = []
        columns = 0
        rows = 0

        guard let image = BackgroundImageCache.shared.image(at: newPath),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return false }
        imageSize = CGSize(width: source.width, height: source.height)

        let width = 64
        let height = max(1, Int((Double(width) * Double(source.height) / Double(source.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }

        // The buffer's first row is the top of the image.
        grid = (0..<(width * height)).map { index in
            let red = Float(pixels[index * 4]) / 255
            let green = Float(pixels[index * 4 + 1]) / 255
            let blue = Float(pixels[index * 4 + 2]) / 255
            return 0.299 * red + 0.587 * green + 0.114 * blue
        }
        columns = width
        rows = height
        return true
    }

    /// The perceived brightness of a color, from 0 to 1.
    static func luminance(of color: Color) -> Double {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
    }
}

/// Picks the color scheme for a glass node from the brightness behind it.
///
/// A dark backdrop gets dark glass with light ink, and a bright one gets light
/// glass with dark ink. The choice has a dead band in the middle, so a node
/// that drifts across an edge between light and dark doesn't flicker.
struct AdaptiveTone: ViewModifier {
    /// The node's frame in window points, or nil to follow the app's appearance.
    var frame: CGRect?

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var tone: ColorScheme?

    func body(content: Content) -> some View {
        let luminance = frame.map {
            CanvasBackdrop.shared.luminance(in: $0, viewSize: app.viewSize, settings: app.settings.data, scheme: scheme)
        }
        // -1 is clearly dark, 1 is clearly bright, and 0 keeps the last choice.
        let zone = luminance.map { $0 < 0.44 ? -1 : ($0 > 0.56 ? 1 : 0) }
        let fallback: ColorScheme? = luminance.map { $0 < 0.5 ? .dark : .light }
        let resolved: ColorScheme? = zone == nil ? nil : (zone == -1 ? .dark : (zone == 1 ? .light : (tone ?? fallback)))

        content
            .environment(\.colorScheme, resolved ?? scheme)
            .onChange(of: resolved, initial: true) { _, value in tone = value }
    }
}

extension View {
    /// Matches the view's glass and ink to the canvas behind `frame`.
    func adaptiveTone(over frame: CGRect?) -> some View {
        modifier(AdaptiveTone(frame: frame))
    }
}
