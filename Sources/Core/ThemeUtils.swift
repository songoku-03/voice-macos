import Foundation

public struct RGBColor: Equatable, Sendable {
    public let r: Double // 0...1
    public let g: Double // 0...1
    public let b: Double // 0...1
    public let a: Double // 0...1

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
        self.a = min(max(a, 0), 1)
    }

    public init(hex: String) {
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
        self.r = Double(r) / 255.0
        self.g = Double(g) / 255.0
        self.b = Double(b) / 255.0
        self.a = Double(a) / 255.0
    }

    public var toHSB: (h: Double, s: Double, b: Double) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC

        var h: Double = 0
        if delta > 0 {
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h *= 60
            if h < 0 { h += 360 }
        }

        let s = maxC == 0 ? 0 : delta / maxC
        let b = maxC
        return (h: h, s: s, b: b)
    }

    public static func fromHSB(h: Double, s: Double, b: Double, a: Double = 1.0) -> RGBColor {
        let c = b * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c

        var r1: Double = 0
        var g1: Double = 0
        var b1: Double = 0

        switch h {
        case 0..<60:    (r1, g1, b1) = (c, x, 0)
        case 60..<120:  (r1, g1, b1) = (x, c, 0)
        case 120..<180: (r1, g1, b1) = (0, c, x)
        case 180..<240: (r1, g1, b1) = (0, x, c)
        case 240..<300: (r1, g1, b1) = (x, 0, c)
        default:        (r1, g1, b1) = (c, 0, x)
        }

        return RGBColor(r: r1 + m, g: g1 + m, b: b1 + m, a: a)
    }
}

public enum ThemeUtils {
    
    // WCAG Relative Luminance formula (sRGB linearized)
    public static func relativeLuminance(_ color: RGBColor) -> Double {
        func linearize(_ component: Double) -> Double {
            return component <= 0.04045 ? (component / 12.92) : pow((component + 0.055) / 1.055, 2.4)
        }
        let R = linearize(color.r)
        let G = linearize(color.g)
        let B = linearize(color.b)
        return 0.2126 * R + 0.7152 * G + 0.0722 * B
    }

    // WCAG Contrast ratio formula (L1 + 0.05) / (L2 + 0.05)
    public static func contrastRatio(_ c1: RGBColor, _ c2: RGBColor) -> Double {
        let l1 = relativeLuminance(c1)
        let l2 = relativeLuminance(c2)
        let maxL = max(l1, l2)
        let minL = min(l1, l2)
        return (maxL + 0.05) / (minL + 0.05)
    }

    // Background reference colors
    public static let lightBg = RGBColor(hex: "FBF7EE")
    public static let darkBg  = RGBColor(hex: "171520")
    public static let darkStroke = RGBColor(hex: "0D0C13")
    public static let whiteColor = RGBColor(r: 1, g: 1, b: 1)

    // Derive text-safe accent color guaranteed to meet WCAG >= 4.5:1 contrast against target background
    public static func accentText(for accent: RGBColor, isDarkBackground: Bool) -> RGBColor {
        let bg = isDarkBackground ? darkBg : lightBg
        let current = accent
        
        if contrastRatio(current, bg) >= 4.5 {
            return current
        }

        let hsb = accent.toHSB
        let h = hsb.h
        let s = hsb.s

        if isDarkBackground {
            // Dark background: lighten brightness up towards 1.0
            for step in 0...20 {
                let newB = min(1.0, hsb.b + Double(step) * 0.03)
                let candidate = RGBColor.fromHSB(h: h, s: s, b: newB, a: accent.a)
                if contrastRatio(candidate, bg) >= 4.5 {
                    return candidate
                }
            }
            return whiteColor
        } else {
            // Light background: darken brightness / adjust saturation
            for step in 0...30 {
                let newB = max(0.1, hsb.b - Double(step) * 0.025)
                let newS = min(1.0, s + Double(step) * 0.01)
                let candidate = RGBColor.fromHSB(h: h, s: newS, b: newB, a: accent.a)
                if contrastRatio(candidate, bg) >= 4.5 {
                    return candidate
                }
            }
            return darkStroke
        }
    }

    // Determine label color on top of an accent fill (chooses highest contrast between dark stroke and white)
    public static func onAccent(fill: RGBColor) -> RGBColor {
        let whiteContrast = contrastRatio(whiteColor, fill)
        let darkContrast = contrastRatio(darkStroke, fill)
        return darkContrast >= whiteContrast ? darkStroke : whiteColor
    }
}
