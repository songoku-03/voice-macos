import SwiftUI

// Design system for SoundsSource — applies the swiftui-design-skill (MIT, © wholiver).
//
// Direction: "Functional + Warm" — a pro-audio menu-bar tool. We deliberately avoid the
// banned neon-on-black "cyber" look: a single warm coral accent on warm near-black
// neutrals, a serif wordmark as the signature detail, an 8pt spacing grid, and monospaced
// numerics for the audio-tool feel. macOS dark-only, so colors are fixed (no UIColor
// light/dark machinery from the skill's iOS reference).

// MARK: - Color(hex:) — macOS-compatible (skill's reference uses UIColor; this doesn't)

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
}

// MARK: - Design Tokens

enum DS {
    // Neutrals — warm near-black, never pure #000 / #FFF (skill color rules 6 & 7)
    static let bg = Color(hex: "17161A")          // window / popover base
    static let surface = Color(hex: "201F24").opacity(0.6) // translucent header, footer
    static let surfaceHi = Color(hex: "2A2930").opacity(0.8) // expanded / hovered surface
    static let stroke = Color(hex: "302E36").opacity(0.5) // hairline dividers & borders

    // Card design backgrounds
    static let cardBg = Color(hex: "222026").opacity(0.4)
    static let cardBgHover = Color(hex: "2D2B33").opacity(0.65)
    static let cardBgActive = Color(hex: "35323C").opacity(0.85)

    static let textPrimary = Color(hex: "F3F1EE")   // warm white
    static let textSecondary = Color(hex: "9C978F")  // warm gray
    static let textTertiary = Color(hex: "6A655E")   // muted

    // One warm accent defines the brand (replaces the old cyan/cyber tint)
    static let accent = Color(hex: "F0623E")        // warm coral
    static let accentDim = Color(hex: "F0623E").opacity(0.12) // soft accent fills

    // Modern gradients for UI elements
    static let accentGradient = LinearGradient(
        colors: [Color(hex: "F0623E"), Color(hex: "E54E5F")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let sliderGradient = LinearGradient(
        colors: [Color(hex: "F0623E"), Color(hex: "EA5380")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let eqGradient = LinearGradient(
        colors: [Color(hex: "F0623E"), Color(hex: "E54E5F"), Color(hex: "E8A14B")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Semantic — green means "producing audio right now"; amber/red reserved for levels
    static let playing = Color(hex: "5FD08A")
    static let warning = Color(hex: "E8A14B")
    static let danger = Color(hex: "E5564B")

    // Spacing — 8pt grid (skill spacing system)
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24

    // Corner radius — consistent across the app
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10
    static let radiusL: CGFloat = 14
}

// MARK: - Type Scale (skill typography hierarchy)

enum DSFont {
    // Display: serif wordmark — the signature detail that sets the app apart
    static let wordmark = Font.system(size: 16, weight: .bold, design: .serif)
    // Headings / row titles
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    // Labels — uppercased section labels
    static let label = Font.system(size: 9, weight: .bold)
    static let control = Font.system(size: 11, weight: .medium)
    // Numerics — monospaced for the audio-tool feel (volume %, dB)
    static let mono = Font.system(size: 10, weight: .medium, design: .monospaced)
    static let caption = Font.system(size: 11, weight: .medium)
}
