import AppKit
import SwiftUI

/// Volley's colors, each with a light and a dark variant so the app follows the system appearance.
/// `PaletteTests` checks every text/background pair stays readable (WCAG AA) in both.
enum Palette {
    static let coral = adaptive(light: 0xFF9E8F, dark: 0xFF9E8F)
    /// Incoming message bubbles.
    static let blush = adaptive(light: 0xFFE3DB, dark: 0x4A2F2A)
    /// Body text on Volley surfaces.
    static let ink = adaptive(light: 0x2A1F1D, dark: 0xF3E6E2)
    /// Text and marks on coral (buttons, outgoing bubbles, the logo): dark in both modes.
    static let onCoral = adaptive(light: 0x2A1F1D, dark: 0x2A1F1D)
    /// Window and panel backgrounds.
    static let shell = adaptive(light: 0xFFF6F2, dark: 0x1E1817)
    /// Raised surfaces: cards, the message box, tiles.
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2220)
    /// Secondary text.
    static let muted = adaptive(light: 0x6B5753, dark: 0xB5A19C)

    private static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let coral = Color(nsColor: Palette.coral)
    static let blush = Color(nsColor: Palette.blush)
    static let ink = Color(nsColor: Palette.ink)
    static let onCoral = Color(nsColor: Palette.onCoral)
    static let shell = Color(nsColor: Palette.shell)
    static let card = Color(nsColor: Palette.card)
    static let muted = Color(nsColor: Palette.muted)
}
