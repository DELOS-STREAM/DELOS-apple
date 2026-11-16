// What a stream session reports while it connects and runs.
import CDelosCommon

/// The steps of a connection, in the order the core runs them (`STAGE_*`).
public enum StreamStage: Int32, Sendable, CaseIterable {
    case platformInit = 1
    case nameResolution = 2
    case audioStreamInit = 3
    case rtspHandshake = 4
    case controlStreamInit = 5
    case videoStreamInit = 6
    case inputStreamInit = 7
    case controlStreamStart = 8
    case videoStreamStart = 9
    case audioStreamStart = 10
    case inputStreamStart = 11

    /// The core's English name of the stage, for logs and error details.
    public var name: String { String(cString: LiGetStageName(rawValue)) }
}

/// Network quality as the core judges it from packet loss.
public enum ConnectionStatus: Sendable, Equatable {
    case okay
    case poor
}

/// Why a running stream ended.
public enum StreamTermination: Sendable, Equatable {
    /// The host ended the stream normally (the game quit or the host stopped streaming).
    case graceful
    case noVideoTraffic
    case noVideoFrame
    case unexpectedEarlyTermination
    /// The host shows protected content it may not stream.
    case protectedContent
    case frameConversion
    /// Another error code of the core or the host.
    case error(Int32)

    init(errorCode: Int32) {
        switch errorCode {
        case ML_ERROR_GRACEFUL_TERMINATION: self = .graceful
        case ML_ERROR_NO_VIDEO_TRAFFIC: self = .noVideoTraffic
        case ML_ERROR_NO_VIDEO_FRAME: self = .noVideoFrame
        case ML_ERROR_UNEXPECTED_EARLY_TERMINATION: self = .unexpectedEarlyTermination
        case ML_ERROR_PROTECTED_CONTENT: self = .protectedContent
        case ML_ERROR_FRAME_CONVERSION: self = .frameConversion
        default: self = .error(errorCode)
        }
    }
}

/// One report of the core, in the order the core made them.
public enum StreamEvent: Sendable, Equatable {
    case stageStarting(StreamStage)
    case stageComplete(StreamStage)
    case stageFailed(StreamStage, errorCode: Int32)
    /// All stages are done; video and audio flow.
    case connectionStarted
    case connectionStatus(ConnectionStatus)
    /// The stream ended without `StreamSession.stop()`; the last event of the session.
    case terminated(StreamTermination)
    case hdrMode(enabled: Bool)
    case rumble(controller: UInt16, lowFrequency: UInt16, highFrequency: UInt16)
    case triggerRumble(controller: UInt16, left: UInt16, right: UInt16)
    /// The host wants motion events of `motionType` (`LI_MOTION_TYPE_*`) at `reportRateHz`; 0 stops them.
    case motionEventState(controller: UInt16, motionType: UInt8, reportRateHz: UInt16)
    case controllerLED(controller: UInt16, red: UInt8, green: UInt8, blue: UInt8)
    /// DualSense adaptive trigger effects (`DS_EFFECT_*` flags, 10-byte payloads).
    case adaptiveTriggers(
        controller: UInt16, eventFlags: UInt8, typeLeft: UInt8, typeRight: UInt8, left: [UInt8], right: [UInt8])
}

/// Why `StreamSession.start` failed.
public enum StreamError: Error, Sendable, Equatable {
    /// Another session of this process is starting or running; the core supports one at a time.
    case anotherSessionActive
    /// This session was started before; a session runs once.
    case alreadyStarted
    /// The core rejected the configuration or server information before the first stage (code of
    /// `LiStartConnection`).
    case rejected(code: Int32)
    /// A stage failed with the core's error code (often an `errno` or a host status).
    case stageFailed(StreamStage, errorCode: Int32)
    /// The starting task was cancelled or `stop()` was called during the start.
    case cancelled
}
