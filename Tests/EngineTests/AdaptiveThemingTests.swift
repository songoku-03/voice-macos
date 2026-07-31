import Testing
import Foundation
@testable import Core

@Suite struct AdaptiveThemingTests {
    
    // 9 macOS System Accent Color Fixtures
    static let systemAccents: [String: RGBColor] = [
        "Red":       RGBColor(hex: "FF3B30"),
        "Orange":    RGBColor(hex: "FF9500"),
        "Yellow":    RGBColor(hex: "FFCC00"),
        "Green":     RGBColor(hex: "28CD41"),
        "Blue":      RGBColor(hex: "007AFF"),
        "Purple":    RGBColor(hex: "5856D6"),
        "Pink":      RGBColor(hex: "FF2D55"),
        "Graphite":  RGBColor(hex: "8E8E93"),
        "Multicolor":RGBColor(hex: "AF52DE")
    ]
    
    @Test func testAccentTextContrastLightBackground() {
        for (name, accent) in Self.systemAccents {
            let derived = ThemeUtils.accentText(for: accent, isDarkBackground: false)
            let ratio = ThemeUtils.contrastRatio(derived, ThemeUtils.lightBg)
            #expect(ratio >= 4.5, "Accent '\(name)' text contrast on Light background is \(ratio) (expected >= 4.5)")
        }
    }
    
    @Test func testAccentTextContrastDarkBackground() {
        for (name, accent) in Self.systemAccents {
            let derived = ThemeUtils.accentText(for: accent, isDarkBackground: true)
            let ratio = ThemeUtils.contrastRatio(derived, ThemeUtils.darkBg)
            #expect(ratio >= 4.5, "Accent '\(name)' text contrast on Dark background is \(ratio) (expected >= 4.5)")
        }
    }
    
    @Test func testOnAccentFillContrast() {
        for (name, fill) in Self.systemAccents {
            let choice = ThemeUtils.onAccent(fill: fill)
            let chosenRatio = ThemeUtils.contrastRatio(choice, fill)
            let altRatio = ThemeUtils.contrastRatio(choice == ThemeUtils.darkStroke ? ThemeUtils.whiteColor : ThemeUtils.darkStroke, fill)
            #expect(chosenRatio >= altRatio, "onAccent for '\(name)' should choose higher contrast option (\(chosenRatio) vs \(altRatio))")
        }
    }
    
    @Test func testStructuralTokensAppearanceInvariant() {
        let strokeHex = "0D0C13"
        let strokeColor = RGBColor(hex: strokeHex)
        #expect(ThemeUtils.darkStroke == strokeColor)
    }
}
