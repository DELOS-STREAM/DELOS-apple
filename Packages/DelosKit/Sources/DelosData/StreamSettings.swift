import DelosCore
import DelosInput
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

    /// The choices in Android's order (Automatic, AV1, HEVC, H.264), without a codec this device does not decode.
    public static func choices(decodable: VideoFormats) -> [VideoCodec] {
        allCases.filter {
            switch $0 {
            case .av1: decodable.contains(.av1Main8)
            case .hevc: decodable.contains(.hevc)
            case .automatic, .h264: true
            }
        }
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
    /// stream of the profile starts with it.
    public var statisticsOverlay = StatisticsOverlay.off
    public var rumble = RumbleConfiguration()

    /// The bitrate slider of Android (`seekbar_bitrate_kbps`): 1 to 1000 Mbps in steps of 1 Mbps.
    public static let bitrateRange = 1000...1_000_000
    public static let bitrateStep = 1000

    public init(resolution: StreamResolution? = nil, fps: Int = 60, bitrateKbps: Int? = nil) {
        self.resolution = resolution
        self.fps = Self.clampFPS(fps)
        self.bitrateKbps = bitrateKbps.map(Self.clampBitrate)
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
        case .latency, .balanced, .smoothness: fps
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
        rumble = value(.rumble, d.rumble)
    }
}

/// The choices Settings → Stream offers on this device (`SettingsCapabilities.choices` of DELOS for Android).
public enum StreamChoices {
    /// A resolution in the list: one of the presets, or the display's own.
    public enum Resolution: Hashable, Sendable {
        case preset(StreamResolution)
        /// The display's resolution (`settings_resolution_native`); [portrait] on a squarish display.
        case native(StreamResolution, portrait: Bool)

        public var resolution: StreamResolution {
            switch self {
            case .preset(let r), .native(let r, _): r
            }
        }
    }

    /// A frame rate in the list: one of 30, 60, 90 and 120, or the display's highest refresh rate when it is none of them.
    public enum FrameRate: Hashable, Sendable {
        case preset(Int)
        case native(Int)

        public var fps: Int {
            switch self {
            case .preset(let fps), .native(let fps): fps
            }
        }
    }

    public static let presetFrameRates = [30, 60, 90, 120]

    /// Every preset (VideoToolbox decodes 4K on every device of the minimum systems, which lifts Android's display-based
    /// cap of the presets to 3840), then the display's resolution in landscape; on a squarish display (aspect below 1.3)
    /// its portrait one first. A value the list has already is not repeated.
    public static func resolutions(displayWidth: Int, displayHeight: Int) -> [Resolution] {
        var list = StreamResolution.presets.map(Resolution.preset)
        let w = max(displayWidth, displayHeight), h = min(displayWidth, displayHeight)
        if w > 0, h > 0 {
            if Double(w) / Double(h) < 1.3 { list.append(.native(StreamResolution(width: h, height: w), portrait: true)) }
            list.append(.native(StreamResolution(width: w, height: h), portrait: false))
        }
        return unique(list, by: \.resolution)
    }

    /// The presets up to the display's highest refresh rate (at least 60, with 2 Hz to spare), then that rate when the
    /// presets do not have it.
    public static func frameRates(maxFramesPerSecond: Int) -> [FrameRate] {
        let limit = max(60, maxFramesPerSecond + 2)
        let list = presetFrameRates.filter { $0 <= limit }.map(FrameRate.preset) + [.native(maxFramesPerSecond)]
        return unique(list.filter { $0.fps > 0 }, by: \.fps)
    }

    private static func unique<T, K: Hashable>(_ list: [T], by key: (T) -> K) -> [T] {
        var seen = Set<K>()
        return list.filter { seen.insert(key($0)).inserted }
    }

    /// The settings with every chosen value the device does not offer replaced (`StreamSettingsStore.normalize` of
    /// DELOS for Android): a resolution by the last preset, a frame rate by 60, a codec by Automatic.
    public static func normalized(
        _ settings: StreamSettings, displayWidth: Int, displayHeight: Int, maxFramesPerSecond: Int, decodable: VideoFormats
    ) -> StreamSettings {
        var next = settings
        if let chosen = settings.resolution {
            let list = resolutions(displayWidth: displayWidth, displayHeight: displayHeight)
            if !list.contains(where: { $0.resolution == chosen }) { next.resolution = StreamResolution.presets.last }
        }
        let rates = frameRates(maxFramesPerSecond: maxFramesPerSecond)
        if !rates.contains(where: { $0.fps == settings.fps }) { next.fps = rates.first { $0.fps == 60 }?.fps ?? rates[0].fps }
        if !VideoCodec.choices(decodable: decodable).contains(settings.codec) { next.codec = .automatic }
        return next
    }
}

/// Stores the ``StreamSettings`` of each profile in `UserDefaults`, next to its ``Appearance``.
public struct StreamSettingsStore: Sendable {
    public static let didSave = Notification.Name("DelosStreamSettingsDidSave")
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
        NotificationCenter.default.post(name: Self.didSave, object: profile)
    }

    /// Forgets a removed profile's settings.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }
}
