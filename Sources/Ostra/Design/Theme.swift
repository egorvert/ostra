import AppKit
import OstraCore
import SwiftUI

/// Colors, type, and metrics shared by every view.
///
/// The palette is monochrome on purpose. Color carries meaning in two places
/// only: the status dot on an agent, and the one primary action in view.
enum Theme {
    // MARK: Colors

    /// The single accent: selection and the primary action.
    static let accent = Color(red: 0.04, green: 0.44, blue: 1.0)
    static let amber = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let green = Color(red: 0.19, green: 0.72, blue: 0.40)
    static let red = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let neutral = Color(white: 0.62)

    static func canvasBase(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.078, blue: 0.086) : Color(red: 0.965, green: 0.960, blue: 0.948)
    }

    static func canvasPattern(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color(red: 0.22, green: 0.20, blue: 0.16)
    }

    /// The fill that frosts a glass panel so text stays readable over any canvas.
    static func frostFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.105, green: 0.108, blue: 0.118) : Color(red: 0.992, green: 0.990, blue: 0.985)
    }

    /// The surface of an agent card. Cards are content, so they don't use glass.
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.07) : Color(white: 1, opacity: 0.78)
    }

    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 1, opacity: 0.10) : Color(white: 0, opacity: 0.07)
    }

    static func addition(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.36, green: 0.80, blue: 0.52) : Color(red: 0.10, green: 0.54, blue: 0.28)
    }

    static func deletion(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.97, green: 0.48, blue: 0.48) : Color(red: 0.78, green: 0.20, blue: 0.20)
    }

    // MARK: Type

    /// Interface text, in Geist.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.sans(size, weight)
    }

    /// Reading text, in Geist.
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.sans(size, weight)
    }

    /// Code, in Geist Mono.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.mono(size, weight)
    }

    // MARK: Metrics

    static let hudMargin: CGFloat = 18
    static let panelRadius: CGFloat = 24
    static let inputRadius: CGFloat = 23
    static let cardRadius: CGFloat = 18
    static let chatWidth: CGFloat = 600
    static let chatMinWidth: CGFloat = 400
    static let cornerButton: CGFloat = 44
}

extension AgentPhase {
    /// The color of the status dot.
    var tint: Color {
        switch self {
        case .idle, .interrupted, .starting, .working: Theme.neutral
        case .awaitingApproval, .awaitingInput: Theme.amber
        case .done: Theme.green
        case .failed: Theme.red
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .starting: "Starting"
        case .working: "Working"
        case .awaitingApproval: "Needs approval"
        case .awaitingInput: "Has a question"
        case .done: "Done"
        case .failed: "Failed"
        case .interrupted: "Stopped"
        }
    }
}

extension Color {
    /// Creates a color from `#RRGGBB`.
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    /// The color as `#RRGGBB`, in sRGB.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
