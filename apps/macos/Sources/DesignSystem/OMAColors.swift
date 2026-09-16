import SwiftUI

/// Semantic palette. The app is dark-only: a near-black canvas, two stacked
/// greys for cards, lime as the single accent and orange as the second voice.
enum OMAColor {
    /// Window and page background.
    static let canvas = Color(red: 13 / 255, green: 13 / 255, blue: 13 / 255)
    /// Cards and panels.
    static let surface = Color(red: 27 / 255, green: 27 / 255, blue: 27 / 255)
    /// Rows, chips and inner cards that sit on a surface.
    static let elevated = Color(red: 38 / 255, green: 38 / 255, blue: 38 / 255)
    /// Hover state for elevated controls.
    static let raised = Color(red: 48 / 255, green: 48 / 255, blue: 48 / 255)

    /// Lime accent: primary actions, the selected sidebar item, highlights.
    static let accent = Color(red: 201 / 255, green: 246 / 255, blue: 111 / 255)
    /// Text drawn on top of the lime accent.
    static let onAccent = Color(red: 12 / 255, green: 14 / 255, blue: 8 / 255)
    /// Orange: the second voice for attention, secondary series, Claude.
    static let attention = Color(red: 247 / 255, green: 154 / 255, blue: 62 / 255)
    static let positive = Color(red: 171 / 255, green: 233 / 255, blue: 104 / 255)
    static let negative = Color(red: 255 / 255, green: 110 / 255, blue: 110 / 255)

    /// Hairline for the few places that still need a stroke (fields, diffs).
    static let separator = Color.white.opacity(0.07)
    static let quiet = Color.secondary
}
