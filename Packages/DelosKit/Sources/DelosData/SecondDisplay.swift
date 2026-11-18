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
