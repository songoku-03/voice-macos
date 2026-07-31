import SwiftUI
import AppKit
import Core

// Design system for SoundsSource — Neobrutalist / Comic aesthetic.
// Supports appearance-aware light (warm cream) and dark (indigo) themes
// with role-based token taxonomy (Brand, Control, Semantic).

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(.sRGB,
                  red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    init(hexLight lightHex: String, darkHex: String) {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? darkHex : lightHex)
        }
        self.init(nsColor: nsColor)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
}

enum DS {
    // Surface & background tokens (dynamic macOS adaptive translucent tones)
    static let bg = Color(hexLight: "F6F6F8", darkHex: "12111A")
    static let surface = Color(hexLight: "FFFFFF", darkHex: "1B1926")
    static let surfaceHi = Color(hexLight: "EFF1F5", darkHex: "262335")
    
    // Structural tokens (crisp 1px hairline stroke & soft ambient shadow)
    static let stroke = Color(hexLight: "D8DCE6", darkHex: "353147")
    static let borderWidth: CGFloat = 1.0
    static let shadowColor = Color.black.opacity(0.15)
    static let shadowOffset: CGFloat = 0.0

    // Card styling (dynamic glassmorphic layers)
    static let cardBg = Color(hexLight: "F8F9FA", darkHex: "211E2F")
    static let cardBgHover = Color(hexLight: "F1F3F7", darkHex: "2B273D")
    static let cardBgActive = Color(hexLight: "E9ECEF", darkHex: "342F4B")

    // Typography tokens (dynamic)
    static let textPrimary = Color(hexLight: "1A1C23", darkHex: "F8FAFC")
    static let textSecondary = Color(hexLight: "5A6072", darkHex: "A0A7BC")
    static let textTertiary = Color(hexLight: "8A92A6", darkHex: "6C748B")

    // Brand tokens (fixed vibrant modern palette)
    static let brandYellow = Color(hex: "F59E0B")
    static let brandPink = Color(hex: "EC4899")
    static let brandMint = Color(hex: "10B981")

    // Control tokens (follows system accent)
    static var control: Color { Color.accentColor }
    static var controlDim: Color { Color.accentColor.opacity(0.15) }
    
    // Legacy token compatibility
    static var accent: Color { Color.accentColor }
    static let accentPink = Color(hex: "EC4899")
    static var accentDim: Color { Color.accentColor.opacity(0.15) }

    // Vibrant gradients
    static let accentGradient = LinearGradient(
        colors: [Color(hex: "6366F1"), Color(hex: "EC4899")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static var sliderGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    static let eqGradient = LinearGradient(
        colors: [Color(hex: "6366F1"), Color(hex: "EC4899"), Color(hex: "10B981")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Derived contrast helpers
    static var accentText: Color {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let systemAccent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(hex: "6366F1")
            let rgb = RGBColor(r: Double(systemAccent.redComponent), g: Double(systemAccent.greenComponent), b: Double(systemAccent.blueComponent), a: Double(systemAccent.alphaComponent))
            let derived = ThemeUtils.accentText(for: rgb, isDarkBackground: isDark)
            return NSColor(srgbRed: CGFloat(derived.r), green: CGFloat(derived.g), blue: CGFloat(derived.b), alpha: CGFloat(derived.a))
        }
        return Color(nsColor: nsColor)
    }

    static func onAccent(_ fill: Color = Color.accentColor) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let systemAccent = NSColor(fill).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(hex: "6366F1")
            let rgb = RGBColor(r: Double(systemAccent.redComponent), g: Double(systemAccent.greenComponent), b: Double(systemAccent.blueComponent), a: Double(systemAccent.alphaComponent))
            let derived = ThemeUtils.onAccent(fill: rgb)
            return NSColor(srgbRed: CGFloat(derived.r), green: CGFloat(derived.g), blue: CGFloat(derived.b), alpha: CGFloat(derived.a))
        }
        return Color(nsColor: nsColor)
    }

    // Semantic colors (fixed)
    static let playing = Color(hex: "10B981")       // Modern Emerald Mint
    static let warning = Color(hex: "F59E0B")       // Amber
    static let danger = Color(hex: "EF4444")        // Rose Red

    // Spacing
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24

    // Modern corner radii
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 12
    static let radiusL: CGFloat = 16
}

enum DSFont {
    // Sleek macOS font hierarchy
    static let wordmark = Font.system(size: 15, weight: .bold, design: .rounded)
    static let rowTitle = Font.system(size: 13, weight: .semibold, design: .default)
    static let label = Font.system(size: 10, weight: .bold, design: .default)
    static let control = Font.system(size: 11, weight: .semibold, design: .default)
    static let mono = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let caption = Font.system(size: 11, weight: .medium, design: .default)
}

// MARK: - View Extension for Soft macOS Drop Shadow
extension View {
    func cartoonShadow(radius: CGFloat = DS.radiusM) -> some View {
        self.shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
    }
}
