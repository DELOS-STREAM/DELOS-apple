import Foundation

/// How DELOS starts for a profile (`Startup` of DELOS for Android): the default PC, which the start screen marks and
/// focuses first. Android's "Skip the start screen" is not ported yet.
public struct Startup: Codable, Equatable, Sendable {
    /// The id of the default PC; nil: none.
    public var defaultPC: String?

    public init(defaultPC: String? = nil) {
        self.defaultPC = defaultPC
    }
}

/// Keeps one ``Startup`` per profile in `UserDefaults` (key `startup.<profile id>`, Android's `ui_default_pc` in the
/// profile's settings).
public struct StartupStore: Sendable {
    private let suiteName: String?

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String) -> String { "startup.\(profile)" }

    public func load(profile: String) -> Startup {
        guard let data = defaults.data(forKey: key(profile)),
              let startup = try? JSONDecoder().decode(Startup.self, from: data) else { return Startup() }
        return startup
    }

    public func save(_ startup: Startup, profile: String) {
        guard let data = try? JSONEncoder().encode(startup) else { return }
        defaults.set(data, forKey: key(profile))
    }

    /// Forgets a deleted profile's startup.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }
}
