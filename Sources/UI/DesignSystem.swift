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
    // Surface & background tokens (dynamic)
    static let bg = Color(hexLight: "FBF7EE", darkHex: "171520")
    static let surface = Color(hexLight: "F0EAE0", darkHex: "221F32")
    static let surfaceHi = Color(hexLight: "E5DED2", darkHex: "2E2A44")
    
    // Structural tokens (appearance-invariant)
    static let stroke = Color(hex: "0D0C13")
    static let borderWidth: CGFloat = 2.0
    static let shadowColor = Color(hex: "0D0C13")
    static let shadowOffset: CGFloat = 3.0

    // Card styling (dynamic)
    static let cardBg = Color(hexLight: "EADFCF", darkHex: "29253B")
    static let cardBgHover = Color(hexLight: "DFD2C0", darkHex: "342F4B")
    static let cardBgActive = Color(hexLight: "D4C5B0", darkHex: "413B5E")

    // Typography tokens (dynamic)
    static let textPrimary = Color(hexLight: "15131A", darkHex: "FAFAFD")
    static let textSecondary = Color(hexLight: "5C566F", darkHex: "A39FB8")
    static let textTertiary = Color(hexLight: "8D869F", darkHex: "6A6482")

    // Brand tokens (fixed)
    static let brandYellow = Color(hex: "FFE15D")
    static let brandPink = Color(hex: "FF5E97")
    static let brandMint = Color(hex: "54E7A2")

    // Control tokens (follows system accent)
    static var control: Color { Color.accentColor }
    static var controlDim: Color { Color.accentColor.opacity(0.16) }
    
    // Legacy token compatibility
    static var accent: Color { Color.accentColor }
    static let accentPink = Color(hex: "FF5E97")
    static var accentDim: Color { Color.accentColor.opacity(0.16) }

    // Vibrant gradients
    static let accentGradient = LinearGradient(
        colors: [Color(hex: "FFE15D"), Color(hex: "FF5E97")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static var sliderGradient: LinearGradient {
        LinearGradient(
            colors: [Color.accentColor, Color.accentColor.opacity(0.75)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    static let eqGradient = LinearGradient(
        colors: [Color(hex: "FFE15D"), Color(hex: "FF5E97"), Color(hex: "54E7A2")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Derived contrast helpers
    static var accentText: Color {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let systemAccent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(hex: "FFE15D")
            let rgb = RGBColor(r: Double(systemAccent.redComponent), g: Double(systemAccent.greenComponent), b: Double(systemAccent.blueComponent), a: Double(systemAccent.alphaComponent))
            let derived = ThemeUtils.accentText(for: rgb, isDarkBackground: isDark)
            return NSColor(srgbRed: CGFloat(derived.r), green: CGFloat(derived.g), blue: CGFloat(derived.b), alpha: CGFloat(derived.a))
        }
        return Color(nsColor: nsColor)
    }

    static func onAccent(_ fill: Color = Color.accentColor) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let systemAccent = NSColor(fill).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor(hex: "FFE15D")
            let rgb = RGBColor(r: Double(systemAccent.redComponent), g: Double(systemAccent.greenComponent), b: Double(systemAccent.blueComponent), a: Double(systemAccent.alphaComponent))
            let derived = ThemeUtils.onAccent(fill: rgb)
            return NSColor(srgbRed: CGFloat(derived.r), green: CGFloat(derived.g), blue: CGFloat(derived.b), alpha: CGFloat(derived.a))
        }
        return Color(nsColor: nsColor)
    }

    // Semantic colors (fixed)
    static let playing = Color(hex: "54E7A2")       // Neon Mint
    static let warning = Color(hex: "FFAC38")
    static let danger = Color(hex: "FF5252")

    // Spacing
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24

    // Bubblecorner radii
    static let radiusS: CGFloat = 10
    static let radiusM: CGFloat = 16
    static let radiusL: CGFloat = 22
}

enum DSFont {
    // Playful rounded font weights
    static let wordmark = Font.system(size: 16, weight: .black, design: .rounded)
    static let rowTitle = Font.system(size: 13, weight: .bold, design: .rounded)
    static let label = Font.system(size: 10, weight: .black, design: .rounded)
    static let control = Font.system(size: 11, weight: .bold, design: .rounded)
    static let mono = Font.system(size: 10, weight: .bold, design: .monospaced)
    static let caption = Font.system(size: 11, weight: .bold, design: .rounded)
}

// MARK: - View Extension for Cartoon Offset Shadow
extension View {
    func cartoonShadow(radius: CGFloat = DS.radiusM) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(DS.shadowColor)
                    .offset(x: DS.shadowOffset, y: DS.shadowOffset)
            )
    }
}
