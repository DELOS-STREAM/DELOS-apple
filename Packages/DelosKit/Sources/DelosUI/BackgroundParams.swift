import CoreGraphics
import DelosData

/// What every background is drawn from: the canvas, the clock and the hues, as `BgParams` in DELOS for Android
/// (`shell/ui/Backdrop.kt`). Material You does not exist on Apple platforms, so the secondary color is always [tint].
struct BackgroundParams: Equatable {
    /// The prototype's canvas: 960 × 540 canvas pixels, the coordinates every background is drawn in.
    static let canvas = CGSize(width: 960, height: 540)

    /// The canvas the shapes are drawn on, in canvas pixels: 960 × 540 at 16:9, extended along the longer axis.
    var w: Double
    var h: Double
    var t: Double
    var dark: Bool
    /// The secondary color: the palette's, or (later) the focused game's.
    var tint: Double
    var base: Double
    var acc: Double
    var acc2: Double
    var acc3: Double
    /// How saturated the main, secondary and accent colors are (below 1 for a game's muted colors).
    var sat1 = 1.0
    var sat2 = 1.0
    var sat3 = 1.0

    /// The palette path (no game colors): main, secondary and accent hues of the theme.
    init(colors: DelosColors, canvas: CGSize, t: Double) {
        w = canvas.width
        h = canvas.height
        self.t = t
        dark = colors.dark
        tint = colors.accent2Hue
        base = colors.baseHue
        acc = colors.accentHue
        acc2 = colors.accent2Hue
        acc3 = colors.accent3Hue
    }

    /// The saturation factor of hue `hue` when it is one of the three colors, else 1 (the first match wins, as
    /// Kotlin's `when`).
    func s(_ hue: Double) -> Double {
        switch hue {
        case acc: sat1
        case acc2, tint: sat2
        case acc3: sat3
        default: 1
        }
    }

    /// The three lights of the shader backgrounds: main, secondary (or the focused game's color) and accent.
    var lights: (c1: RGBA, c2: RGBA, c3: RGBA) {
        dark
            ? (hsl(acc, 85 * sat1, 56), hsl(tint, 85 * sat2, 56), hsl(acc3, 85 * sat3, 62))
            : (hsl(acc, 80 * sat1, 58), hsl(tint, 80 * sat2, 58), hsl(acc3, 80 * sat3, 62))
    }

    /// How strongly the shader backgrounds light the theme color.
    var glow: Double { dark ? 0.62 : 0.5 }

    /// The canvas for a view of `size` points: one scale for both axes (the shapes keep their proportions), so the
    /// canvas grows along the axis that has more room. `unit` is points per canvas pixel.
    static func canvas(for size: CGSize) -> (unit: Double, canvas: CGSize) {
        let unitX = size.width / canvas.width
        let unitY = size.height / canvas.height
        let unit = min(unitX, unitY)
        guard unit > 0 else { return (1, canvas) }
        return (unit, CGSize(
            width: unitX <= unitY ? canvas.width : size.width / unit,
            height: unitY <= unitX ? canvas.height : size.height / unit
        ))
    }
}

/// How each background is drawn.
enum BackgroundStyle: Equatable {
    /// Only the base gradient.
    case still
    /// Shapes drawn on a canvas (Aurora, Tide, Silk).
    case canvas
    /// Contour: a glow and the line shader.
    case contour
    /// A full-screen shader of the three lights; the name of its Metal function.
    case shader(String)

    init(_ kind: BackgroundKind) {
        self = switch kind {
        case .still: .still
        case .aurora, .tide, .silk: .canvas
        case .contour: .contour
        case .nebula: .shader("delosNebula")
        case .plasma: .shader("delosPlasma")
        case .lava: .shader("delosLava")
        case .caustics: .shader("delosCaustics")
        case .bokeh: .shader("delosBokeh")
        case .orbit: .shader("delosOrbit")
        }
    }
}
