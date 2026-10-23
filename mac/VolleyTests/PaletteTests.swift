import AppKit
import XCTest
@testable import Volley

/// Every text/background pair the app uses must stay readable (WCAG AA, 4.5:1) in light and dark mode.
final class PaletteTests: XCTestCase {
    private struct RGB { let r, g, b: Double }

    private func rgb(_ color: NSColor, _ appearance: NSAppearance.Name) -> RGB {
        var out = RGB(r: 0, g: 0, b: 0)
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        }
        return out
    }

    private func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private struct Pair { let name: String; let text: NSColor; let background: NSColor }

    private func contrast(_ a: NSColor, on b: NSColor, _ appearance: NSAppearance.Name) -> Double {
        let la = luminance(rgb(a, appearance)), lb = luminance(rgb(b, appearance))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let pairs = [
        Pair(name: "ink on shell", text: Palette.ink, background: Palette.shell),
        Pair(name: "ink on card", text: Palette.ink, background: Palette.card),
        Pair(name: "ink on blush (incoming bubble)", text: Palette.ink, background: Palette.blush),
        Pair(name: "onCoral on coral (outgoing bubble, buttons)", text: Palette.onCoral, background: Palette.coral),
        Pair(name: "muted on shell", text: Palette.muted, background: Palette.shell),
        Pair(name: "muted on card", text: Palette.muted, background: Palette.card)
    ]

    func testReadableInLightAndDark() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for pair in pairs {
                let ratio = contrast(pair.text, on: pair.background, appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(pair.name) in \(appearance.rawValue): \(ratio)")
            }
        }
    }

    func testSurfacesAreDarkInDarkMode() {
        XCTAssertLessThan(luminance(rgb(Palette.shell, .darkAqua)), 0.05)
        XCTAssertLessThan(luminance(rgb(Palette.card, .darkAqua)), 0.08)
        XCTAssertGreaterThan(luminance(rgb(Palette.shell, .aqua)), 0.85)
    }
}
