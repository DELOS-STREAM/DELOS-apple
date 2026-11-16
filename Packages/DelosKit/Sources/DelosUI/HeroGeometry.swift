import Foundation

/// The hero area (`HeroArea` of DELOS for Android): the stage plus a margin on every side that the tilt (``HeroMotion``)
/// swings into view, 90 stage pixels per side at the 1920-pixel width and the 1080-pixel height, growing in proportion
/// with a wider or taller stage: 2100 × 1260 at 1920 × 1080, 2100 × 1680 at 4:3.
struct HeroArea: Equatable, Hashable, Sendable {
    let width: Double
    let height: Double

    static let marginX = 90.0
    static let marginY = 90.0

    static func of(stageWidth: Double, stageHeight: Double) -> HeroArea {
        HeroArea(width: stageWidth + 2 * marginX * stageWidth / 1920, height: stageHeight + 2 * marginY * stageHeight / 1080)
    }

    /// The area of the 1920 × 1080 stage: 2100 × 1260.
    static let standard = of(stageWidth: 1920, stageHeight: 1080)
}

/// Where a game background image sits in the hero area (`HeroGeometry` of DELOS for Android), stage pixels. A wide hero
/// (SteamGridDB: about 3.1 : 1) is fitted to the area's width at the top, and its bottom edge fades over ``fade`` pixels
/// into an extension: a heavily blurred, darkened copy of the same image over the whole area. An image that leaves
/// nothing to extend (its width-fit height reaches the area's) fills the area and is cropped.
enum HeroGeometry {
    /// The soft bottom edge of a width-fitted hero.
    static let fade = 160.0
    /// CSS blur(σ) of the extension, stage pixels.
    static let extensionBlur = 40.0
    /// How far the extension is blended toward ``extensionTint`` (darker, less saturated).
    static let extensionTintAmount = 0.55
    /// The background color of the dark theme (14, 18, 36).
    static let extensionTint = (r: 14.0, g: 18.0, b: 36.0)
    /// The band's bottom fade as (position, opacity) pairs: a smoothstep without a visible start or end.
    static let fadeStops: [(at: Double, opacity: Double)] = [(0, 1), (0.25, 0.84375), (0.5, 0.5), (0.75, 0.15625), (1, 0)]

    struct Layout: Equatable {
        /// A width-fitted band over the extension (its bottom ``fade`` pixels fade out); else it fills the area.
        let extended: Bool
        let left: Double
        let top: Double
        let width: Double
        let height: Double
        let fade: Double
        var right: Double { left + width }
        var bottom: Double { top + height }
    }

    /// The layout of a [width] × [height] hero in [area]; an image of unknown size fills the area.
    static func layout(_ area: HeroArea, width: Int, height: Int) -> Layout {
        guard width > 0, height > 0 else { return Layout(extended: false, left: 0, top: 0, width: area.width, height: area.height, fade: 0) }
        let fitHeight = area.width * Double(height) / Double(width)
        if fitHeight >= area.height { return cover(area, width: width, height: height) }
        return Layout(extended: true, left: 0, top: 0, width: area.width, height: fitHeight, fade: min(fade, fitHeight))
    }

    /// The image scaled to fill [area] and centred (a crop), whatever its shape.
    static func cover(_ area: HeroArea, width: Int, height: Int) -> Layout {
        guard width > 0, height > 0 else { return Layout(extended: false, left: 0, top: 0, width: area.width, height: area.height, fade: 0) }
        let scale = max(area.width / Double(width), area.height / Double(height))
        let w = Double(width) * scale, h = Double(height) * scale
        return Layout(extended: false, left: (area.width - w) / 2, top: (area.height - h) / 2, width: w, height: h, fade: 0)
    }

    /// The band's opacity at [position] (0 at the start of the fade, 1 at the bottom edge) on ``fadeStops``.
    static func fadeOpacity(_ position: Double) -> Double {
        if position <= 0 { return 1 }
        if position >= 1 { return 0 }
        for (a, b) in zip(fadeStops, fadeStops.dropFirst()) where position <= b.at {
            return a.opacity + (b.opacity - a.opacity) * (position - a.at) / (b.at - a.at)
        }
        return 0
    }
}

/// A centred, symmetric orbit of the hero plane's normal (`HeroMotion` of DELOS for Android): 15° around, once in 25 s,
/// no pan, roll or zoom. The plane is scaled by ``overscan`` so the area still covers the screen at every phase.
enum HeroMotion {
    static let period = 25.0
    static let degrees = 15.0
    static let overscan = 1.02
    /// The camera's distance, as a multiple of the area's longer side.
    static let cameraDistanceFactor = 2.2

    /// The orbit's phase (0...1) at [time] seconds of a shared clock, so every copy is in phase and none restarts.
    static func turn(at time: TimeInterval) -> Double {
        let t = time.truncatingRemainder(dividingBy: period)
        return (t < 0 ? t + period : t) / period
    }

    static func pitch(_ turn: Double, reduced: Bool) -> Double { reduced ? 0 : degrees * sin(turn * 2 * .pi) }
    static func yaw(_ turn: Double, reduced: Bool) -> Double { reduced ? 0 : degrees * cos(turn * 2 * .pi) }
}
