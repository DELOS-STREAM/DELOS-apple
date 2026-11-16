import DelosCore
import DelosHost
import Foundation
import Security

/// What the user chose for a stream (Settings → Stream). Defaults: the device's display resolution capped at 1080p,
/// 60 fps, the bitrate from ``StreamPlan/defaultBitrateKbps(width:height:fps:)``.
public struct StreamSettings: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    /// Nil: the default for the resolution and frame rate.
    public var bitrateKbps: Int?
    public var playAudioOnHost = false
    public var optimizeGameSettings = true

    public init(width: Int, height: Int, fps: Int = 60, bitrateKbps: Int? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }

    /// The resolution of a display of `pixelWidth` × `pixelHeight` (landscape), scaled down to fit in 1920 × 1080 with
    /// even dimensions.
    public static func forDisplay(pixelWidth: Int, pixelHeight: Int) -> StreamSettings {
        let w = max(pixelWidth, pixelHeight), h = min(pixelWidth, pixelHeight)
        let scale = min(1, 1920 / Double(w), 1080 / Double(h))
        return StreamSettings(width: Int(Double(w) * scale) & ~1, height: Int(Double(h) * scale) & ~1)
    }
}

/// The launch request and the stream configuration for one stream: the same remote input key goes into both.
public struct StreamPlan: Sendable {
    public let request: LaunchRequest
    public let configuration: StreamConfiguration

    /// - Parameters:
    ///   - formats: the video formats this device decodes (the host picks one of them).
    ///   - resume: the host already runs this app (resume instead of launch).
    public init(app: HostApp, settings: StreamSettings, formats: VideoFormats, refreshRate: Int, randomBytes: (Int) -> [UInt8] = StreamPlan.secureRandom) {
        let key = randomBytes(RemoteInputKey.length)
        let keyID = randomBytes(4).reduce(Int32(0)) { $0 << 8 | Int32($1) }
        // The IV is the key id, big-endian, followed by zeros (as Moonlight and DELOS for Android send it)
        var iv = [UInt8](repeating: 0, count: RemoteInputKey.length)
        withUnsafeBytes(of: keyID.bigEndian) { for (i, byte) in $0.enumerated() { iv[i] = byte } }
        let audio = AudioConfiguration.stereo
        let bitrate = settings.bitrateKbps ?? Self.defaultBitrateKbps(width: settings.width, height: settings.height, fps: settings.fps)
        request = LaunchRequest(
            appID: app.id, appUUID: app.uuid, width: settings.width, height: settings.height,
            frameRate: Double(settings.fps), resolutionScaleFactor: 100, optimizeGameSettings: settings.optimizeGameSettings,
            remoteInputKey: Data(key), remoteInputKeyID: keyID, hdr: false, virtualDisplay: false,
            playAudioOnHost: settings.playAudioOnHost, surroundAudioInfo: audio.channelMask << 16 | audio.channelCount,
            gamepadMask: 1, persistGamepadsAfterDisconnect: false, coreParameters: CoreInfo.launchQueryParameters)
        configuration = StreamConfiguration(
            width: settings.width, height: settings.height, fps: settings.fps, bitrateKbps: bitrate,
            audio: audio, supportedVideoFormats: formats, clientRefreshRateX100: refreshRate * 100,
            encryption: .audio, remoteInputKey: RemoteInputKey(key: key, iv: iv)!)
    }

    public static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }

    /// The default bitrate of DELOS for Android and Moonlight (`getDefaultBitrate`): a factor from the resolution,
    /// interpolated in a table, times the frame rate over 30 (above 60 fps it grows with the square root).
    public static func defaultBitrateKbps(width: Int, height: Int, fps: Int) -> Int {
        let frameRateFactor = (fps <= 60 ? Double(fps) : (Double(fps) / 60).squareRoot() * 60) / 30
        let pixels: [Double] = [640 * 360, 854 * 480, 1280 * 720, 1920 * 1080, 2560 * 1440, 3840 * 2160]
        let factors: [Double] = [1, 2, 5, 10, 20, 40]
        let p = Double(width * height)
        var resolutionFactor = factors.last!
        for i in pixels.indices where p <= pixels[i] {
            if p == pixels[i] || i == 0 {
                resolutionFactor = factors[i]
            } else {
                resolutionFactor = (p - pixels[i - 1]) / (pixels[i] - pixels[i - 1]) * (factors[i] - factors[i - 1]) + factors[i - 1]
            }
            break
        }
        // Java's Math.round of a float: half up
        return Int((Double(Float(resolutionFactor)) * frameRateFactor + 0.5).rounded(.down)) * 1000
    }

    /// What the core needs to know about the host for the stream.
    public static func serverInformation(_ record: HostRecord, address: HostAddress, sessionURL: String?) -> ServerInformation {
        ServerInformation(
            address: address.host, appVersion: record.appVersion ?? "7.1.431.-1", gfeVersion: record.gfeVersion,
            rtspSessionURL: sessionURL, codecModeSupport: ServerCodecModes(rawValue: Int32(truncatingIfNeeded: record.codecModeSupport)))
    }
}
