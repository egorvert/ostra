import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "Match system"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

enum CanvasStyle: String, Codable, CaseIterable, Identifiable {
    case dots
    case grid
    case plain
    case image

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dots: "Dots"
        case .grid: "Grid"
        case .plain: "Plain"
        case .image: "Image"
        }
    }
}

/// The user's preferences. Every field has a default, so old files keep loading.
struct SettingsData: Codable, Equatable {
    var appearance: AppearanceMode = .light
    var canvasStyle: CanvasStyle = .dots
    /// The canvas color as `#RRGGBB`, or nil for the default of the color scheme.
    var canvasColor: String?
    /// How strong the dots or grid lines are, from 0 to 1.
    var patternStrength: Double = 0.5
    var backgroundImagePath: String?
    /// How much the canvas color covers the image, from 0 to 0.9.
    var imageDim: Double = 0.15
    /// The blur radius for the image, in points.
    var imageBlur: Double = 0
    /// The chat pane's frost, from 0 (pure glass) to 1 (opaque).
    var chatFrost: Double = 0.5
    /// The frost for menus and smaller panels.
    var panelFrost: Double = 0.3
    /// True when agent cards use glass. Cards are content, so the default is a plain card.
    var glassCards: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SettingsData()
        appearance = try container.decodeIfPresent(AppearanceMode.self, forKey: .appearance) ?? defaults.appearance
        canvasStyle = try container.decodeIfPresent(CanvasStyle.self, forKey: .canvasStyle) ?? defaults.canvasStyle
        canvasColor = try container.decodeIfPresent(String.self, forKey: .canvasColor)
        patternStrength = try container.decodeIfPresent(Double.self, forKey: .patternStrength) ?? defaults.patternStrength
        backgroundImagePath = try container.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        imageDim = try container.decodeIfPresent(Double.self, forKey: .imageDim) ?? defaults.imageDim
        imageBlur = try container.decodeIfPresent(Double.self, forKey: .imageBlur) ?? defaults.imageBlur
        chatFrost = try container.decodeIfPresent(Double.self, forKey: .chatFrost) ?? defaults.chatFrost
        panelFrost = try container.decodeIfPresent(Double.self, forKey: .panelFrost) ?? defaults.panelFrost
        glassCards = try container.decodeIfPresent(Bool.self, forKey: .glassCards) ?? defaults.glassCards
    }
}

/// Loads, publishes, and saves the user's preferences.
@Observable
final class AppSettings {
    var data: SettingsData {
        didSet {
            guard data != oldValue else { return }
            save()
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "ostra.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: stored) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    private func save() {
        guard let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)
    }

    func reset() {
        data = SettingsData()
    }
}
