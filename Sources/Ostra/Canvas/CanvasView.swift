import AppKit
import OstraCore
import SwiftUI

/// The infinite canvas: a background, project groups, and agent cards under one camera.
struct CanvasView: View {
    @Environment(AppModel.self) private var app
    @State private var panStart: CameraState?

    var body: some View {
        GeometryReader { geometry in
            let camera = app.store.camera
            ZStack {
                CanvasBackground(camera: camera)
                    .contentShape(Rectangle())
                    .gesture(panGesture)
                    .onTapGesture { app.canvasTapped() }

                WorldLayer()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scaleEffect(camera.zoom)
                    .offset(x: -camera.x * camera.zoom, y: -camera.y * camera.zoom)
            }
            .onChange(of: geometry.size, initial: true) { _, size in
                app.viewSize = size
            }
        }
    }

    /// Dragging the background pans the canvas.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                let start = panStart ?? app.store.camera
                panStart = start
                var camera = start
                camera.x -= value.translation.width / start.zoom
                camera.y -= value.translation.height / start.zoom
                Motion.instantly { app.store.camera = camera }
            }
            .onEnded { _ in panStart = nil }
    }
}

/// Everything that lives in world coordinates. The world's origin sits at the layer's center.
private struct WorldLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geometry in
            let origin = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack {
                ForEach(app.store.projects) { project in
                    ProjectGroupView(project: project, origin: origin)
                }
                ForEach(app.store.agents) { agent in
                    AgentCardView(agent: agent, origin: origin)
                }
            }
        }
    }
}

/// The canvas background: a color, an optional image, and an optional pattern.
struct CanvasBackground: View {
    var camera: CameraState
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let data = app.settings.data
        let base = data.canvasColor.flatMap(Color.init(hex:)) ?? Theme.canvasBase(scheme)
        ZStack {
            base
            if data.canvasStyle == .image, let image = BackgroundImageCache.shared.image(at: data.backgroundImagePath) {
                GeometryReader { geometry in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: data.imageBlur, opaque: true)
                        .clipped()
                }
                base.opacity(data.imageDim)
            }
            if data.canvasStyle == .dots || data.canvasStyle == .grid {
                PatternLayer(
                    x: camera.x,
                    y: camera.y,
                    zoom: camera.zoom,
                    lines: data.canvasStyle == .grid,
                    color: Theme.canvasPattern(scheme),
                    strength: data.patternStrength
                )
            }
        }
        .ignoresSafeArea()
    }
}

/// Loads the background image once per path.
final class BackgroundImageCache {
    static let shared = BackgroundImageCache()
    private var path: String?
    private var cached: NSImage?

    func image(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if path == self.path { return cached }
        self.path = path
        cached = NSImage(contentsOfFile: path)
        return cached
    }
}

/// Dots or grid lines that move with the camera.
///
/// The pattern keeps a steady density on screen: as the camera zooms out,
/// every other dot fades away before the spacing doubles, so nothing pops.
struct PatternLayer: View, Animatable {
    var x: Double
    var y: Double
    var zoom: Double
    var lines: Bool
    var color: Color
    var strength: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(x, y), zoom) }
        set {
            x = newValue.first.first
            y = newValue.first.second
            zoom = newValue.second
        }
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            let base: CGFloat = 24
            let half = base / 2
            // Pick the power-of-two spacing that lands the step in (12, 24].
            // At zoom 1 every dot shows at full strength, 24 points apart.
            var step = base * zoom
            while step <= half { step *= 2 }
            while step > base { step /= 2 }
            // Marks on odd rows and columns fade out as the step shrinks, so
            // the spacing can double without anything popping.
            let minorAlpha = Double((step - half) / half)

            let originX = size.width / 2 - x * zoom
            let originY = size.height / 2 - y * zoom
            let firstColumn = Int((-originX / step).rounded(.down)) - 1
            let firstRow = Int((-originY / step).rounded(.down)) - 1
            let columns = Int(size.width / step) + 3
            let rows = Int(size.height / step) + 3

            let alpha = 0.06 + strength * 0.26
            if lines {
                var major = Path()
                var minor = Path()
                for column in firstColumn..<(firstColumn + columns) {
                    let px = (originX + CGFloat(column) * step).rounded() + 0.5
                    if column % 2 == 0 {
                        major.move(to: CGPoint(x: px, y: 0))
                        major.addLine(to: CGPoint(x: px, y: size.height))
                    } else {
                        minor.move(to: CGPoint(x: px, y: 0))
                        minor.addLine(to: CGPoint(x: px, y: size.height))
                    }
                }
                for row in firstRow..<(firstRow + rows) {
                    let py = (originY + CGFloat(row) * step).rounded() + 0.5
                    if row % 2 == 0 {
                        major.move(to: CGPoint(x: 0, y: py))
                        major.addLine(to: CGPoint(x: size.width, y: py))
                    } else {
                        minor.move(to: CGPoint(x: 0, y: py))
                        minor.addLine(to: CGPoint(x: size.width, y: py))
                    }
                }
                context.stroke(major, with: .color(color.opacity(alpha * 0.55)), lineWidth: 1)
                context.stroke(minor, with: .color(color.opacity(alpha * 0.55 * minorAlpha)), lineWidth: 1)
            } else {
                let radius: CGFloat = 1.15
                var major = Path()
                var minor = Path()
                for column in firstColumn..<(firstColumn + columns) {
                    let px = originX + CGFloat(column) * step
                    for row in firstRow..<(firstRow + rows) {
                        let py = originY + CGFloat(row) * step
                        let dot = CGRect(x: px - radius, y: py - radius, width: radius * 2, height: radius * 2)
                        if column % 2 == 0, row % 2 == 0 {
                            major.addEllipse(in: dot)
                        } else {
                            minor.addEllipse(in: dot)
                        }
                    }
                }
                context.fill(major, with: .color(color.opacity(alpha)))
                if minorAlpha > 0.01 {
                    context.fill(minor, with: .color(color.opacity(alpha * minorAlpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
