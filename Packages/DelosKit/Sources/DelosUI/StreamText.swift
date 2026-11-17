import DelosCore
import Foundation

/// The words of the result overlay (`ResultText` in DELOS for Android): a short title, one calm sentence, and the
/// technical details behind Details.
struct ResultText: Equatable, Sendable {
    let title: String
    let sentence: String
    let details: String?
}

/// Why a stream could not start before the streaming core connected: the PC's answers to the launch (the messages of
/// DELOS for Android's `NvConnection.startApp`).
enum LaunchFailure: Error, Equatable, Sendable {
    case offline
    case notPaired
    case appNotFound
    /// The PC did not let DELOS start the app (status 403).
    case denied
    /// The running session belongs to another device (status 470).
    case resumeForeign(code: Int)
    /// The running app is minimized on the PC (status 525).
    case appMinimized
    case resumeFailed(detail: String)
    /// Another app than the one asked for runs on the PC: it is not quit without the player's choice.
    case otherAppRunning
    case launchFailed(detail: String)
}

/// What the player reads when a stream failed (`describeStreamFailure` and the launch messages of DELOS for Android).
enum StreamText {
    static func launchFailure(_ failure: LaunchFailure, pcName: String, appName: String) -> ResultText {
        let title = L("stream_result_start_title")
        switch failure {
        case .offline:
            return ResultText(title: title, sentence: L("stream_result_offline", pcName), details: L("stream_result_offline_details"))
        case .notPaired:
            return ResultText(title: title, sentence: L("stream_result_unpaired", pcName), details: L("stream_result_unpaired_details"))
        case .appNotFound:
            return ResultText(title: title, sentence: L("conn_app_not_found", appName), details: nil)
        case .denied:
            return ResultText(title: title, sentence: L("stream_result_denied"), details: L("stream_result_denied_details"))
        case .resumeForeign(let code):
            return ResultText(title: title, sentence: L("conn_resume_foreign", Int32(clamping: code)), details: nil)
        case .appMinimized:
            return ResultText(title: title, sentence: L("conn_app_minimized"), details: nil)
        case .resumeFailed(let detail):
            return ResultText(title: title, sentence: L("conn_resume_failed"), details: detail)
        case .otherAppRunning:
            return ResultText(title: title, sentence: L("scut_other_game_running"), details: nil)
        case .launchFailed(let detail):
            return ResultText(title: title, sentence: L("conn_launch_failed"), details: detail)
        }
    }

    /// A connection stage that failed with the core's error code (an errno, a host status, or -408 for a time-out).
    static func stageFailure(stage: String, errorCode: Int32) -> ResultText {
        var details = L("stream_result_failed_stage", stage, errorCode)
        let sentence: String
        switch errorCode {
        case 403:
            sentence = L("stream_result_denied")
            details += "\n\n" + L("stream_result_denied_details")
        case -408:
            sentence = L("stream_result_timeout")
            details += "\n\n" + L("stream_result_timeout_details")
        default:
            sentence = L("stream_result_connecting")
        }
        return ResultText(title: L("stream_result_start_title"), sentence: sentence, details: details)
    }

    /// A failed `StreamSession.start`; nil when it was cancelled (the player left).
    static func startFailure(_ error: StreamError) -> ResultText? {
        switch error {
        case .cancelled:
            return nil
        case let .stageFailed(stage, errorCode):
            return stageFailure(stage: stage.name, errorCode: errorCode)
        case let .rejected(code):
            return stageFailure(stage: StreamStage.platformInit.name, errorCode: code)
        case .anotherSessionActive, .alreadyStarted:
            return stageFailure(stage: StreamStage.platformInit.name, errorCode: -1)
        }
    }

    /// A running stream that ended without the player; nil for a normal end (the PC closed the game or the stream).
    static func termination(_ termination: StreamTermination) -> ResultText? {
        let lost = L("stream_result_lost_title"), closed = L("stream_result_closed_title")
        switch termination {
        case .graceful:
            return nil
        case .noVideoTraffic:
            return ResultText(title: lost, sentence: L("stream_result_no_video"), details: L("stream_result_no_video_details"))
        case .noVideoFrame:
            return ResultText(title: lost, sentence: L("stream_result_slow"), details: L("stream_result_slow_details"))
        case .unexpectedEarlyTermination, .protectedContent:
            return ResultText(title: closed, sentence: L("stream_result_host_error"), details: L("stream_result_host_error_details"))
        case .frameConversion:
            return ResultText(title: closed, sentence: L("stream_result_encoding"), details: L("stream_result_encoding_details"))
        case .error(let code):
            return ResultText(title: lost, sentence: L("stream_result_ended"), details: L("stream_result_terminated_details", errorCode(code)))
        }
    }

    /// Android shows large codes in hexadecimal (`Integer.toHexString`: the 32-bit two's complement).
    static func errorCode(_ code: Int32) -> String {
        abs(Int(code)) > 1000 ? String(UInt32(bitPattern: code), radix: 16) : String(code)
    }

    /// The PC was asked to quit the game and did not (`stream_quit_failed`).
    static func quitFailure(appName: String) -> ResultText {
        ResultText(title: L("stream_quit_failed", appName), sentence: "", details: nil)
    }
}

/// The status lines told while a stream connects (`StreamLoader` of DELOS for Android): for each connection stage one
/// of a few funny sentences, in turn, starting at a random one.
@MainActor
enum StageLines {
    enum Group: CaseIterable {
        case platform, nameResolution, rtsp, controlStream, videoStream, audioStream, inputStream
    }

    private static var told: [Group: Int] = [:]

    static func group(_ stage: StreamStage) -> Group {
        switch stage {
        case .platformInit: .platform
        case .nameResolution: .nameResolution
        case .rtspHandshake: .rtsp
        case .controlStreamInit, .controlStreamStart: .controlStream
        case .videoStreamInit, .videoStreamStart: .videoStream
        case .audioStreamInit, .audioStreamStart: .audioStream
        case .inputStreamInit, .inputStreamStart: .inputStream
        }
    }

    static func options(_ group: Group, pcName pc: String) -> [String] {
        switch group {
        case .platform:
            [L("stream_loader_lines_platform_0", pc), L("stream_loader_lines_platform_1", pc), L("stream_loader_lines_platform_2", pc)]
        case .nameResolution:
            [L("stream_loader_lines_name_resolution_0", pc), L("stream_loader_lines_name_resolution_1", pc),
             L("stream_loader_lines_name_resolution_2", pc)]
        case .rtsp:
            [L("stream_loader_lines_rtsp_0", pc), L("stream_loader_lines_rtsp_1", pc), L("stream_loader_lines_rtsp_2", pc)]
        case .controlStream:
            [L("stream_loader_lines_control_stream_0", pc), L("stream_loader_lines_control_stream_1", pc),
             L("stream_loader_lines_control_stream_2", pc)]
        case .videoStream:
            [L("stream_loader_lines_video_stream_0", pc), L("stream_loader_lines_video_stream_1", pc),
             L("stream_loader_lines_video_stream_2", pc)]
        case .audioStream:
            [L("stream_loader_lines_audio_stream_0", pc), L("stream_loader_lines_audio_stream_1", pc),
             L("stream_loader_lines_audio_stream_2", pc)]
        case .inputStream:
            [L("stream_loader_lines_input_stream_0", pc), L("stream_loader_lines_input_stream_1", pc),
             L("stream_loader_lines_input_stream_2", pc)]
        }
    }

    /// The next line of `group`.
    static func line(_ group: Group, pcName: String) -> String {
        let options = options(group, pcName: pcName)
        let n = told[group] ?? Int.random(in: 0..<options.count)
        told[group] = n + 1
        return options[n % options.count]
    }
}
