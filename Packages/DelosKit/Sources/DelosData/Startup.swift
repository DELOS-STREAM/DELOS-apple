import Foundation

/// How DELOS starts for a profile (`Startup` of DELOS for Android): the default PC, which the start screen marks and
/// focuses first, and "Skip the start screen", which connects to it right away.
public struct Startup: Codable, Equatable, Sendable {
    /// The id of the default PC; nil: none. Without one there is nothing to skip to, so ``skipStart`` goes off with it.
    public var defaultPC: String? { didSet { if defaultPC == nil { skipStart = false } } }
    /// Connect straight to the default PC when DELOS starts (`ui_skip_start`).
    public var skipStart = false

    public init(defaultPC: String? = nil, skipStart: Bool = false) {
        self.defaultPC = defaultPC
        self.skipStart = defaultPC != nil && skipStart
    }

    /// Reads leniently: a startup stored before skipping existed has it off.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let pc = try? c.decodeIfPresent(String.self, forKey: .defaultPC)
        self.init(defaultPC: pc, skipStart: (try? c.decodeIfPresent(Bool.self, forKey: .skipStart)) ?? false)
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
