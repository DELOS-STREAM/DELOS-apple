import DelosCore
import DelosHost
import Foundation
import Security

/// The launch request and the stream configuration for one stream: the same remote input key goes into both.
public struct StreamPlan: Sendable {
    public let request: LaunchRequest
    public let configuration: StreamConfiguration

    /// - Parameters:
    ///   - display: the display's size in pixels: the resolution while the settings have none.
    ///   - decodable: the video formats this device decodes; the settings' codec chooses which are offered (the host
    ///     picks one of them).
    ///   - displaySupportsHDR: the display shows HDR (`HDRDisplay`); without it a stored `hdr = true` is ignored.
    public init(
        app: HostApp, settings: StreamSettings, display: StreamResolution, decodable: VideoFormats, refreshRate: Int, displaySupportsHDR: Bool,
        randomBytes: (Int) -> [UInt8] = StreamPlan.secureRandom
    ) {
        let key = randomBytes(RemoteInputKey.length)
        let keyID = randomBytes(4).reduce(Int32(0)) { $0 << 8 | Int32($1) }
        // The IV is the key id, big-endian, followed by zeros (as Moonlight and DELOS for Android send it)
        var iv = [UInt8](repeating: 0, count: RemoteInputKey.length)
        withUnsafeBytes(of: keyID.bigEndian) { for (i, byte) in $0.enumerated() { iv[i] = byte } }
        let audio = AudioConfiguration.stereo
        let formats = settings.codec.formats(decodable: decodable, hdr: settings.hdr && displaySupportsHDR)
        // HDR is asked of the host only with a 10-bit format to carry it
        let hdr = !formats.isDisjoint(with: .tenBit)
        let size = settings.resolution(displayWidth: display.width, displayHeight: display.height)
        let fps = settings.streamFPS(refreshRate: refreshRate)
        request = LaunchRequest(
            appID: app.id, appUUID: app.uuid, width: size.width, height: size.height,
            // Optimize game settings is GeForce Experience's; DELOS for Android always sends it off
            frameRate: Double(fps), resolutionScaleFactor: 100, optimizeGameSettings: false,
            remoteInputKey: Data(key), remoteInputKeyID: keyID, hdr: hdr, virtualDisplay: false,
            playAudioOnHost: settings.playAudioOnHost, surroundAudioInfo: audio.channelMask << 16 | audio.channelCount,
            gamepadMask: 1, persistGamepadsAfterDisconnect: false, coreParameters: CoreInfo.launchQueryParameters)
        configuration = StreamConfiguration(
            width: size.width, height: size.height, fps: fps, bitrateKbps: settings.bitrate(at: size),
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
