// The typed configuration of a stream and the host's server information, mapped to the C core's
// STREAM_CONFIGURATION and SERVER_INFORMATION.
import CDelosCommon

/// Whether the host is on the local network, which decides the packet size and the core's remote tuning.
public enum StreamingLocation: Int32, Sendable, CaseIterable {
    case local = 0  // STREAM_CFG_LOCAL
    case remote = 1  // STREAM_CFG_REMOTE
    /// The core decides from the resolved address (private ranges are local).
    case automatic = 2  // STREAM_CFG_AUTO
}

/// The speaker layouts the core can request.
public enum AudioConfiguration: Sendable, CaseIterable {
    case stereo
    case surround51
    case surround71

    /// The number of audio channels.
    public var channelCount: Int {
        switch self {
        case .stereo: 2
        case .surround51: 6
        case .surround71: 8
        }
    }

    /// The speaker mask of the layout (Windows `SPEAKER_*` bits, as the host expects them).
    public var channelMask: Int {
        switch self {
        case .stereo: 0x3
        case .surround51: 0x3F
        case .surround71: 0x63F
        }
    }

    /// The core's encoding: `MAKE_AUDIO_CONFIGURATION(channelCount, channelMask)` of Limelight.h.
    public var rawValue: Int32 {
        Int32(channelMask << 16 | channelCount << 8 | 0xCA)
    }

    /// The layout of a value encoded by the core, or nil for a layout the core does not define.
    public init?(rawValue: Int32) {
        guard let layout = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
        self = layout
    }
}

/// Video formats as the core's `VIDEO_FORMAT_*` bits: the formats the client can decode, or the one format the host
/// negotiated.
public struct VideoFormats: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let h264 = VideoFormats(rawValue: VIDEO_FORMAT_H264)
    public static let h264High444 = VideoFormats(rawValue: VIDEO_FORMAT_H264_HIGH8_444)
    public static let hevc = VideoFormats(rawValue: VIDEO_FORMAT_H265)
    public static let hevcMain10 = VideoFormats(rawValue: VIDEO_FORMAT_H265_MAIN10)
    public static let hevcRExt444 = VideoFormats(rawValue: VIDEO_FORMAT_H265_REXT8_444)
    public static let hevcRExt10_444 = VideoFormats(rawValue: VIDEO_FORMAT_H265_REXT10_444)
    public static let av1Main8 = VideoFormats(rawValue: VIDEO_FORMAT_AV1_MAIN8)
    public static let av1Main10 = VideoFormats(rawValue: VIDEO_FORMAT_AV1_MAIN10)
    public static let av1High444 = VideoFormats(rawValue: VIDEO_FORMAT_AV1_HIGH8_444)
    public static let av1High10_444 = VideoFormats(rawValue: VIDEO_FORMAT_AV1_HIGH10_444)
    /// PyroWave formats are carried for protocol parity with DELOS for Android; the Apple app does not offer them yet.
    public static let pyroWave = VideoFormats(rawValue: VIDEO_FORMAT_PYROWAVE)
    public static let pyroWave444 = VideoFormats(rawValue: VIDEO_FORMAT_PYROWAVE_444)
    public static let pyroWaveHDR10 = VideoFormats(rawValue: VIDEO_FORMAT_PYROWAVE_HDR10)
    public static let pyroWaveHDR10_444 = VideoFormats(rawValue: VIDEO_FORMAT_PYROWAVE_HDR10_444)

    public static let allH264 = VideoFormats(rawValue: VIDEO_FORMAT_MASK_H264)
    public static let allHEVC = VideoFormats(rawValue: VIDEO_FORMAT_MASK_H265)
    public static let allAV1 = VideoFormats(rawValue: VIDEO_FORMAT_MASK_AV1)
    public static let allPyroWave = VideoFormats(rawValue: VIDEO_FORMAT_MASK_PYROWAVE)
    /// Formats with 10 bits per component (HDR capable).
    public static let tenBit = VideoFormats(rawValue: VIDEO_FORMAT_MASK_10BIT)
    /// Formats with full-resolution chroma.
    public static let yuv444 = VideoFormats(rawValue: VIDEO_FORMAT_MASK_YUV444)
}

/// The codecs a host can encode, as the `SCM_*` bits of its server information (`ServerCodecModeSupport`).
public struct ServerCodecModes: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let h264 = ServerCodecModes(rawValue: SCM_H264)
    public static let h264High444 = ServerCodecModes(rawValue: SCM_H264_HIGH8_444)
    public static let hevc = ServerCodecModes(rawValue: SCM_HEVC)
    public static let hevcMain10 = ServerCodecModes(rawValue: SCM_HEVC_MAIN10)
    public static let hevcRExt444 = ServerCodecModes(rawValue: SCM_HEVC_REXT8_444)
    public static let hevcRExt10_444 = ServerCodecModes(rawValue: SCM_HEVC_REXT10_444)
    public static let av1Main8 = ServerCodecModes(rawValue: SCM_AV1_MAIN8)
    public static let av1Main10 = ServerCodecModes(rawValue: SCM_AV1_MAIN10)
    public static let av1High444 = ServerCodecModes(rawValue: SCM_AV1_HIGH8_444)
    public static let av1High10_444 = ServerCodecModes(rawValue: SCM_AV1_HIGH10_444)
    public static let pyroWave = ServerCodecModes(rawValue: SCM_PYROWAVE)
    public static let pyroWave444 = ServerCodecModes(rawValue: SCM_PYROWAVE_444)
    public static let pyroWaveHDR10 = ServerCodecModes(rawValue: SCM_PYROWAVE_HDR10)
    public static let pyroWaveHDR10_444 = ServerCodecModes(rawValue: SCM_PYROWAVE_HDR10_444)
}

/// The color space the host encodes in.
public enum ColorSpace: Int32, Sendable, CaseIterable {
    case rec601 = 0  // COLORSPACE_REC_601
    case rec709 = 1  // COLORSPACE_REC_709
    case rec2020 = 2  // COLORSPACE_REC_2020
}

/// The range of the encoded luma and chroma values.
public enum ColorRange: Int32, Sendable, CaseIterable {
    case limited = 0  // COLOR_RANGE_LIMITED
    case full = 1  // COLOR_RANGE_FULL
}

/// Which streams the client asks the host to encrypt (`ENCFLG_*`); the control stream and input are always
/// encrypted.
public struct EncryptionFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let audio = EncryptionFlags(rawValue: Int32(ENCFLG_AUDIO))
    public static let video = EncryptionFlags(rawValue: Int32(ENCFLG_VIDEO))
    /// Every stream, including those later protocol versions add.
    public static let all = EncryptionFlags(rawValue: -1)  // ENCFLG_ALL, 0xFFFFFFFF
}

/// The AES-128 key and IV that encrypt input; the same pair is sent to the host in the launch request.
public struct RemoteInputKey: Sendable, Equatable {
    public static let length = 16

    public let key: [UInt8]
    public let iv: [UInt8]

    /// Nil unless both values have 16 bytes.
    public init?(key: [UInt8], iv: [UInt8]) {
        guard key.count == Self.length, iv.count == Self.length else { return nil }
        self.key = key
        self.iv = iv
    }

    /// A new pair from the system's cryptographically secure random generator.
    public static func random() -> RemoteInputKey {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<2 * length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return RemoteInputKey(key: Array(bytes[..<length]), iv: Array(bytes[length...]))!
    }
}

/// PyroWave settings of DELOS hosts. Carried so the configuration matches DELOS for Android; the Apple app does not
/// decode PyroWave yet, so they only take effect when a PyroWave format is offered.
public struct PyroWaveSettings: Sendable, Equatable {
    /// The compression version the client accepts; 0 disables compression.
    public var compression: Int
    /// The link rate the host may assume, in Mbit/s; 0 lets the host decide.
    public var linkMbps: Int
    /// The rate the host paces packets at, in Mbit/s; 0 lets the host decide.
    public var paceMbps: Int

    public init(compression: Int = 0, linkMbps: Int = 0, paceMbps: Int = 0) {
        self.compression = compression
        self.linkMbps = linkMbps
        self.paceMbps = paceMbps
    }
}

/// Everything the client asks of a stream.
public struct StreamConfiguration: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    /// The video bit rate in kbit/s.
    public var bitrateKbps: Int
    /// The largest video packet in bytes; the core rounds it down to a multiple of 16.
    public var packetSize: Int
    public var streamingLocation: StreamingLocation
    public var audio: AudioConfiguration
    public var supportedVideoFormats: VideoFormats
    /// The display's refresh rate × 100 (hosts use it for frame pacing); 0 when unknown.
    public var clientRefreshRateX100: Int
    public var colorSpace: ColorSpace
    public var colorRange: ColorRange
    public var encryption: EncryptionFlags
    public var remoteInputKey: RemoteInputKey
    public var pyroWave: PyroWaveSettings

    public init(
        width: Int,
        height: Int,
        fps: Int,
        bitrateKbps: Int,
        packetSize: Int = 1392,
        streamingLocation: StreamingLocation = .automatic,
        audio: AudioConfiguration = .stereo,
        supportedVideoFormats: VideoFormats = .h264,
        clientRefreshRateX100: Int = 0,
        colorSpace: ColorSpace = .rec709,
        colorRange: ColorRange = .limited,
        encryption: EncryptionFlags = .audio,
        remoteInputKey: RemoteInputKey,
        pyroWave: PyroWaveSettings = PyroWaveSettings()
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.packetSize = packetSize
        self.streamingLocation = streamingLocation
        self.audio = audio
        self.supportedVideoFormats = supportedVideoFormats
        self.clientRefreshRateX100 = clientRefreshRateX100
        self.colorSpace = colorSpace
        self.colorRange = colorRange
        self.encryption = encryption
        self.remoteInputKey = remoteInputKey
        self.pyroWave = pyroWave
    }

    /// The C structure handed to `LiStartConnection`.
    var cValue: STREAM_CONFIGURATION {
        var config = STREAM_CONFIGURATION()
        LiInitializeStreamConfiguration(&config)
        config.width = Int32(clamping: width)
        config.height = Int32(clamping: height)
        config.fps = Int32(clamping: fps)
        config.bitrate = Int32(clamping: bitrateKbps)
        config.packetSize = Int32(clamping: packetSize)
        config.streamingRemotely = streamingLocation.rawValue
        config.audioConfiguration = audio.rawValue
        config.supportedVideoFormats = supportedVideoFormats.rawValue
        config.clientRefreshRateX100 = Int32(clamping: clientRefreshRateX100)
        config.colorSpace = colorSpace.rawValue
        config.colorRange = colorRange.rawValue
        config.encryptionFlags = encryption.rawValue
        withUnsafeMutableBytes(of: &config.remoteInputAesKey) { $0.copyBytes(from: remoteInputKey.key) }
        withUnsafeMutableBytes(of: &config.remoteInputAesIv) { $0.copyBytes(from: remoteInputKey.iv) }
        config.pyrowaveCompression = Int32(clamping: pyroWave.compression)
        config.pyrowaveLinkMbps = Int32(clamping: pyroWave.linkMbps)
        config.pyrowavePaceMbps = Int32(clamping: pyroWave.paceMbps)
        return config
    }
}

/// What the client knows about the host from its server information (`/serverinfo`) and the launch response.
public struct ServerInformation: Sendable, Equatable {
    /// Host name or IP address of the host.
    public var address: String
    /// `appversion` of the server information, for example "7.1.431.-1".
    public var appVersion: String
    /// `GfeVersion` of the server information; nil for hosts that do not send it.
    public var gfeVersion: String?
    /// `sessionUrl0` of the launch or resume response; nil for the well-known RTSP port.
    public var rtspSessionURL: String?
    public var codecModeSupport: ServerCodecModes

    public init(
        address: String,
        appVersion: String,
        gfeVersion: String? = nil,
        rtspSessionURL: String? = nil,
        codecModeSupport: ServerCodecModes
    ) {
        self.address = address
        self.appVersion = appVersion
        self.gfeVersion = gfeVersion
        self.rtspSessionURL = rtspSessionURL
        self.codecModeSupport = codecModeSupport
    }

    /// Calls `body` with the C structure; its strings are valid only during the call.
    func withCValue<Result>(_ body: (inout SERVER_INFORMATION) throws -> Result) rethrows -> Result {
        try address.withCString { address in
            try appVersion.withCString { appVersion in
                try gfeVersion.withOptionalCString { gfeVersion in
                    try rtspSessionURL.withOptionalCString { rtspSessionURL in
                        var info = SERVER_INFORMATION()
                        LiInitializeServerInformation(&info)
                        info.address = address
                        info.serverInfoAppVersion = appVersion
                        info.serverInfoGfeVersion = gfeVersion
                        info.rtspSessionUrl = rtspSessionURL
                        info.serverCodecModeSupport = codecModeSupport.rawValue
                        return try body(&info)
                    }
                }
            }
        }
    }
}

extension Optional where Wrapped == String {
    fileprivate func withOptionalCString<Result>(
        _ body: (UnsafePointer<CChar>?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .some(let string): try string.withCString(body)
        case .none: try body(nil)
        }
    }
}
