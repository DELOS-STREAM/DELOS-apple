import DelosCore
import GameController

/// A controller's battery as the host gets it (`sendControllerBatteryPacket` of DELOS for Android): read when the
/// controller is announced and every ``interval`` after, sent only when the state or the level changed since the last
/// report.
public struct BatteryReport: Sendable, Equatable {
    /// How often the battery is read again (Android's `BATTERY_RECHECK_INTERVAL_MS`).
    public static let interval = Duration.seconds(120)

    public var state: BatteryState
    /// 0…100, or ``BatteryState/unknownPercentage``.
    public var percentage: UInt8

    public init(state: BatteryState, percentage: UInt8) {
        self.state = state
        self.percentage = percentage
    }

    /// GameController's reading: the state as Android maps `BatteryState.STATUS_*`, the level 0…1 as a whole percentage
    /// (cut, as Android's cast does); a level that is not a number is unknown.
    public init(state: GCDeviceBattery.State, level: Float) {
        switch state {
        case .charging: self.state = .charging
        case .discharging: self.state = .discharging
        case .full: self.state = .full
        case .unknown: self.state = .unknown
        @unknown default: self.state = .unknown
        }
        percentage = level.isFinite ? UInt8(min(max(level, 0), 1) * 100) : BatteryState.unknownPercentage
    }
}
