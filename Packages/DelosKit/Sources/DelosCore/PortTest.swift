import CDelosCommon
import Foundation

/// The core's connection test (`MoonBridge.testClientConnectivity` of DELOS for Android, DelosStreamActivity.java:1657-1680,
/// 1700-1722): whether this network blocks the ports a failed stage or a lost stream used, asked of Moonlight's test server.
public enum PortTest {
    /// What the test found.
    public enum Result: Equatable, Sendable {
        /// Every port answered.
        case passed
        /// The test itself could not run (no Internet, the test server unreachable): nothing is known.
        case inconclusive
        /// These ports (`ML_PORT_FLAG_*`) did not answer: this network blocks them.
        case blocked(UInt32)

        /// The network is known to block the stream.
        public var blocked: Bool {
            if case .blocked = self { true } else { false }
        }
    }

    /// Moonlight's test server for Apple clients (Android asks `android.conntest.moonlight-stream.org`, ServerHelper.java:36).
    public static let server = "ios.conntest.moonlight-stream.org"
    /// The ports of the PC's HTTP and HTTPS server, which a launch talks to (`ML_PORT_FLAG_TCP_47984 | ML_PORT_FLAG_TCP_47989`,
    /// NvConnection.java:439).
    public static let launchPorts: UInt32 = 0x0001 | 0x0002

    /// The ports a failed [stage] used; 0 when no port is likely involved.
    public static func ports(stage: StreamStage) -> UInt32 {
        UInt32(LiGetPortFlagsFromStage(Int32(stage.rawValue)))
    }

    /// The ports a stream that ended with [termination] used; 0 when no port is likely involved.
    public static func ports(termination: StreamTermination) -> UInt32 {
        UInt32(LiGetPortFlagsFromTerminationErrorCode(termination.errorCode))
    }

    /// The ports as the result's details list them, one per line ("TCP 47984").
    public static func describe(_ ports: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        LiStringifyPortFlags(ports, "\n", &buffer, Int32(buffer.count))
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Tests [ports] (blocking network I/O, run off the caller's thread). No ports: nothing to test, passed.
    public static func run(_ ports: UInt32) async -> Result {
        guard ports != 0 else { return .passed }
        return await Task.detached(priority: .userInitiated) {
            let found = LiTestClientConnectivity(server, 443, ports)
            switch found {
            case 0: return Result.passed
            case 0xFFFF_FFFF: return Result.inconclusive
            default: return Result.blocked(UInt32(found))
            }
        }.value
    }
}

extension StreamTermination {
    /// The core's error code of this termination (`ML_ERROR_*`).
    public var errorCode: Int32 {
        switch self {
        case .graceful: ML_ERROR_GRACEFUL_TERMINATION
        case .noVideoTraffic: ML_ERROR_NO_VIDEO_TRAFFIC
        case .noVideoFrame: ML_ERROR_NO_VIDEO_FRAME
        case .unexpectedEarlyTermination: ML_ERROR_UNEXPECTED_EARLY_TERMINATION
        case .protectedContent: ML_ERROR_PROTECTED_CONTENT
        case .frameConversion: ML_ERROR_FRAME_CONVERSION
        case .error(let code): code
        }
    }
}
