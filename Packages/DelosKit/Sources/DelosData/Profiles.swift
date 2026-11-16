import Foundation
import Observation

/// A user profile (`Profile` in DELOS for Android's `shell/data/Profiles.kt`): its identity and the index of its avatar
/// in the avatar set (DelosUI's `Avatar.all`). The set only ever grows at its end, so a stored index never changes its
/// meaning; the interface clamps an index it does not know.
public struct Profile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var avatar: Int

    /// The longest name, in characters (the name field of DELOS for Android takes 20).
    public static let maxNameLength = 20

    public init(id: String, name: String, avatar: Int) {
        self.id = id
        self.name = name
        self.avatar = avatar
    }

    /// Reads a stored profile leniently: an id and a name are required, a missing or unreadable avatar is the first one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        avatar = (try? c.decodeIfPresent(Int.self, forKey: .avatar)) ?? 0
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "empty profile id")
        }
    }

    /// A name as it is stored: without the spaces around it and at most ``maxNameLength`` characters. Nil when nothing
    /// is left: a profile always has a name.
    public static func cleanName(_ name: String) -> String? {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// All profiles in their order and the current one's id.
public struct Profiles: Codable, Equatable, Sendable {
    public var all: [Profile]
    public var currentID: String?

    public init(all: [Profile] = [], currentID: String? = nil) {
        self.all = all
        self.currentID = currentID
    }

    /// The current profile; the first one when the stored id is missing or unknown, nil when there is none.
    public var current: Profile? { all.first { $0.id == currentID } ?? all.first }

    /// Reads stored profiles leniently: an unreadable profile is skipped (and a second profile with an id already read),
    /// the others are kept.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let entries = (try? c.decodeIfPresent([Lenient<Profile>].self, forKey: .all)) ?? []
        var seen = Set<String>()
        all = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }
        currentID = try? c.decodeIfPresent(String.self, forKey: .currentID)
    }
}

/// A value that decodes to nil instead of failing the array it is in.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Keeps the profiles in `UserDefaults` (kept on tvOS, which may purge files), the list and the current id in one
/// value so they never disagree. Each profile's settings are stored by its id (``AppearanceStore``).
///
/// Without a profile DELOS is on its first run: it shows the first-run screens until one is created
/// (`ShellActivity` in DELOS for Android).
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profiles: Profiles
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appearance: AppearanceStore
    private static let key = "profiles"

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        appearance = AppearanceStore(suiteName: suiteName)
        profiles = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Profiles.self, from: $0) } ?? Profiles()
    }

    /// No profile exists: the first run.
    public var isFirstRun: Bool { profiles.all.isEmpty }

    public var current: Profile? { profiles.current }

    /// Adds a profile with a copy of the current one's settings and makes it the current one. Nil when the name is blank
    /// (``Profile/cleanName(_:)``).
    @discardableResult
    public func create(name: String, avatar: Int) -> Profile? {
        guard let name = Profile.cleanName(name) else { return nil }
        let profile = Profile(id: UUID().uuidString.lowercased(), name: name, avatar: max(avatar, 0))
        if let current = profiles.current {
            appearance.save(appearance.load(profile: current.id), profile: profile.id)
        }
        save(Profiles(all: profiles.all + [profile], currentID: profile.id))
        return profile
    }

    /// Changes a profile's name and avatar. False when the name is blank or the profile does not exist.
    @discardableResult
    public func update(_ id: String, name: String, avatar: Int) -> Bool {
        guard let name = Profile.cleanName(name), let index = profiles.all.firstIndex(where: { $0.id == id }) else { return false }
        var next = profiles
        next.all[index].name = name
        next.all[index].avatar = max(avatar, 0)
        save(next)
        return true
    }

    /// Renames a profile, keeping its avatar. False when the name is blank or the profile does not exist.
    @discardableResult
    public func rename(_ id: String, to name: String) -> Bool {
        guard let profile = profiles.all.first(where: { $0.id == id }) else { return false }
        return update(id, name: name, avatar: profile.avatar)
    }

    /// Gives a profile another avatar.
    public func setAvatar(_ id: String, avatar: Int) {
        guard let profile = profiles.all.first(where: { $0.id == id }) else { return }
        update(id, name: profile.name, avatar: avatar)
    }

    public func switchTo(_ id: String) {
        guard id != profiles.current?.id, profiles.all.contains(where: { $0.id == id }) else { return }
        save(Profiles(all: profiles.all, currentID: id))
    }

    /// Removes a profile and its settings without asking. When it was the current one, the next remaining profile takes
    /// over. Returns false when no profile is left (the first run starts again).
    @discardableResult
    public func remove(_ id: String) -> Bool {
        guard profiles.all.contains(where: { $0.id == id }) else { return !profiles.all.isEmpty }
        let wasCurrent = profiles.current?.id == id
        let rest = profiles.all.filter { $0.id != id }
        save(Profiles(all: rest, currentID: wasCurrent ? rest.first?.id : profiles.currentID))
        appearance.remove(profile: id)
        return !rest.isEmpty
    }

    private func save(_ next: Profiles) {
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        profiles = next
    }
}
