import DelosData
import Foundation

/// The stream menu's settings that are kept for the running game as the player sets them (`MenuSavedSetting`,
/// settings/MenuAutoSave.kt:4).
enum MenuSavedSetting: Sendable {
    case upscaler, gyroSmoothing
}

/// Keeps what the stream menu sets as the game's own settings (`MenuAutoSave` of DELOS for Android,
/// settings/MenuAutoSave.kt:6-41): a change only marks the setting, and its live value is written once, ``delay`` after the
/// last change (a slider drag or a held direction writes once, when it settles), or at once by ``flush()`` (the menu closed,
/// the stream ended). Nothing is written without a change, so opening the menu writes nothing, and the profile is never
/// touched: [write] receives the game's overrides only. Time comes from [clock] (seconds) so the logic is testable; the
/// owner calls ``tick()`` once ``nextDelay()`` has passed.
@MainActor
final class MenuAutoSave {
    static let delay: TimeInterval = 0.5

    private let clock: () -> TimeInterval
    private let values: (MenuSavedSetting) -> [SettingKey: StoredSetting]
    private let write: ([SettingKey: StoredSetting]) -> Void
    private var changedAt: [(setting: MenuSavedSetting, at: TimeInterval)] = []

    init(
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        values: @escaping (MenuSavedSetting) -> [SettingKey: StoredSetting],
        write: @escaping ([SettingKey: StoredSetting]) -> Void
    ) {
        self.clock = clock
        self.values = values
        self.write = write
    }

    func changed(_ setting: MenuSavedSetting) {
        changedAt.removeAll { $0.setting == setting }
        changedAt.append((setting, clock()))
    }

    /// Seconds until the first pending setting is due (0 when it already is); nil when nothing is pending.
    func nextDelay() -> TimeInterval? {
        changedAt.map(\.at).min().map { max($0 + Self.delay - clock(), 0) }
    }

    /// Writes the settings whose last change is at least ``delay`` old, in one write.
    func tick() {
        let now = clock()
        writeOnly(changedAt.filter { now - $0.at >= Self.delay }.map(\.setting))
    }

    /// Writes every pending setting now.
    func flush() {
        writeOnly(changedAt.map(\.setting))
    }

    private func writeOnly(_ due: [MenuSavedSetting]) {
        guard !due.isEmpty else { return }
        var merged: [SettingKey: StoredSetting] = [:]
        for setting in due { merged.merge(values(setting)) { _, new in new } }
        changedAt.removeAll { entry in due.contains(entry.setting) }
        write(merged)
    }
}
