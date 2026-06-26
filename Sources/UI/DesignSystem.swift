import SwiftUI

// Design system for SoundsSource — Cartoonish / Playful theme.
// Employs rounded bold typography, bold solid borders, bright neon accents,
// and flat offset shadows for a Neobrutalist/comic-book sticker aesthetic.

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

enum DS {
    // Playful dark indigo base colors
    static let bg = Color(hex: "171520")
    static let surface = Color(hex: "221F32")
    static let surfaceHi = Color(hex: "2E2A44")
    
    // Bold comic outlines
    static let stroke = Color(hex: "0D0C13")
    static let borderWidth: CGFloat = 2.0
    static let shadowColor = Color(hex: "0D0C13")
    static let shadowOffset: CGFloat = 3.0

    // Card styling
    static let cardBg = Color(hex: "29253B")
    static let cardBgHover = Color(hex: "342F4B")
    static let cardBgActive = Color(hex: "413B5E")

    // Typography colors
    static let textPrimary = Color(hex: "FAFAFD")
    static let textSecondary = Color(hex: "A39FB8")
    static let textTertiary = Color(hex: "6A6482")

    // Neon playful accent colors
    static let accent = Color(hex: "FFE15D")        // Banana yellow
    static let accentPink = Color(hex: "FF5E97")    // Magenta pink
    static let accentDim = Color(hex: "FFE15D").opacity(0.16)

    // Vibrant gradients
    static let accentGradient = LinearGradient(
        colors: [Color(hex: "FFE15D"), Color(hex: "FF5E97")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let sliderGradient = LinearGradient(
        colors: [Color(hex: "FF5E97"), Color(hex: "FF90B3")],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let eqGradient = LinearGradient(
        colors: [Color(hex: "FFE15D"), Color(hex: "FF5E97"), Color(hex: "54E7A2")],
        startPoint: .leading,
        endPoint: .trailing
    )

    // Semantic colors
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
