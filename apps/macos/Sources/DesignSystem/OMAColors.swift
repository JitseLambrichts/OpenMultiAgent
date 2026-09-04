import AppKit
import SwiftUI

/// Semantic palette. Dark values follow the approved reference values; light and
/// increased-contrast variants come from a dynamic `NSColor` so the same names
/// work in every appearance without an asset catalog.
enum OMAColor {
    static let canvas = dynamic(
        dark: (11, 13, 18), light: (246, 247, 250),
        darkHighContrast: (0, 0, 0), lightHighContrast: (255, 255, 255)
    )
    static let surface = dynamic(
        dark: (18, 22, 32), light: (255, 255, 255),
        darkHighContrast: (8, 8, 12), lightHighContrast: (255, 255, 255)
    )
    static let elevated = dynamic(
        dark: (25, 30, 42), light: (238, 240, 246),
        darkHighContrast: (18, 20, 28), lightHighContrast: (232, 234, 240)
    )
    static let accent = dynamic(
        dark: (110, 139, 255), light: (64, 96, 235),
        darkHighContrast: (150, 172, 255), lightHighContrast: (30, 60, 200)
    )
    static let positive = dynamic(
        dark: (91, 207, 154), light: (24, 150, 94),
        darkHighContrast: (140, 230, 185), lightHighContrast: (0, 110, 60)
    )
    static let attention = dynamic(
        dark: (237, 184, 91), light: (190, 120, 10),
        darkHighContrast: (255, 210, 130), lightHighContrast: (140, 85, 0)
    )
    static let negative = dynamic(
        dark: (240, 110, 110), light: (200, 50, 50),
        darkHighContrast: (255, 150, 150), lightHighContrast: (160, 20, 20)
    )

    /// Separators and quiet text use system semantics so vibrancy and contrast
    /// settings keep working on every surface.
    static let separator = Color(nsColor: .separatorColor)
    static let quiet = Color.secondary

    private typealias RGB = (Int, Int, Int)

    private static func dynamic(
        dark: RGB,
        light: RGB,
        darkHighContrast: RGB,
        lightHighContrast: RGB
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ])
            let rgb: RGB = switch match {
            case .darkAqua: dark
            case .accessibilityHighContrastDarkAqua: darkHighContrast
            case .accessibilityHighContrastAqua: lightHighContrast
            default: light
            }
            return NSColor(
                srgbRed: CGFloat(rgb.0) / 255,
                green: CGFloat(rgb.1) / 255,
                blue: CGFloat(rgb.2) / 255,
                alpha: 1
            )
        })
    }
}

/// Appearance preference. Dark is the default; System and Light remain available.
enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case dark
    case system
    case light

    static let storageKey = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .dark: "Donker"
        case .system: "Systeem"
        case .light: "Licht"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}
