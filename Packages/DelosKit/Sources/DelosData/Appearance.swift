import Foundation

/// The animated backgrounds (Settings → Appearance), as in DELOS for Android (`BackgroundKind`).
public enum BackgroundKind: String, CaseIterable, Codable, Sendable {
    case aurora, tide, silk, contour, nebula, plasma, lava, caustics, bokeh, orbit, still
}

/// The color palettes, by name; their hues live with the color tokens in DelosUI.
public enum PaletteName: String, CaseIterable, Codable, Sendable {
    case delos, ember, rose, orchid, dusk, iris, graphite, mint
}

/// How the status bar shows the time.
public enum ClockFormat: String, CaseIterable, Codable, Sendable {
    case system, h12, h24
}

/// Settings → Appearance. The defaults are the first-run look of DELOS for Android (owner, 2026-11-16): DELOS palette,
/// dark theme, Contour background, game colors and game backgrounds on (blur 5, opacity 80 %), interface scale 100 %.
public struct Appearance: Codable, Equatable, Sendable {
    public var dark = true
    /// The interface takes its colors from the system instead of the palette (`ui_material_you`): on the Mac the accent
    /// color of System Settings → Appearance. iPhone, iPad and Apple TV have no system color to follow.
    public var materialYou = false
    public var palette = PaletteName.delos
    public var clock = ClockFormat.system
    /// The animated background takes on the main color of the focused game's background image.
    public var matchGameColors = true
    public var background = BackgroundKind.contour
    public var heroBackground = true
    /// Game background blur in stage pixels, 0...40.
    public var heroBlur = 5 { didSet { heroBlur = min(max(heroBlur, 0), 40) } }
    /// Game background opacity in percent, 0...100.
    public var heroOpacity = 80 { didSet { heroOpacity = min(max(heroOpacity, 0), 100) } }
    /// Interface scale in percent, 100...130.
    public var uiScale = 100 { didSet { uiScale = min(max(uiScale, 100), 130) } }
    public var reducedMotion = false
    public var sounds = true
    public var haptics = true

    public init() {}

    /// Reads stored settings leniently: a missing or unknown value (an option removed in a later version) falls back to
    /// its default instead of discarding all settings, and numbers are clamped to their ranges.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        dark = value(.dark, d.dark)
        materialYou = value(.materialYou, d.materialYou)
        palette = value(.palette, d.palette)
        clock = value(.clock, d.clock)
        matchGameColors = value(.matchGameColors, d.matchGameColors)
        background = value(.background, d.background)
        heroBackground = value(.heroBackground, d.heroBackground)
        heroBlur = min(max(value(.heroBlur, d.heroBlur), 0), 40)
        heroOpacity = min(max(value(.heroOpacity, d.heroOpacity), 0), 100)
        uiScale = min(max(value(.uiScale, d.uiScale), 100), 130)
        reducedMotion = value(.reducedMotion, d.reducedMotion)
        sounds = value(.sounds, d.sounds)
        haptics = value(.haptics, d.haptics)
    }
}

/// Stores the ``Appearance`` of each profile in `UserDefaults` (small, and kept on tvOS, which may purge files).
public struct AppearanceStore: Sendable {
    private let suiteName: String?

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String) -> String { "appearance.\(profile)" }

    public func load(profile: String) -> Appearance {
        guard let data = defaults.data(forKey: key(profile)),
              let appearance = try? JSONDecoder().decode(Appearance.self, from: data) else { return Appearance() }
        return appearance
    }

    public func save(_ appearance: Appearance, profile: String) {
        guard let data = try? JSONEncoder().encode(appearance) else { return }
        defaults.set(data, forKey: key(profile))
    }

    /// Forgets a removed profile's appearance.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }
}
