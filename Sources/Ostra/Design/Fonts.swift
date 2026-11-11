import AppKit
import CoreText
import SwiftUI

/// Loads Geist and Geist Mono from the app's resources and hands out fonts.
///
/// The fonts ship inside the app, so nothing needs installing. If a file is
/// missing, every lookup falls back to the system font.
enum Fonts {
    enum Family {
        case sans
        case mono
    }

    /// PostScript names by family and weight, read from the font files.
    private static let names: [Family: [Font.Weight: String]] = register()

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(.sans, size, weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        font(.mono, size, weight)
    }

    static func nsSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        guard let name = resolve(.sans, weight), let font = NSFont(name: name, size: size) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    static func nsMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        guard let name = resolve(.mono, weight), let font = NSFont(name: name, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return font
    }

    private static func font(_ family: Family, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        guard let name = resolve(family, weight) else {
            return .system(size: size, weight: weight, design: family == .mono ? .monospaced : .default)
        }
        return .custom(name, fixedSize: size)
    }

    /// The bundled face nearest to the requested weight.
    private static func resolve(_ family: Family, _ weight: Font.Weight) -> String? {
        guard let faces = names[family], !faces.isEmpty else { return nil }
        let order: [Font.Weight]
        switch weight {
        case .ultraLight, .thin, .light, .regular: order = [.regular, .medium, .semibold, .bold]
        case .medium: order = [.medium, .regular, .semibold, .bold]
        case .semibold: order = [.semibold, .medium, .bold, .regular]
        default: order = [.bold, .semibold, .medium, .regular]
        }
        return order.lazy.compactMap { faces[$0] }.first
    }

    private static func register() -> [Family: [Font.Weight: String]] {
        var result: [Family: [Font.Weight: String]] = [.sans: [:], .mono: [:]]
        guard let directory = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return result
        }
        for url in files where url.pathExtension.lowercased() == "otf" || url.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first,
                  let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { continue }
            let file = url.deletingPathExtension().lastPathComponent.lowercased()
            let family: Family = file.contains("mono") ? .mono : .sans
            let weight: Font.Weight
            if file.hasSuffix("semibold") {
                weight = .semibold
            } else if file.hasSuffix("bold") {
                weight = .bold
            } else if file.hasSuffix("medium") {
                weight = .medium
            } else {
                weight = .regular
            }
            result[family]?[weight] = name
        }
        return result
    }
}
