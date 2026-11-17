import DelosMedia
import Foundation

/// The settings one app overrides in a profile (`GameSettingsStore` of DELOS for Android, docs/PER_APP_SETTINGS.md): the
/// stream settings that exist here. A setting that is nil follows the profile; one that is set is custom for the app,
/// even when it equals the profile's value. The profile's own settings are never written.
public struct GameSettingsOverride: Codable, Equatable, Sendable {
    /// What the app asks for as its resolution: the display's own, or a fixed one.
    public enum Resolution: Codable, Equatable, Sendable {
        case automatic
        case fixed(StreamResolution)
    }

    /// The overridable settings, in the order of the screen (Android's keys).
    public enum Key: String, CaseIterable, Sendable {
        case resolution = "list_resolution"
        case frameRate = "list_fps"
        case bitrate = "seekbar_bitrate_kbps"
        case codec = "video_format"
        case framePacing = "frame_pacing"
        case hostAudio = "checkbox_host_audio"
    }

    public var resolution: Resolution?
    public var fps: Int?
    public var bitrateKbps: Int?
    public var codec: VideoCodec?
    public var framePacing: FramePacing?
    public var playAudioOnHost: Bool?

    public init() {}

    /// The keys this app overrides.
    public var keys: Set<Key> {
        var keys: Set<Key> = []
        if resolution != nil { keys.insert(.resolution) }
        if fps != nil { keys.insert(.frameRate) }
        if bitrateKbps != nil { keys.insert(.bitrate) }
        if codec != nil { keys.insert(.codec) }
        if framePacing != nil { keys.insert(.framePacing) }
        if playAudioOnHost != nil { keys.insert(.hostAudio) }
        return keys
    }

    public var isEmpty: Bool { keys.isEmpty }

    /// How many settings are custom for this app.
    public var count: Int { keys.count }

    /// [profile] with this app's settings laid over it: what a stream of the app uses.
    public func merged(onto profile: StreamSettings) -> StreamSettings {
        var settings = profile
        switch resolution {
        case .automatic?: settings.resolution = nil
        case .fixed(let value)?: settings.resolution = value
        case nil: break
        }
        if let fps { settings.fps = fps }
        if let bitrateKbps { settings.bitrateKbps = bitrateKbps }
        if let codec { settings.codec = codec }
        if let framePacing { settings.framePacing = framePacing }
        if let playAudioOnHost { settings.playAudioOnHost = playAudioOnHost }
        return settings
    }

    /// Makes every setting of [after] that differs from [before] custom for this app: what one edit of the app's rows
    /// changed (an unchanged one is not an override).
    public mutating func record(from before: StreamSettings, to after: StreamSettings) {
        if after.resolution != before.resolution { resolution = after.resolution.map(Resolution.fixed) ?? .automatic }
        if after.fps != before.fps { fps = after.fps }
        if after.bitrateKbps != before.bitrateKbps { bitrateKbps = after.bitrateKbps }
        if after.codec != before.codec { codec = after.codec }
        if after.framePacing != before.framePacing { framePacing = after.framePacing }
        if after.playAudioOnHost != before.playAudioOnHost { playAudioOnHost = after.playAudioOnHost }
    }

    /// The setting follows the profile again.
    public mutating func reset(_ key: Key) {
        switch key {
        case .resolution: resolution = nil
        case .frameRate: fps = nil
        case .bitrate: bitrateKbps = nil
        case .codec: codec = nil
        case .framePacing: framePacing = nil
        case .hostAudio: playAudioOnHost = nil
        }
    }

    /// The Undo of a reset (`restoreMissing`): puts back what [backup] had and this no longer has, and keeps anything
    /// set since.
    public mutating func restoreMissing(from backup: GameSettingsOverride) {
        if resolution == nil { resolution = backup.resolution }
        if fps == nil { fps = backup.fps }
        if bitrateKbps == nil { bitrateKbps = backup.bitrateKbps }
        if codec == nil { codec = backup.codec }
        if framePacing == nil { framePacing = backup.framePacing }
        if playAudioOnHost == nil { playAudioOnHost = backup.playAudioOnHost }
    }

    /// Reads leniently: a value written by another version that this one cannot read follows the profile.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        let stored: Resolution? = value(.resolution)
        if case .fixed(let size)? = stored, !size.isValid { resolution = nil } else { resolution = stored }
        // Numbers are clamped to their ranges like the profile's
        var clamped = StreamSettings()
        let storedFPS: Int? = value(.fps)
        let storedBitrate: Int? = value(.bitrateKbps)
        if let storedFPS { clamped.fps = storedFPS }
        if let storedBitrate { clamped.bitrateKbps = storedBitrate }
        fps = storedFPS == nil ? nil : clamped.fps
        bitrateKbps = storedBitrate == nil ? nil : clamped.bitrateKbps
        codec = value(.codec)
        framePacing = value(.framePacing)
        playAudioOnHost = value(.playAudioOnHost)
    }
}

/// Stores the ``GameSettingsOverride`` of each app, per profile and per PC (`ui_game_<PC>_<app>_<key>` in the profile's
/// preferences on Android): sparse, so an app that overrides nothing has no entry. PC and app id are its identity;
/// titles do not matter.
public struct GameSettingsStore: Sendable {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private static let prefix = "gamesettings."

    private func key(_ profile: String, _ hostID: String, _ appID: Int) -> String { "\(Self.prefix)\(profile).\(hostID).\(appID)" }

    /// What the app overrides in the profile; nothing when it has no entry.
    public func load(profile: String, hostID: String, appID: Int) -> GameSettingsOverride {
        guard let data = defaults.data(forKey: key(profile, hostID, appID)),
              let stored = try? JSONDecoder().decode(GameSettingsOverride.self, from: data) else { return GameSettingsOverride() }
        return stored
    }

    public func save(_ settings: GameSettingsOverride, profile: String, hostID: String, appID: Int) {
        let name = key(profile, hostID, appID)
        guard !settings.isEmpty, let data = try? JSONEncoder().encode(settings) else {
            defaults.removeObject(forKey: name)
            return
        }
        defaults.set(data, forKey: name)
    }

    /// The apps of the PC the profile overrides something for (the library's "custom" pill).
    public func customApps(profile: String, hostID: String) -> Set<Int> {
        let start = "\(Self.prefix)\(profile).\(hostID)."
        return Set(defaults.dictionaryRepresentation().keys.compactMap { name in
            name.hasPrefix(start) ? Int(name.dropFirst(start.count)) : nil
        })
    }

    /// A new profile starts with a copy of the current one's overrides, like its other settings.
    public func copy(from source: String, to target: String) {
        let start = "\(Self.prefix)\(source)."
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(start) {
            if let data = defaults.data(forKey: name) { defaults.set(data, forKey: "\(Self.prefix)\(target).\(name.dropFirst(start.count))") }
        }
    }

    /// Forgets a removed profile's overrides.
    public func remove(profile: String) {
        removeAll { $0.first.map { String($0) } == profile }
    }

    /// Forgets the overrides of a PC that was removed, for every profile.
    public func remove(hostID: String) {
        removeAll { $0.count > 1 && String($0[1]) == hostID }
    }

    /// Removes the entries whose "profile.host.app" parts satisfy [matches].
    private func removeAll(where matches: ([Substring]) -> Bool) {
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(Self.prefix) {
            if matches(name.dropFirst(Self.prefix.count).split(separator: ".", omittingEmptySubsequences: false)) { defaults.removeObject(forKey: name) }
        }
    }
}
