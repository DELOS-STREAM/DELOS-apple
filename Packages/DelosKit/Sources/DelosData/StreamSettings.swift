import DelosCore
import DelosMedia
import Foundation

/// The size of a stream in pixels (`list_resolution` of DELOS for Android, `<width>x<height>`).
public struct StreamResolution: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// The fixed choices of DELOS for Android (`resolution_values`): 360p, 480p, 720p, 1080p, 1440p and 4K.
    public static let presets = [
        StreamResolution(width: 640, height: 360), StreamResolution(width: 854, height: 480),
        StreamResolution(width: 1280, height: 720), StreamResolution(width: 1920, height: 1080),
        StreamResolution(width: 2560, height: 1440), StreamResolution(width: 3840, height: 2160),
    ]

    /// How Android writes it in a label: `2796x1290`.
    public var text: String { "\(width)x\(height)" }

    /// The resolution of a display of `pixelWidth` × `pixelHeight` (landscape), scaled down to fit in 1920 × 1080 with
    /// even dimensions: the stream's resolution while the profile has not chosen one.
    public static func forDisplay(pixelWidth: Int, pixelHeight: Int) -> StreamResolution {
        let w = max(pixelWidth, pixelHeight), h = min(pixelWidth, pixelHeight)
        let scale = min(1, 1920 / Double(w), 1080 / Double(h))
        return StreamResolution(width: Int(Double(w) * scale) & ~1, height: Int(Double(h) * scale) & ~1)
    }

    var isValid: Bool { (1...32768).contains(width) && (1...32768).contains(height) }
}

/// The video codec the profile prefers (`video_format` of DELOS for Android, with its stored values). The host picks
/// one of the formats offered; which ones are offered follows Android's decoder choice.
public enum VideoCodec: String, CaseIterable, Codable, Sendable {
    /// H.264, and HEVC where this device decodes it. AV1 is offered only when chosen.
    case automatic = "auto"
    case av1 = "forceav1"
    case hevc = "forceh265"
    /// H.264 only.
    case h264 = "neverh265"
    /// PyroWave, Vibepollo's wavelet codec, where the host and this device support it; the usual codecs otherwise
    /// (offered only where a PyroWave decoder exists, ``choices(decodable:pyroWave:)``).
    case pyroWave = "pyrowave"

    /// The formats offered to the host, from what this device decodes ([decodable]). A codec this device cannot decode
    /// is never offered, even when chosen (Android warns and streams without it).
    ///
    /// With [hdr] the 10-bit profiles are offered too: HEVC Main10 whenever HEVC is allowed (HDR implies HEVC, as on
    /// Android), AV1 Main 10 when AV1 is chosen. H.264 has no HDR: its choice offers none.
    public func formats(decodable: VideoFormats, hdr: Bool = false) -> VideoFormats {
        var formats: VideoFormats = .h264
        guard self != .h264 else { return formats }
        if decodable.contains(.hevc) { formats.insert(.hevc) }
        if self == .av1, decodable.contains(.av1Main8) { formats.insert(.av1Main8) }
        if hdr {
            if decodable.contains(.hevcMain10) { formats.insert(.hevcMain10) }
            if self == .av1, decodable.contains(.av1Main10) { formats.insert(.av1Main10) }
        }
        return formats
    }

    /// The choices in Android's order (Automatic, AV1, HEVC, H.264, PyroWave), without a codec this device does not
    /// decode; PyroWave only where [pyroWave] (a PyroWave decoder) is there.
    public static func choices(decodable: VideoFormats, pyroWave: Bool = false) -> [VideoCodec] {
        allCases.filter {
            switch $0 {
            case .av1: decodable.contains(.av1Main8)
            case .hevc: decodable.contains(.hevc)
            case .pyroWave: pyroWave
            case .automatic, .h264: true
            }
        }
    }
}

/// The bitrate PyroWave needs for good quality (`PyroWaveBitrate` of DELOS for Android, after Vibepollo's client): the
/// PyroWave author's regression at 35 dB PSNR-HVS-M-H from twice the screen height; HDR10 gets 1.2x. PyroWave is
/// intra-only, so it needs several times HEVC's bitrate: about 220 Mbps for 1080p60.
public enum PyroWaveBitrate {
    private static let coefficients420 = [
        611.9945665176643, 87.22375978784984, -374.2744854882103, 138.525763156332,
        404.3879014230974, -64.04327593791751, -194.8035057145124, -12.904253458542499,
    ]
    private static let coefficients444 = [
        719.659360640365, 51.9223145866537, -522.3229212980714, 104.10383129754959,
        605.6153091742109, 87.26139899802612, -306.13390524230874, -110.39755862218644,
    ]

    /// The recommended bitrate in kbps, rounded up to 5 Mbps and capped at the slider's maximum; 4:4:4 never with HDR
    /// (the HDR bridge is 4:2:0), as `getDefaultBitrate` of DELOS for Android.
    public static func recommendedKbps(width: Int, height: Int, fps: Int, chroma444: Bool, hdr: Bool) -> Int {
        let pixels = min(max(Double(width) * Double(height), 1280 * 720), 3840 * 2160)
        let x = (pixels * 1e-6).squareRoot() - 2
        var power = 1.0, estimate = 0.0
        for coefficient in chroma444 && !hdr ? coefficients444 : coefficients420 {
            estimate += power * coefficient
            power *= x
        }
        let mbits = estimate * 8e-3 * Double(max(fps, 1)) * (hdr ? 1.2 : 1)
        return min(Int((mbits * 1000 / 5000).rounded(.up)) * 5000, StreamSettings.bitrateRange.upperBound)
    }
}

/// What a profile chose in Settings → Stream and Settings → Audio for its streams.
public struct StreamSettings: Codable, Equatable, Sendable {
    /// Nil: the display's resolution capped at 1080p (``StreamResolution/forDisplay(pixelWidth:pixelHeight:)``).
    public var resolution: StreamResolution?
    /// Frames per second, 60 by default as on Android.
    public var fps = 60 { didSet { fps = Self.clampFPS(fps) } }
    /// Nil: ``StreamPlan/defaultBitrateKbps(width:height:fps:)`` for the resolution and frame rate, so it follows them.
    public var bitrateKbps: Int? { didSet { bitrateKbps = bitrateKbps.map(Self.clampBitrate) } }
    public var codec = VideoCodec.automatic
    /// Asks the host for HDR video (`checkbox_enable_hdr`); it takes effect where the device decodes and shows HDR.
    public var hdr = false
    /// Plays the app's audio on the PC as well (`checkbox_host_audio`).
    public var playAudioOnHost = false
    /// How frames are timed on screen. Balanced by default, unlike Android's lowest latency: on iPad the display layer
    /// showed the network's jitter as uneven motion (owner, iPad Pro M5, 120 fps, 2026-11-16).
    public var framePacing = FramePacing.balanced
    /// The statistics overlay the stream menu's Overlay tile last chose (Android keeps it in the profile as well); every
    /// stream of the profile starts with it. Settings → Display shows it as Android's two switches,
    /// `checkbox_enable_perf_overlay` (shown) and `checkbox_enable_perf_overlay_lite` (compact).
    public var statisticsOverlay = StatisticsOverlay.off
    /// Every other setting of the catalog the profile changed, by Android's key (``SettingKey``); a key that is not here
    /// has its default. Read with ``bool(_:)``, ``int(_:)`` and ``text(_:)``.
    public var values: [String: StoredSetting] = [:]
    /// The bitrate each codec last had (`ui_codec_bitrate_<codec>` of DELOS for Android): kept when the codec changes
    /// away and restored when it comes back. Never part of what a stream reads.
    public var codecBitrates: [String: Int] = [:]

    /// The bitrate slider of Android (`seekbar_bitrate_kbps`): 1 to 1000 Mbps in steps of 1 Mbps.
    public static let bitrateRange = 1000...1_000_000
    public static let bitrateStep = 1000

    public init(resolution: StreamResolution? = nil, fps: Int = 60, bitrateKbps: Int? = nil) {
        self.resolution = resolution
        self.fps = Self.clampFPS(fps)
        self.bitrateKbps = bitrateKbps.map(Self.clampBitrate)
    }

    // MARK: Catalog values

    /// The stored value of [key], else its default.
    public func value(_ key: SettingKey) -> StoredSetting { values[key.rawValue] ?? key.defaultValue }

    public func bool(_ key: SettingKey) -> Bool { value(key).bool ?? key.defaultValue.bool ?? false }

    public func int(_ key: SettingKey) -> Int { value(key).int ?? key.defaultValue.int ?? 0 }

    public func text(_ key: SettingKey) -> String { value(key).text ?? key.defaultValue.text ?? "" }

    /// Whether the profile has a value of its own for [key] (Android's `contains`): a custom resolution or refresh rate
    /// is offered as a choice only once it was typed.
    public func isSet(_ key: SettingKey) -> Bool { values[key.rawValue] != nil }

    /// Stores [value] for [key] when the key accepts it (type, range, choices); a slider's value is clamped first.
    public mutating func set(_ key: SettingKey, _ value: StoredSetting) {
        var value = value
        if case .int(let v) = value, let range = key.range { value = .int(min(max(v, range.lowerBound), range.upperBound)) }
        guard key.accepts(value) else { return }
        values[key.rawValue] = value
    }

    // MARK: Codec bitrates

    /// The bitrate PyroWave recommends for these settings (`pyroWaveRecommendedBitrateKbps`), nil when the codec is not
    /// PyroWave. [displayResolution] stands in while the resolution follows the display.
    public func pyroWaveRecommendedKbps(displayResolution: StreamResolution) -> Int? {
        guard codec == .pyroWave else { return nil }
        let r = resolution ?? displayResolution
        return PyroWaveBitrate.recommendedKbps(width: r.width, height: r.height, fps: fps, chroma444: text(.pyrowaveChroma) == "444", hdr: hdr)
    }

    /// Changes the codec as Android's settings store does (docs/PER_APP_SETTINGS.md "Inheritance and codec bitrates"):
    /// the bitrate in use is kept for the codec left (only when the bitrate is chosen, [ownsBitrate]), a codec that has
    /// a kept bitrate gets it back, a first PyroWave gets its recommended bitrate, and leaving PyroWave for a codec with
    /// none kept lets the bitrate follow the default (or the profile) again.
    public mutating func changeCodec(to next: VideoCodec, displayResolution: StreamResolution, ownsBitrate: Bool? = nil) {
        let before = codec
        guard next != before else { return }
        if let kbps = bitrateKbps, ownsBitrate ?? true { codecBitrates[before.rawValue] = kbps }
        codec = next
        if let kept = codecBitrates[next.rawValue] {
            bitrateKbps = kept
        } else if next == .pyroWave {
            bitrateKbps = pyroWaveRecommendedKbps(displayResolution: displayResolution)
        } else if before == .pyroWave {
            bitrateKbps = nil
        }
    }

    /// With PyroWave, a change of resolution, frame rate, HDR or chroma recalculates its recommended bitrate.
    public mutating func followPyroWave(displayResolution: StreamResolution) {
        if let kbps = pyroWaveRecommendedKbps(displayResolution: displayResolution) { bitrateKbps = kbps }
    }

    /// The bitrate in kbps on a metered network (`seekbar_metered_bitrate_kbps`): the chosen one, or a quarter of
    /// [normal] when it is 0, as the row's help says.
    public func meteredBitrate(normal: Int) -> Int {
        let chosen = int(.meteredBitrate)
        return chosen > 0 ? chosen : max(Self.bitrateRange.lowerBound, normal / 4)
    }

    /// The resolution the stream asks for on a display of `pixelWidth` × `pixelHeight`.
    public func resolution(displayWidth: Int, displayHeight: Int) -> StreamResolution {
        resolution ?? .forDisplay(pixelWidth: displayWidth, pixelHeight: displayHeight)
    }

    /// The bitrate the stream asks for at [resolution]: the chosen one, else the default.
    public func bitrate(at resolution: StreamResolution) -> Int {
        bitrateKbps ?? StreamPlan.defaultBitrateKbps(width: resolution.width, height: resolution.height, fps: fps)
    }

    /// StreamDisplayPlanner.java:288–315: cap only near refresh; Warp is actual host-side oversampling.
    public func streamFPS(refreshRate: Int) -> Int {
        switch framePacing {
        case .warp: fps * 2
        case .warp2: fps * 4
        case .capFPS:
            refreshRate > 49 && fps >= refreshRate && fps - refreshRate <= 3 ? refreshRate - 1 : fps
        case .latency, .balanced, .smoothness, .fastVSync: fps
        }
    }

    private static func clampFPS(_ fps: Int) -> Int { min(max(fps, 1), 1000) }

    private static func clampBitrate(_ kbps: Int) -> Int { min(max(kbps, bitrateRange.lowerBound), bitrateRange.upperBound) }

    /// Reads stored settings leniently: a missing or unknown value (a codec removed in a later version) falls back to
    /// its default instead of discarding all settings, and numbers are clamped to their ranges.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback }
        resolution = value(.resolution, d.resolution).flatMap { $0.isValid ? $0 : nil }
        fps = Self.clampFPS(value(.fps, d.fps))
        bitrateKbps = value(.bitrateKbps, d.bitrateKbps).map(Self.clampBitrate)
        codec = value(.codec, d.codec)
        hdr = value(.hdr, d.hdr)
        playAudioOnHost = value(.playAudioOnHost, d.playAudioOnHost)
        framePacing = value(.framePacing, d.framePacing)
        statisticsOverlay = value(.statisticsOverlay, d.statisticsOverlay)
        // A key or a value this version does not know is dropped, the others are kept
        var stored = StreamSettings()
        for (name, setting) in value(.values, [String: StoredSetting]()) {
            if let key = SettingKey(rawValue: name) { stored.set(key, setting) }
        }
        values = stored.values
        codecBitrates = value(.codecBitrates, [String: Int]()).filter { VideoCodec(rawValue: $0.key) != nil }
            .mapValues(Self.clampBitrate)
    }
}

/// The choices Settings → Stream offers on this device (`SettingsCapabilities.choices` of DELOS for Android).
public enum StreamChoices {
    /// A resolution in the list: one of the presets, the display's own, or the one typed as the custom resolution.
    public enum Resolution: Hashable, Sendable {
        case preset(StreamResolution)
        /// The display's resolution (`settings_resolution_native`); [portrait] on a squarish display; [fullscreen] the
        /// whole panel of a display whose safe area is smaller (`settings_resolution_native_fullscreen`).
        case native(StreamResolution, portrait: Bool, fullscreen: Bool = false)
        /// `edit_diy_w_h` once it was typed (`settings_resolution_custom`).
        case custom(StreamResolution)

        public var resolution: StreamResolution {
            switch self {
            case .preset(let r), .native(let r, _, _), .custom(let r): r
            }
        }
    }

    /// A frame rate in the list: one of 30, 60, 90 and 120, the display's highest refresh rate when it is none of them,
    /// or the custom refresh rate once it was typed.
    public enum FrameRate: Hashable, Sendable {
        case preset(Int)
        case native(Int)
        /// `custom_refresh_rate` (as typed, "59.94"), streamed at its nearest whole rate.
        case custom(Int, text: String)

        public var fps: Int {
            switch self {
            case .preset(let fps), .native(let fps), .custom(let fps, _): fps
            }
        }
    }

    public static let presetFrameRates = [30, 60, 90, 120]

    /// The custom resolution of [settings] when it was typed and reads `<width>x<height>` (Android's
    /// `[1-9][0-9]*x[1-9][0-9]*`).
    public static func customResolution(_ settings: StreamSettings) -> StreamResolution? {
        guard settings.isSet(.customResolution) else { return nil }
        let parts = settings.text(.customResolution).split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), !parts[0].hasPrefix("0"), !parts[1].hasPrefix("0"),
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let r = StreamResolution(width: w, height: h)
        return r.isValid ? r : nil
    }

    /// The custom refresh rate of [settings] when it was typed and is a positive number: its text and nearest whole rate.
    public static func customFrameRate(_ settings: StreamSettings) -> FrameRate? {
        guard settings.isSet(.customRefreshRate), let value = Double(settings.text(.customRefreshRate)),
              value.isFinite, value > 0 else { return nil }
        return .custom(min(max(Int(value.rounded()), 1), 1000), text: settings.text(.customRefreshRate))
    }

    /// Every preset (VideoToolbox decodes 4K on every device of the minimum systems, which lifts Android's display-based
    /// cap of the presets to 3840), then the display's resolution in landscape; on a squarish display (aspect below 1.3)
    /// its portrait one first. Where the safe area ([safeWidth] × [safeHeight]) is smaller than the panel, the safe
    /// area's resolution comes first and the whole panel's is the fullscreen one, as Android does for a display cutout.
    /// Then the [custom] resolution. A value the list has already is not repeated.
    public static func resolutions(
        displayWidth: Int, displayHeight: Int, safeWidth: Int? = nil, safeHeight: Int? = nil, custom: StreamResolution? = nil
    ) -> [Resolution] {
        var list = StreamResolution.presets.map(Resolution.preset)
        func add(_ width: Int, _ height: Int, fullscreen: Bool) {
            let w = max(width, height), h = min(width, height)
            guard w > 0, h > 0 else { return }
            if Double(w) / Double(h) < 1.3 {
                list.append(.native(StreamResolution(width: h, height: w), portrait: true, fullscreen: fullscreen))
            }
            list.append(.native(StreamResolution(width: w, height: h), portrait: false, fullscreen: fullscreen))
        }
        let cutout = safeWidth.map { $0 > 0 } == true && safeHeight.map { $0 > 0 } == true
            && (safeWidth != displayWidth || safeHeight != displayHeight)
        if cutout, let safeWidth, let safeHeight { add(safeWidth & ~1, safeHeight & ~1, fullscreen: false) }
        add(displayWidth, displayHeight, fullscreen: cutout)
        if let custom { list.append(.custom(custom)) }
        return unique(list, by: \.resolution)
    }

    /// The presets up to the display's highest refresh rate (at least 60, with 2 Hz to spare; every preset when
    /// [unlocked], `checkbox_unlock_fps`), then that rate when the presets do not have it, then the [custom] rate.
    public static func frameRates(maxFramesPerSecond: Int, unlocked: Bool = false, custom: FrameRate? = nil) -> [FrameRate] {
        let limit = max(60, maxFramesPerSecond + 2)
        let list = presetFrameRates.filter { unlocked || $0 <= limit }.map(FrameRate.preset) + [.native(maxFramesPerSecond)]
            + (custom.map { [$0] } ?? [])
        return unique(list.filter { $0.fps > 0 }, by: \.fps)
    }

    private static func unique<T, K: Hashable>(_ list: [T], by key: (T) -> K) -> [T] {
        var seen = Set<K>()
        return list.filter { seen.insert(key($0)).inserted }
    }

    /// The settings with every chosen value the device does not offer replaced (`StreamSettingsStore.normalize` of
    /// DELOS for Android): a resolution by the last preset, a frame rate by 60, a codec by Automatic.
    public static func normalized(
        _ settings: StreamSettings, displayWidth: Int, displayHeight: Int, maxFramesPerSecond: Int, decodable: VideoFormats,
        safeWidth: Int? = nil, safeHeight: Int? = nil, pyroWave: Bool = false
    ) -> StreamSettings {
        var next = settings
        if let chosen = settings.resolution {
            let list = resolutions(
                displayWidth: displayWidth, displayHeight: displayHeight, safeWidth: safeWidth, safeHeight: safeHeight,
                custom: customResolution(settings))
            if !list.contains(where: { $0.resolution == chosen }) { next.resolution = StreamResolution.presets.last }
        }
        let rates = frameRates(
            maxFramesPerSecond: maxFramesPerSecond, unlocked: settings.bool(.unlockFps), custom: customFrameRate(settings))
        if !rates.contains(where: { $0.fps == settings.fps }) { next.fps = rates.first { $0.fps == 60 }?.fps ?? rates[0].fps }
        if !VideoCodec.choices(decodable: decodable, pyroWave: pyroWave).contains(settings.codec) { next.codec = .automatic }
        return next
    }
}

/// Stores the ``StreamSettings`` of each profile in `UserDefaults`, next to its ``Appearance``.
public struct StreamSettingsStore: Sendable {
    private let suiteName: String?

    /// - Parameter suiteName: a `UserDefaults` suite; nil is the app's standard defaults.
    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String) -> String { "stream.\(profile)" }

    /// The profile's settings; the defaults when it has none.
    public func load(profile: String) -> StreamSettings {
        guard let data = defaults.data(forKey: key(profile)),
              let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) else { return StreamSettings() }
        return settings
    }

    public func save(_ settings: StreamSettings, profile: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(profile))
    }

    /// Forgets a removed profile's settings.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }
}
