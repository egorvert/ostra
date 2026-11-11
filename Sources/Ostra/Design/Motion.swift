import SwiftUI

/// Animation curves, timings, and transitions.
///
/// The rules behind them:
/// - Actions that repeat all day don't animate: cycling agents, moving a
///   selection, and menus opened with a key. Use `Motion.instantly`.
/// - Panels animate however they open, because a surface that covers part of
///   the canvas has to show where it came from. They use springs without
///   bounce, so a panel that closes mid-way reverses from where it is.
/// - Entrances ease out and start near full size. Exits are faster and leave
///   the way they came.
/// - Bounce belongs to things the pointer threw: a dropped card, a flicked canvas.
/// - With Reduce Motion on, movement goes and fades stay.
enum Motion {
    /// Stretches every duration. Set `OSTRA_MOTION_SCALE=5` to study a
    /// transition in slow motion.
    static let scale: Double = {
        let value = ProcessInfo.processInfo.environment["OSTRA_MOTION_SCALE"].flatMap(Double.init) ?? 1
        return min(max(value, 0.1), 20)
    }()

    /// True while the system asks for reduced motion. `RootView` keeps it current.
    nonisolated(unsafe) static var reduced = false

    /// A strong ease-out for entrances and exits.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration * scale)
    }

    /// A strong ease-in-out for elements that travel across the screen.
    static func easeInOut(_ duration: Double) -> Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: duration * scale)
    }

    /// A spring. `bounce` stays at zero unless the pointer supplied momentum.
    static func spring(_ duration: Double, bounce: Double = 0) -> Animation {
        .spring(duration: duration * scale, bounce: bounce)
    }

    /// Press feedback on buttons and cards.
    static let press = easeOut(0.14)
    /// Hover and color changes.
    static let hover = Animation.easeOut(duration: 0.15 * scale)
    /// Popovers and menus opened with the pointer.
    static let popIn = easeOut(0.18)
    static let popOut = easeOut(0.12)
    /// Large glass panels: the chat pane, the left panel, and the status pane.
    static let panel = spring(0.36)
    static let panelOut = spring(0.26)
    /// Sheets that cover the window: settings and shortcuts.
    static let sheet = easeOut(0.26)
    static let sheetOut = easeOut(0.16)
    /// The indicator that slides between tabs.
    static let tab = spring(0.3)
    /// The content that changes under the tabs.
    static let tabContent = easeOut(0.2)
    /// The camera gliding to an agent or a new zoom level.
    static let camera = spring(0.5)
    /// Small state changes inside a view.
    static let snappy = spring(0.26)
    /// Things that settle after the pointer lets go.
    static let settle = spring(0.42, bounce: 0.16)
    /// The canvas coasting after a flick.
    static let coast = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7 * scale)

    /// Runs a state change without animation.
    static func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// Runs a state change with `animation`, or at once when `animated` is false.
    static func perform(_ animation: Animation, animated: Bool = true, _ change: () -> Void) {
        if animated {
            withAnimation(reduced ? .easeOut(duration: 0.15) : animation, change)
        } else {
            instantly(change)
        }
    }
}

/// A transition that scales, shifts, softens, and fades a view.
///
/// Every entrance in the app is one of these with different numbers, so the
/// motion reads as one system. With Reduce Motion on, only the fade remains.
struct Materialize: Transition {
    var scale: CGFloat = 1
    var anchor: UnitPoint = .center
    var offset: CGSize = .zero
    /// A blur that bridges two pieces of content while they cross-fade. Leave
    /// it at zero on glass, which the system materializes itself.
    var blur: CGFloat = 0

    func body(content: Content, phase: TransitionPhase) -> some View {
        let resting = phase.isIdentity
        let moves = !Motion.reduced
        content
            .scaleEffect(resting || !moves ? 1 : scale, anchor: anchor)
            .offset(resting || !moves ? .zero : offset)
            .blur(radius: resting ? 0 : blur)
            .opacity(resting ? 1 : 0)
    }
}

extension AnyTransition {
    /// A popover that grows out of its trigger. It starts at 96% size, never from zero.
    static func pop(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(Materialize(scale: 0.96, anchor: anchor)).animation(Motion.popIn),
            removal: AnyTransition(Materialize(scale: 0.98, anchor: anchor)).animation(Motion.popOut)
        )
    }

    /// The chat pane: it rises out of the chat box and sinks back into it.
    static var rise: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(Materialize(scale: 0.965, anchor: .bottom, offset: CGSize(width: 0, height: 18))),
            removal: AnyTransition(Materialize(scale: 0.98, anchor: .bottom, offset: CGSize(width: 0, height: 10)))
        )
    }

    /// A panel that slides in from the leading edge and leaves the same way.
    static func slide(from edge: HorizontalEdge, distance: CGFloat = 36) -> AnyTransition {
        let shift = CGSize(width: edge == .leading ? -distance : distance, height: 0)
        return AnyTransition(Materialize(scale: 0.985, anchor: edge == .leading ? .leading : .trailing, offset: shift))
    }

    /// A sheet in the middle of the window. Sheets have no trigger to grow
    /// from, so they scale from the center.
    static var sheet: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(Materialize(scale: 0.97, offset: CGSize(width: 0, height: 8))),
            removal: AnyTransition(Materialize(scale: 0.985))
        )
    }

    /// Content that replaces other content in the same place. It arrives from
    /// the side it lives on, and a short blur hides the overlap.
    static func swap(forward: Bool) -> AnyTransition {
        let travel: CGFloat = forward ? 14 : -14
        return .asymmetric(
            insertion: AnyTransition(Materialize(offset: CGSize(width: travel, height: 0), blur: 3)),
            removal: AnyTransition(Materialize(offset: CGSize(width: -travel, height: 0), blur: 3))
        )
    }

    /// A small item that joins a row, such as an attachment.
    static var chip: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(Materialize(scale: 0.9)).animation(Motion.snappy),
            removal: AnyTransition(Materialize(scale: 0.94)).animation(Motion.popOut)
        )
    }
}

/// A button style that scales down on press, so the interface feels like it hears the click.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
