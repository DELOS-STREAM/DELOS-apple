import DelosMedia
import Foundation

/// The settings one app overrides in a profile (`GameSettingsStore` of DELOS for Android, docs/PER_APP_SETTINGS.md): its
/// `STREAM_KEYS` and `DISPLAY_KEYS`. A setting that is not set follows the profile; one that is set is custom for the
/// app, even when it equals the profile's value. The profile's own settings are never written. Each codec also keeps the
/// app's own bitrate (the codec bitrate slots), which never reach a stream.
public struct GameSettingsOverride: Codable, Equatable, Sendable {
    /// What the app asks for as its resolution: the display's own, or a fixed one.
    public enum Resolution: Codable, Equatable, Sendable {
        case automatic
        case fixed(StreamResolution)
    }

    /// The overridable settings, in the order of the screen (Android's keys): the Stream tab, then the Display tab.
    public enum Key: String, CaseIterable, Sendable {
        case resolution = "list_resolution"
        case frameRate = "list_fps"
        case bitrate = "seekbar_bitrate_kbps"
        case codec = "video_format"
        case framePacing = "frame_pacing"
        case asyncDecode = "checkbox_async_decode"
        case gamepadMotionSensors = "checkbox_gamepad_motion_sensors"
        case gamepadMotionFallback = "checkbox_gamepad_motion_fallback"
        case forceDeviceMotion = "checkbox_force_device_motion"
        case gyroSmoothing = "seekbar_gyro_smoothing"
        /// Playing the app's audio on the PC as well (an override Android's list does not have).
        case hostAudio = "checkbox_host_audio"
        case hdr = "checkbox_enable_hdr"
        case fullRange = "checkbox_full_range"
        case videoScaleMode = "list_video_scale_mode"
        case vrr = "list_vrr"
        case resolutionScaleFactor = "seekbar_resolution_scale_factor"
        case useVirtualDisplay = "checkbox_use_virtual_display"
        case enforceDisplayMode = "checkbox_enforce_display_mode"
        case upscaler = "checkbox_sgsr"
        case upscalerMode = "list_sgsr_quality"
        case upscalerSharpness = "seekbar_sgsr_sharpness"
        case upscalerSupersampling = "list_sgsr_supersampling_level"

        /// The keys of the Display tab (`DISPLAY_KEYS`); the others are the Stream tab's.
        public static let display: [Key] = [
            .hdr, .fullRange, .videoScaleMode, .vrr, .resolutionScaleFactor, .useVirtualDisplay, .enforceDisplayMode,
            .upscaler, .upscalerMode, .upscalerSharpness, .upscalerSupersampling,
        ]

        /// The catalog setting behind the key, nil for the ones with a field of their own.
        public var setting: SettingKey? { SettingKey(rawValue: rawValue) }
    }

    public var resolution: Resolution?
    public var fps: Int?
    /// With ``fps``: the app's frame rate is the custom refresh rate (``StreamSettings/customFrameRateChosen``).
    public var customFrameRateChosen: Bool?
    public var bitrateKbps: Int?
    public var codec: VideoCodec?
    public var hdr: Bool?
    public var framePacing: FramePacing?
    public var playAudioOnHost: Bool?
    /// The catalog settings the app overrides (keys of ``Key`` with a ``Key/setting``).
    public var values: [String: StoredSetting] = [:]
    /// The app's bitrate for each codec (`ui_game_<PC>_<app>_ui_codec_bitrate_<codec>`).
    public var codecBitrates: [String: Int] = [:]

    public init() {}

    /// The keys this app overrides.
    public var keys: Set<Key> {
        var keys: Set<Key> = []
        if resolution != nil { keys.insert(.resolution) }
        if fps != nil { keys.insert(.frameRate) }
        if bitrateKbps != nil { keys.insert(.bitrate) }
        if codec != nil { keys.insert(.codec) }
        if hdr != nil { keys.insert(.hdr) }
        if framePacing != nil { keys.insert(.framePacing) }
        if playAudioOnHost != nil { keys.insert(.hostAudio) }
        for name in values.keys { if let key = Key(rawValue: name) { keys.insert(key) } }
        return keys
    }

    /// Nothing is custom and no codec keeps a bitrate.
    public var isEmpty: Bool { keys.isEmpty && codecBitrates.isEmpty }

    /// How many settings are custom for this app.
    public var count: Int { keys.count }

    /// [profile] with this app's settings laid over it: what a stream of the app uses. The codec bitrates are the app's
    /// own, so a codec change on the App settings screen keeps them.
    public func merged(onto profile: StreamSettings) -> StreamSettings {
        var settings = profile
        switch resolution {
        case .automatic?: settings.resolution = nil
        case .fixed(let value)?: settings.resolution = value
        case nil: break
        }
        if let fps {
            settings.fps = fps
            settings.customFrameRateChosen = customFrameRateChosen ?? false
        }
        if let bitrateKbps { settings.bitrateKbps = bitrateKbps }
        if let codec { settings.codec = codec }
        if let hdr { settings.hdr = hdr }
        if let framePacing { settings.framePacing = framePacing }
        if let playAudioOnHost { settings.playAudioOnHost = playAudioOnHost }
        for (name, value) in values { if let key = SettingKey(rawValue: name) { settings.set(key, value) } }
        settings.codecBitrates = codecBitrates
        return settings
    }

    /// Makes every setting of [after] that differs from [before] custom for this app: what one edit of the app's rows
    /// changed (an unchanged one is not an override). A bitrate that went back to following leaves the profile's.
    public mutating func record(from before: StreamSettings, to after: StreamSettings) {
        if after.resolution != before.resolution { resolution = after.resolution.map(Resolution.fixed) ?? .automatic }
        if after.fps != before.fps || after.customFrameRateChosen != before.customFrameRateChosen {
            fps = after.fps
            customFrameRateChosen = after.customFrameRateChosen
        }
        if after.bitrateKbps != before.bitrateKbps { bitrateKbps = after.bitrateKbps }
        if after.codec != before.codec { codec = after.codec }
        if after.hdr != before.hdr { hdr = after.hdr }
        if after.framePacing != before.framePacing { framePacing = after.framePacing }
        if after.playAudioOnHost != before.playAudioOnHost { playAudioOnHost = after.playAudioOnHost }
        for key in Key.allCases {
            guard let setting = key.setting, after.value(setting) != before.value(setting) else { continue }
            values[key.rawValue] = after.value(setting)
        }
        codecBitrates = after.codecBitrates
    }

    /// The setting follows the profile again; the bitrate also forgets every codec's bitrate.
    public mutating func reset(_ key: Key) {
        switch key {
        case .resolution: resolution = nil
        case .frameRate:
            fps = nil
            customFrameRateChosen = nil
        case .bitrate:
            bitrateKbps = nil
            codecBitrates = [:]
        case .codec: codec = nil
        case .hdr: hdr = nil
        case .framePacing: framePacing = nil
        case .hostAudio: playAudioOnHost = nil
        default: values[key.rawValue] = nil
        }
    }

    /// The Undo of a reset (`restoreMissing`): puts back what [backup] had and this no longer has, and keeps anything
    /// set since.
    public mutating func restoreMissing(from backup: GameSettingsOverride) {
        if resolution == nil { resolution = backup.resolution }
        if fps == nil {
            fps = backup.fps
            customFrameRateChosen = backup.customFrameRateChosen
        }
        if bitrateKbps == nil { bitrateKbps = backup.bitrateKbps }
        if codec == nil { codec = backup.codec }
        if hdr == nil { hdr = backup.hdr }
        if framePacing == nil { framePacing = backup.framePacing }
        if playAudioOnHost == nil { playAudioOnHost = backup.playAudioOnHost }
        values.merge(backup.values) { current, _ in current }
        codecBitrates.merge(backup.codecBitrates) { current, _ in current }
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
        customFrameRateChosen = storedFPS == nil ? nil : value(.customFrameRateChosen)
        bitrateKbps = storedBitrate == nil ? nil : clamped.bitrateKbps
        codec = value(.codec)
        hdr = value(.hdr)
        framePacing = value(.framePacing)
        playAudioOnHost = value(.playAudioOnHost)
        var settings = StreamSettings()
        for (name, setting) in (value(.values) as [String: StoredSetting]?) ?? [:] {
            guard let key = Key(rawValue: name)?.setting else { continue }
            settings.set(key, setting)
        }
        values = settings.values
        codecBitrates = ((value(.codecBitrates) as [String: Int]?) ?? [:]).filter { VideoCodec(rawValue: $0.key) != nil }
            .mapValues { min(max($0, StreamSettings.bitrateRange.lowerBound), StreamSettings.bitrateRange.upperBound) }
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

    /// The apps of the PC the profile overrides something for (the library's "custom" pill); codec bitrates alone do not
    /// count (`countGames` looks at the real keys only).
    public func customApps(profile: String, hostID: String) -> Set<Int> {
        let start = "\(Self.prefix)\(profile).\(hostID)."
        return Set(defaults.dictionaryRepresentation().keys.compactMap { name in
            guard name.hasPrefix(start), let appID = Int(name.dropFirst(start.count)),
                  let data = defaults.data(forKey: name),
                  let stored = try? JSONDecoder().decode(GameSettingsOverride.self, from: data), stored.count > 0 else { return nil }
            return appID
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
