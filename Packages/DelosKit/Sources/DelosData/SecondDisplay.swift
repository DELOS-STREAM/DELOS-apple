import Foundation

/// What a second screen of this device is (`SecondDisplayOverride` of DELOS for Android, Settings → Display → Second
/// display): found out automatically, always an external monitor or TV (a stream target), or always part of the device
/// (never a stream target). Kept for the device, not per profile, under Android's key `display_second_role`. On Apple
/// devices the second screen is an external display (USB-C, HDMI adapter, AirPlay screen) or a Mac's other monitor;
/// the external-display stream reads this choice when it sorts the screens.
public enum SecondDisplayRole: String, CaseIterable, Codable, Sendable {
    case automatic
    case external
    case builtIn = "built_in"

    public static let key = "display_second_role"

    /// The stored choice; Automatic when there is none (or an unknown one).
    public static func load(_ defaults: UserDefaults = .standard) -> SecondDisplayRole {
        defaults.string(forKey: key).flatMap(SecondDisplayRole.init(rawValue:)) ?? .automatic
    }

    public static func save(_ role: SecondDisplayRole, _ defaults: UserDefaults = .standard) {
        defaults.set(role.rawValue, forKey: key)
        NotificationCenter.default.post(name: DisplaySettings.didChange, object: nil)
    }
}

/// The device-wide display settings (Second display, Main screen, the companion's idle dimming) changed: the screens and
/// the companion window follow them live.
public enum DisplaySettings {
    public static let didChange = Notification.Name("DelosDisplaySettingsDidChange")
}

/// Settings → Display → Main screen (`MainScreenChoice` of DELOS for Android, `display/DualScreen.kt`): which of the two
/// screens shows the interface and the stream while a second screen is a companion; the other one shows the companion
/// screen. Kept for the device under Android's key `display_main_screen`.
public enum MainScreenChoice: String, CaseIterable, Codable, Sendable {
    /// The larger screen (by pixels); the device's own screen when both are the same size.
    case automatic
    /// The other screen.
    case swapped

    public static let key = "display_main_screen"

    public static func load(_ defaults: UserDefaults = .standard) -> MainScreenChoice {
        defaults.string(forKey: key).flatMap(MainScreenChoice.init(rawValue:)) ?? .automatic
    }

    public static func save(_ choice: MainScreenChoice, _ defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
        NotificationCenter.default.post(name: DisplaySettings.didChange, object: nil)
    }

    /// The next (or with [direction] -1 the previous) choice, wrapping around.
    public func step(_ direction: Int) -> MainScreenChoice {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + direction) % all.count + all.count) % all.count]
    }
}

/// The idle dimming of the companion screen as the user sets it (`CompanionDim` of DELOS for Android,
/// `shell/companion/CompanionLogic.kt`): on by default because of OLED burn-in, after 1, 2, 5 or 10 minutes without a
/// touch. Kept for the device under Android's keys.
public struct CompanionDim: Equatable, Sendable {
    public static let enabledKey = "display_companion_dim"
    public static let minutesKey = "display_companion_dim_minutes"
    /// The delays the setting offers, in minutes.
    public static let minutesChoices = [1, 2, 5, 10]
    public static let defaultMinutes = 1

    public var enabled: Bool
    public var minutes: Int

    public init(enabled: Bool = true, minutes: Int = CompanionDim.defaultMinutes) {
        self.enabled = enabled
        self.minutes = minutes
    }

    /// Seconds of rest before the dim; nil while dimming is off.
    public var delay: TimeInterval? { enabled ? TimeInterval(minutes * 60) : nil }

    /// The stored policy; a missing or unknown delay is ``defaultMinutes``.
    public static func load(_ defaults: UserDefaults = .standard) -> CompanionDim {
        let stored = defaults.object(forKey: minutesKey) as? Int
        let minutes = stored.flatMap { minutesChoices.contains($0) ? $0 : nil } ?? defaultMinutes
        return CompanionDim(enabled: defaults.object(forKey: enabledKey) as? Bool ?? true, minutes: minutes)
    }

    public static func saveEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: DisplaySettings.didChange, object: nil)
    }

    public static func saveMinutes(_ minutes: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(minutesChoices.contains(minutes) ? minutes : defaultMinutes, forKey: minutesKey)
        NotificationCenter.default.post(name: DisplaySettings.didChange, object: nil)
    }

    /// The next (or with [direction] -1 the previous) delay of ``minutesChoices``, wrapping around.
    public static func step(_ minutes: Int, _ direction: Int) -> Int {
        let all = minutesChoices
        let index = all.firstIndex(of: minutes) ?? 0
        return all[((index + direction) % all.count + all.count) % all.count]
    }

    /// Whether the content is dimmed [elapsed] seconds after the last touch: never while dimming is off.
    public func dimmed(sinceTouch elapsed: TimeInterval) -> Bool {
        delay.map { elapsed >= $0 } ?? false
    }
}

/// The size of a screen in pixels, as the screen planner sees it (`PanelSource` of DELOS for Android, without an id).
public struct ScreenSize: Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixels: Int { width * height }
}

/// One of the two screens: the device's own (the iPhone's or iPad's, the Mac's built-in or menu-bar screen) or the second
/// one (an external display, AirPlay screen or another monitor).
public enum ScreenSide: Equatable, Sendable {
    case device
    case second

    public var other: ScreenSide { self == .device ? .second : .device }
}

/// Where the interface and the stream go ([main]) and where the companion screen goes ([companion], always the other one).
public struct ScreenPlan: Equatable, Sendable {
    public var main: ScreenSide
    public var companion: ScreenSide { main.other }

    public init(main: ScreenSide) {
        self.main = main
    }
}

/// What the two screens show (`DualScreenPlanner` and the external-display mode of DELOS for Android,
/// `display/DualScreen.kt:58-70`, `utils/ServerHelper.java:64-71`), a pure function of the screens and the settings.
///
/// - A second screen that is part of the device (Second display: Part of the device) pairs with the device's screen: the
///   Main screen setting picks the main one (Automatic: the one with more pixels, the device's own on a tie; Swapped: the
///   other), the interface and the stream go there and the companion screen to the other one.
/// - A monitor or TV (Automatic, External display) is left to the system (mirrored on iPhone and iPad, a free monitor on
///   the Mac) except while a stream runs with Fully External Display Mode on: the stream goes to it and the device's own
///   screen becomes the companion screen, the touch control of that stream (Android's control window).
/// - Without a second screen nothing changes.
public enum ScreenPlanner {
    /// The plan, or nil: the second screen (if any) is not DELOS's and everything stays on the device's screen.
    public static func plan(
        device: ScreenSize, second: ScreenSize?, role: SecondDisplayRole, choice: MainScreenChoice, fullExternal: Bool, streaming: Bool
    ) -> ScreenPlan? {
        guard let second else { return nil }
        if role == .builtIn { return pair(device: device, second: second, choice: choice) }
        return fullExternal && streaming ? ScreenPlan(main: .second) : nil
    }

    /// The plan of a pair: the larger screen is main with Automatic (a tie goes to the device's own screen), the other one
    /// with Swapped.
    public static func pair(device: ScreenSize, second: ScreenSize, choice: MainScreenChoice) -> ScreenPlan {
        let larger: ScreenSide = second.pixels > device.pixels ? .second : .device
        return ScreenPlan(main: choice == .automatic ? larger : larger.other)
    }

    /// Whether the two screens are a pair, so Settings → Display offers Main screen and the companion's idle dimming (Android
    /// shows them only while a built-in companion display exists).
    public static func paired(second: ScreenSize?, role: SecondDisplayRole) -> Bool {
        second != nil && role == .builtIn
    }
}

/// The corner of the full statistics panel while streaming (`StatsPosition` of DELOS for Android, `ui_stats_position`,
/// kept with the profile's settings as ``SettingKey/statsPosition``); the compact line is always at the top center.
public enum StatsPosition: String, CaseIterable, Sendable {
    case topLeft = "TOP_LEFT"
    case topRight = "TOP_RIGHT"
    case bottomLeft = "BOTTOM_LEFT"
    case bottomRight = "BOTTOM_RIGHT"

    public var top: Bool { self == .topLeft || self == .topRight }
    public var leading: Bool { self == .topLeft || self == .bottomLeft }
}

extension StreamSettings {
    /// Where the full statistics panel goes.
    public var statsPosition: StatsPosition { StatsPosition(rawValue: text(.statsPosition)) ?? .topLeft }
}
