import SwiftUI

/// The web app's palette, transcribed from `src/app/globals.css`.
///
/// Same values rather than iOS system colours, because the two clients show the
/// same questions to the same children and a parent will see both. The design
/// brief there applies here unchanged: "minimal and calm rather than playful -
/// big type, big targets, few things on screen at once".
///
/// Light only, for now. The web app defines no dark palette, and inventing one
/// here would be the native client deciding what the product looks like — with
/// the figure ink colour in particular being a decision the diagram spec makes
/// (`--color-ink` on `--color-card`), not one a renderer gets to reinterpret.
enum Palette {
    static let ink = Color(hex: 0x1B2430)
    static let inkSoft = Color(hex: 0x5B6B7F)
    static let paper = Color(hex: 0xF7F9FC)
    static let card = Color(hex: 0xFFFFFF)
    static let brand = Color(hex: 0x3B6EF5)
    static let brandSoft = Color(hex: 0xE5EDFF)
    static let right = Color(hex: 0x17A06A)
    static let rightSoft = Color(hex: 0xE2F6ED)
    static let wrong = Color(hex: 0xE2705A)
    static let wrongSoft = Color(hex: 0xFDEEEA)
    static let line = Color(hex: 0xDFE6EF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}
