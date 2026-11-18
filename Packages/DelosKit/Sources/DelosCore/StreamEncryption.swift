import CDelosCommon
import Synchronization

/// What a stream encrypts (`StreamEncryption` of DELOS for Android, diag/StreamEncryption.kt): video and audio as the
/// connection negotiated them (nil: not reported), and the control stream, which the core encrypts for hosts of app
/// version 7.1.431 and newer.
public struct StreamEncryption: Equatable, Sendable {
    public let video: Bool?
    public let audio: Bool?
    public let control: Bool

    public init(video: Bool?, audio: Bool?, control: Bool) {
        self.video = video
        self.audio = audio
        self.control = control
    }

    /// The English line of the diagnostic log: "Stream encryption: video on, audio off, control on".
    public var logLine: String {
        "Stream encryption: video \(Self.word(video)), audio \(Self.word(audio)), control \(Self.word(control))"
    }

    private static func word(_ value: Bool?) -> String {
        switch value {
        case true?: "on"
        case false?: "off"
        case nil: "unknown"
        }
    }

    /// From the core's flags ([flags] nil: not reported; bit 0 video, bit 1 audio) and the host's `appversion`.
    public static func of(flags: Int32?, serverAppVersion: String?) -> StreamEncryption {
        StreamEncryption(
            video: flags.map { $0 & DELOS_STREAM_ENCRYPTION_VIDEO != 0 },
            audio: flags.map { $0 & DELOS_STREAM_ENCRYPTION_AUDIO != 0 },
            control: controlEncrypted(serverAppVersion: serverAppVersion))
    }

    /// The core encrypts the control stream for app version 7.1.431 and newer; an unreadable version counts as older.
    public static func controlEncrypted(serverAppVersion: String?) -> Bool {
        guard let parts = serverAppVersion?.split(separator: ".").map({ Int($0) }), parts.count >= 3,
              let major = parts[0], let minor = parts[1], let patch = parts[2]
        else { return false }
        return major > 7 || (major == 7 && (minor > 1 || (minor == 1 && patch >= 431)))
    }

    private static let lastStream = Mutex<StreamEncryption?>(nil)

    /// The last stream of this process; nil before the first one started.
    public static var last: StreamEncryption? { lastStream.withLock { $0 } }

    /// Reads what the connection that has just started negotiated and remembers it as ``last``.
    @discardableResult
    static func read(serverAppVersion: String?) -> StreamEncryption {
        let encryption = of(flags: DelosCommonGetStreamEncryption(), serverAppVersion: serverAppVersion)
        lastStream.withLock { $0 = encryption }
        return encryption
    }
}
