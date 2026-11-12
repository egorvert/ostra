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

/// The side of the window the code panel opens on. The menu and the status
/// pane take the other side.
enum PanelSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        }
    }

    /// The edge the code panel sits against.
    var edge: HorizontalEdge { self == .left ? .leading : .trailing }
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
    /// True when agents and projects pick dark or light ink from the canvas behind them.
    var adaptiveInk: Bool = true
    var codePanelSide: PanelSide = .left
    /// Shortcuts the user changed: chords as text, by command.
    var keyBindings: [String: [String]] = [:]

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
        adaptiveInk = try container.decodeIfPresent(Bool.self, forKey: .adaptiveInk) ?? defaults.adaptiveInk
        codePanelSide = try container.decodeIfPresent(PanelSide.self, forKey: .codePanelSide) ?? defaults.codePanelSide
        keyBindings = try container.decodeIfPresent([String: [String]].self, forKey: .keyBindings) ?? [:]
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
    /// False for scripted development runs, which must not change real preferences.
    @ObservationIgnored private let persists: Bool

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        if persists, let stored = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(SettingsData.self, from: stored) {
            data = decoded
        } else {
            data = SettingsData()
        }
    }

    private func save() {
        guard persists, let encoded = try? JSONEncoder().encode(data) else { return }
        defaults.set(encoded, forKey: key)
    }

    /// Restores every preference but the shortcuts, which the shortcuts sheet resets.
    func reset() {
        var fresh = SettingsData()
        fresh.keyBindings = data.keyBindings
        data = fresh
    }

    /// The shortcuts, with the user's changes.
    var keymap: Keymap {
        get { Keymap(overrides: data.keyBindings) }
        set { data.keyBindings = newValue.overrides }
    }
}
