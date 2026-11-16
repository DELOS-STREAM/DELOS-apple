import DelosData
import SwiftUI

/// A color as linear components in the sRGB space, 0...1, with straight (not premultiplied) alpha.
public struct RGBA: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    public func opacity(_ alpha: Double) -> RGBA { RGBA(red: red, green: green, blue: blue, alpha: alpha) }
}

/// CSS-style `hsl()`: hue in degrees (any value), saturation and lightness in percent; out-of-range values are clamped.
/// The same function as `hsl()` in DELOS for Android (`shell/ui/Colors.kt`).
public func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> RGBA {
    let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    let sat = min(max(s / 100, 0), 1)
    let light = min(max(l / 100, 0), 1)
    let chroma = (1 - abs(2 * light - 1)) * sat
    let sector = hue / 60
    let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double) = switch sector {
    case ..<1: (chroma, x, 0)
    case ..<2: (x, chroma, 0)
    case ..<3: (0, chroma, x)
    case ..<4: (0, x, chroma)
    case ..<5: (x, 0, chroma)
    default: (chroma, 0, x)
    }
    let m = light - chroma / 2
    return RGBA(red: r + m, green: g + m, blue: b + m, alpha: min(max(a, 0), 1))
}

/// Shortest-path hue interpolation.
public func lerpHue(_ a: Double, _ b: Double, _ k: Double) -> Double {
    let d = ((b - a + 540).truncatingRemainder(dividingBy: 360)) - 180
    return (a + d * k + 360).truncatingRemainder(dividingBy: 360)
}

/// The color palettes: the background's hue and saturation and the three colors, main (buttons, focus, selection),
/// secondary (rings, pulses, gradients) and accent (small highlights). Soft palettes use pastel accents.
/// The values match `Palette` in DELOS for Android (`shell/settings/AppearanceStore.kt`).
public enum Palette: String, CaseIterable, Sendable {
    case delos, ember, rose, orchid, dusk, iris, graphite, mint

    public var base: Double { values.0 }
    public var baseSat: Double { values.1 }
    public var accent: Double { values.2 }
    public var accent2: Double { values.3 }
    public var accent3: Double { values.4 }
    public var soft: Bool { values.5 }

    private var values: (Double, Double, Double, Double, Double, Bool) {
        switch self {
        case .delos: (222, 38, 40, 190, 335, false)
        case .ember: (195, 28, 12, 40, 330, false)
        case .rose: (285, 30, 345, 15, 205, false)
        case .orchid: (258, 36, 305, 270, 48, false)
        case .dusk: (232, 12, 268, 205, 330, true)
        case .iris: (25, 22, 232, 190, 40, false)
        case .graphite: (220, 7, 205, 175, 45, true)
        case .mint: (190, 22, 150, 190, 330, true)
        }
    }
}

extension Palette {
    /// The palette a stored ``PaletteName`` stands for.
    public init(_ name: PaletteName) {
        // Both enums list the same names (ColorsTests checks it)
        self = Palette(rawValue: name.rawValue) ?? .delos
    }
}

/// The color tokens of the interface, derived from a palette by the formulas of the prototype (`applyTheme()`) and
/// of `delosColors()` in DELOS for Android. Material You has no counterpart on Apple platforms.
public struct DelosColors: Equatable, Sendable {
    public let dark: Bool
    public let baseHue: Double
    public let accentHue: Double
    public let accent2Hue: Double
    public let accent3Hue: Double
    public let bg: RGBA
    public let bg2: RGBA
    public let surface: RGBA
    public let surface2: RGBA
    public let surface3: RGBA
    public let line: RGBA
    public let text: RGBA
    public let text2: RGBA
    public let text3: RGBA
    public let accent: RGBA
    public let accent2: RGBA
    public let accent3: RGBA
    public let onAccent: RGBA
    public let glow: RGBA
    public let scrim: RGBA

    public init(palette: Palette, dark: Bool) {
        let base = palette.base, acc = palette.accent, acc2 = palette.accent2, acc3 = palette.accent3
        let soft = palette.soft
        self.dark = dark
        baseHue = base
        accentHue = acc
        accent2Hue = acc2
        accent3Hue = acc3
        if dark {
            let sat = palette.baseSat
            // Surfaces and text keep a floor and a ceiling, so the muted palettes stay almost neutral
            let surf = { (drop: Double) in max(2, sat - drop) }
            let txt = { (cap: Double) in min(cap, sat) }
            bg = hsl(base, sat, 7)
            bg2 = hsl(base, sat - 4, 11)
            surface = hsl(base, surf(10), 14, 0.72)
            surface2 = hsl(base, surf(12), 19, 0.84)
            surface3 = hsl(base, surf(14), 23, 0.94)
            line = hsl(base, 35, 70, 0.14)
            text = hsl(base, txt(30), 96)
            text2 = hsl(base, txt(16), 76)
            text3 = hsl(base, txt(12), 58)
            accent = soft ? hsl(acc, 70, 70) : hsl(acc, 95, 62)
            accent2 = soft ? hsl(acc2, 62, 68) : hsl(acc2, 85, 62)
            accent3 = soft ? hsl(acc3, 60, 72) : hsl(acc3, 85, 68)
            onAccent = hsl(acc, 55, 12)
            glow = hsl(acc, soft ? 70 : 95, 58, 0.45)
            scrim = hsl(base, 50, 3, 0.62)
        } else {
            let sat = palette.baseSat + 2
            bg = hsl(base, sat, 95)
            bg2 = hsl(base, palette.baseSat - 4, 90)
            surface = hsl(base, 60, 99, 0.74)
            surface2 = hsl(base, 50, 99, 0.9)
            surface3 = hsl(base, 40, 98, 0.97)
            line = hsl(base, 30, 30, 0.13)
            text = hsl(base, 40, 12)
            text2 = hsl(base, 18, 32)
            text3 = hsl(base, 12, 46)
            accent = soft ? hsl(acc - 6, 65, 46) : hsl(acc - 6, 92, 52)
            accent2 = soft ? hsl(acc2, 55, 40) : hsl(acc2, 80, 40)
            accent3 = soft ? hsl(acc3, 50, 44) : hsl(acc3, 75, 44)
            onAccent = hsl(acc, 60, 12)
            glow = hsl(acc, 85, 50, 0.34)
            scrim = hsl(base, 30, 20, 0.35)
        }
    }

    /// What sits on an ``accent3`` fill: dark on the light colors of the dark theme, white on the light theme's.
    public var onAccent3: RGBA { dark ? onAccent : RGBA(red: 1, green: 1, blue: 1) }
}

extension EnvironmentValues {
    /// The color tokens of the current theme.
    @Entry public var delosColors = DelosColors(palette: .delos, dark: true)
}
