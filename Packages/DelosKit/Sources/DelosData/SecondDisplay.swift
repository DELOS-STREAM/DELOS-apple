import Foundation

/// Where a stream goes (the external-display mode of DELOS for Android, `utils/ServerHelper.java:64-71`), a pure function
/// of the screens and the settings: to a connected second screen (on Apple devices always an external display: USB-C, HDMI
/// adapter, AirPlay screen or a Mac's other monitor) only while the profile's Fully External Display Mode is on. Otherwise
/// the second screen (if any) is left to the system: mirrored on iPhone and iPad, a free monitor on the Mac.
public enum ExternalDisplayPlan {
    public static func streamsOnSecond(secondConnected: Bool, fullExternal: Bool, streaming: Bool) -> Bool {
        secondConnected && fullExternal && streaming
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
