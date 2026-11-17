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
/// value so they never disagree. Each profile's settings are stored by its id (``AppearanceStore``,
/// ``StreamSettingsStore``, ``StartupStore``, ``PlaytimeStore``, ``PlayedGames``, ``HiddenGames``, ``GameSettingsStore``).
///
/// Without a profile DELOS is on its first run: it shows the first-run screens until one is created
/// (`ShellActivity` in DELOS for Android).
@MainActor
@Observable
public final class ProfileStore {
    public private(set) var profiles: Profiles
    /// How the current profile starts (its default PC).
    public private(set) var startup = Startup()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let appearance: AppearanceStore
    @ObservationIgnored private let stream: StreamSettingsStore
    @ObservationIgnored private let startups: StartupStore
    @ObservationIgnored private let playtimes: PlaytimeStore
    @ObservationIgnored private let played: PlayedGames
    @ObservationIgnored private let hidden: HiddenGames
    @ObservationIgnored private let gameSettings: GameSettingsStore
    @ObservationIgnored private let specialKeys: CustomSpecialKeys
    @ObservationIgnored private let deleteGrace: Duration
    /// The profiles deleted less than ``deleteGrace`` ago, which Undo can bring back.
    @ObservationIgnored private var deleted: [String: Deleted] = [:]
    /// The pending purge of each deleted profile, cancelled by Undo or by a newer delete of the same id.
    @ObservationIgnored private var purgeTasks: [String: Task<Void, Never>] = [:]
    private static let key = "profiles"
    /// The ids of deleted profiles whose settings are still kept: when DELOS ends before the grace is over, the next
    /// start removes them.
    private static let deletedKey = "profiles.deleted"

    /// A deleted profile and where it was: its place in the list, whether it was the current one and which profile took
    /// over.
    private struct Deleted {
        let profile: Profile
        let index: Int
        let wasCurrent: Bool
        let successor: String?
        let token: UUID
    }

    /// - Parameters:
    ///   - suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    ///   - deleteGrace: how long a deleted profile's settings are kept for Undo (`DELETE_GRACE_MS` of DELOS for
    ///     Android).
    public init(suiteName: String? = nil, deleteGrace: Duration = .seconds(10)) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        appearance = AppearanceStore(suiteName: suiteName)
        stream = StreamSettingsStore(suiteName: suiteName)
        startups = StartupStore(suiteName: suiteName)
        playtimes = PlaytimeStore(suiteName: suiteName)
        played = PlayedGames(suiteName: suiteName)
        hidden = HiddenGames(suiteName: suiteName)
        gameSettings = GameSettingsStore(suiteName: suiteName)
        specialKeys = CustomSpecialKeys(suiteName: suiteName)
        self.deleteGrace = deleteGrace
        let stored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Profiles.self, from: $0) } ?? Profiles()
        profiles = stored
        startup = stored.current.map { startups.load(profile: $0.id) } ?? Startup()
        for id in defaults.stringArray(forKey: Self.deletedKey) ?? [] where !stored.all.contains(where: { $0.id == id }) {
            removeSettings(id)
        }
        defaults.removeObject(forKey: Self.deletedKey)
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
            stream.save(stream.load(profile: current.id), profile: profile.id)
            gameSettings.copy(from: current.id, to: profile.id)
            startups.save(startups.load(profile: current.id), profile: profile.id)
            specialKeys.copy(from: current.id, to: profile.id)
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

    /// Makes [hostID] the current profile's default PC; nil: none, which also turns "Skip the start screen" off.
    public func setDefaultPC(_ hostID: String?) {
        guard let current = profiles.current else { return }
        var next = startup
        next.defaultPC = hostID
        startups.save(next, profile: current.id)
        startup = next
    }

    /// Turns "Skip the start screen" on or off for the current profile; it stays off without a default PC.
    public func setSkipStart(_ on: Bool) {
        guard let current = profiles.current else { return }
        let next = Startup(defaultPC: startup.defaultPC, skipStart: on)
        startups.save(next, profile: current.id)
        startup = next
    }

    /// Deletes a profile without asking (`ProfileStore.delete` of DELOS for Android): it disappears at once, and when it
    /// was the current one the first remaining profile takes over. Its settings are kept for the delete grace, so
    /// ``undoDelete(_:)`` can bring it back; then, or at the next start if DELOS ended meanwhile, they are removed.
    /// Returns false when no profile is left (the first run starts again).
    @discardableResult
    public func delete(_ id: String) -> Bool {
        guard let index = profiles.all.firstIndex(where: { $0.id == id }) else { return !profiles.all.isEmpty }
        let wasCurrent = profiles.current?.id == id
        var rest = profiles.all
        let profile = rest.remove(at: index)
        let token = UUID()
        deleted[id] = Deleted(profile: profile, index: index, wasCurrent: wasCurrent, successor: rest.first?.id, token: token)
        defaults.set(Array(deleted.keys), forKey: Self.deletedKey)
        save(Profiles(all: rest, currentID: wasCurrent ? rest.first?.id : profiles.currentID))
        let grace = deleteGrace
        purgeTasks[id]?.cancel()
        purgeTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            self?.purge(id, token: token)
        }
        return !rest.isEmpty
    }

    /// Brings back a profile deleted less than the delete grace ago, at its old place with all its settings. It is the
    /// current one again when it was and nobody has chosen another profile since. False when it is gone for good.
    @discardableResult
    public func undoDelete(_ id: String) -> Bool {
        guard let gone = deleted.removeValue(forKey: id) else { return false }
        purgeTasks.removeValue(forKey: id)?.cancel()
        defaults.set(Array(deleted.keys), forKey: Self.deletedKey)
        let takesOver = gone.wasCurrent && profiles.current?.id == gone.successor
        var all = profiles.all
        all.insert(gone.profile, at: min(gone.index, all.count))
        save(Profiles(all: all, currentID: takesOver ? id : profiles.currentID))
        return true
    }

    /// The grace of a deleted profile is over: its settings are removed for good.
    /// A timer of an earlier delete of the same id (deleted, undone, deleted again) finds another [token] and does nothing.
    func purge(_ id: String, token: UUID) {
        guard deleted[id]?.token == token else { return }
        deleted.removeValue(forKey: id)
        purgeTasks.removeValue(forKey: id)
        defaults.set(Array(deleted.keys), forKey: Self.deletedKey)
        removeSettings(id)
    }

    private func removeSettings(_ id: String) {
        appearance.remove(profile: id)
        stream.remove(profile: id)
        startups.remove(profile: id)
        playtimes.remove(profile: id)
        played.remove(profile: id)
        hidden.remove(profile: id)
        gameSettings.remove(profile: id)
        specialKeys.remove(profile: id)
    }

    private func save(_ next: Profiles) {
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        profiles = next
        let startup = next.current.map { startups.load(profile: $0.id) } ?? Startup()
        if startup != self.startup { self.startup = startup }
    }
}
