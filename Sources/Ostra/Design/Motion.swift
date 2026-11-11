import SwiftUI

/// Animation curves and timings.
///
/// The rules behind them:
/// - Keyboard-driven actions that repeat all day (cycling agents, opening a
///   menu with a key) don't animate. Use `Motion.instantly`.
/// - Things that enter or exit ease out, and exits run faster than entrances.
/// - Things that move on screen or follow a gesture use springs, because
///   springs keep their velocity when interrupted.
/// - Nothing scales in from zero. Entrances start near full size.
enum Motion {
    /// A strong ease-out for entrances and exits.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }

    /// A strong ease-in-out for elements that travel across the screen.
    static func easeInOut(_ duration: Double) -> Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: duration)
    }

    /// Press feedback on buttons and cards.
    static let press = easeOut(0.13)
    /// Hover and color changes.
    static let hover = Animation.easeOut(duration: 0.16)
    /// Popovers and menus opened with the pointer.
    static let popIn = easeOut(0.19)
    static let popOut = easeOut(0.12)
    /// Large glass panels: the chat pane and the left panel.
    static let panel = Animation.spring(duration: 0.36, bounce: 0.14)
    static let panelOut = easeOut(0.2)
    /// The camera gliding to an agent.
    static let camera = Animation.spring(duration: 0.55, bounce: 0.0)
    /// Small state changes inside a view.
    static let snappy = Animation.spring(duration: 0.26, bounce: 0.12)
    /// Group outlines settling after a card moves.
    static let settle = Animation.spring(duration: 0.4, bounce: 0.18)

    /// Runs a state change without animation.
    static func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// Runs a state change, animated unless the user asked for reduced motion
    /// or the change came from the keyboard.
    static func perform(_ animation: Animation, animated: Bool, _ change: () -> Void) {
        if animated {
            withAnimation(animation, change)
        } else {
            instantly(change)
        }
    }
}

extension AnyTransition {
    /// A popover that grows out of its trigger. Entrances start at 96% size, never from zero.
    static func pop(from anchor: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.96, anchor: anchor).combined(with: .opacity).animation(Motion.popIn),
            removal: .scale(scale: 0.98, anchor: anchor).combined(with: .opacity).animation(Motion.popOut)
        )
    }

    /// A panel that rises from the bottom edge of the screen.
    static var rise: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.97, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 14)),
            removal: .scale(scale: 0.985, anchor: .bottom).combined(with: .opacity)
        )
    }

    /// A panel that slides in from the leading edge.
    static var slideLeading: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
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
