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
