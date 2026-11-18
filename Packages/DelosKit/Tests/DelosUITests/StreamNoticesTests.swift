import DelosCore
import DelosData
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// A stream attempt for the notices: it connects at once, reports what it is told to and tests ports as told.
@MainActor
private final class NoticeSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    let continuation: AsyncStream<StreamEvent>.Continuation
    var input: (any StreamInputSink)? { nil }
    var waiting: (@MainActor () -> Void)?
    var warnings: [String] = []
    var bitrateKbps: Int? = 20000
    var portTest = PortTest.Result.inconclusive
    var connectFailure: StreamError?
    /// Times the launch was not answered before it was.
    var unanswered = 0
    var quitSucceeds = true

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {
        for _ in 0..<unanswered { waiting?() }
    }

    func connect() async throws(StreamError) {
        if let connectFailure { throw connectFailure }
        continuation.yield(.connectionStarted)
    }

    func stop() async { continuation.finish() }
    func quitApp() async -> Bool { quitSucceeds }
    func testPorts(_ ports: UInt32) async -> PortTest.Result { portTest }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let display = DisplayInfo(pixelWidth: 2000, pixelHeight: 1000, maxFramesPerSecond: 60)

@MainActor
@Suite struct StreamNoticesTests {
    private func streaming(_ steps: NoticeSteps, toasts: Box = Box()) async -> StreamController {
        let controller = StreamController { steps }
        controller.toast = { text, kind, duration in toasts.items.append((text, kind, duration)) }
        controller.start(display: display)
        await eventually { controller.phase == .streaming }
        return controller
    }

    final class Box { var items: [(String, ToastKind?, Double)] = [] }

    @Test func theLaunchWarningsAreLongWarningToasts() async {
        let steps = NoticeSteps()
        steps.warnings = [L("conn_metered"), L("stream_warn_no_av1_decoder")]
        let toasts = Box()
        _ = await streaming(steps, toasts: toasts)
        #expect(toasts.items.map(\.0) == steps.warnings)
        #expect(toasts.items.allSatisfy { $0.1 == .warning && $0.2 == ToastTiming.streamLongMs })
    }

    @Test func anUnansweredLaunchTellsTheUnlockingLines() async {
        let steps = NoticeSteps()
        steps.unanswered = 1
        let controller = StreamController { steps }
        steps.connectFailure = .cancelled
        controller.start(display: display)
        await eventually { StageLines.options(.unlocking, pcName: "Gaming-PC").contains(controller.line) }
        #expect(StageLines.options(.unlocking, pcName: "Gaming-PC").contains(controller.line))
    }

    @Test func aPoorConnectionIsSlowAboveFiveMegabitsAndGoesWhenOkay() async {
        let steps = NoticeSteps()
        let controller = await streaming(steps)
        steps.continuation.yield(.connectionStatus(.poor))
        await eventually { controller.connectionNotice != nil }
        #expect(controller.connectionNotice == L("slow_connection_msg"))
        steps.continuation.yield(.connectionStatus(.okay))
        await eventually { controller.connectionNotice == nil }
        #expect(controller.connectionNotice == nil)
        #expect(StreamWarnings.connection(.poor, bitrateKbps: 5000, disabled: false) == L("poor_connection_msg"))
        #expect(StreamWarnings.connection(.poor, bitrateKbps: 50000, disabled: true) == nil)
    }

    @Test func aQuitGameSaysItSucceeded() async {
        let steps = NoticeSteps()
        let toasts = Box()
        let controller = await streaming(steps, toasts: toasts)
        await controller.leave(quit: true)
        #expect(toasts.items.last?.0 == L("applist_quit_success") + " Desktop")
        #expect(toasts.items.last?.1 == .success)
        #expect(toasts.items.last?.2 == ToastTiming.streamLongMs)
    }

    @Test func aBlockedNetworkExplainsALostVideoStream() async {
        let steps = NoticeSteps()
        steps.portTest = .blocked(0x0100)
        let controller = await streaming(steps)
        steps.continuation.yield(.terminated(.noVideoTraffic))
        await eventually { controller.phase != .streaming }
        guard case .failed(let text) = controller.phase else {
            Issue.record("not failed: \(controller.phase)")
            return
        }
        #expect(text.sentence == L("stream_result_blocked"))
        #expect(text.details?.contains(L("stream_result_ports_hint")) == true)
    }

    @Test func aFailedVideoStageIsTheDecoders() {
        let text = StreamText.startFailure(.stageFailed(.videoStreamStart, errorCode: -1))
        #expect(text?.sentence == L("stream_result_decoder"))
        #expect(text?.details?.contains(L("stream_result_decoder_details")) == true)
        let blocked = StreamText.stageFailure(stage: "RTSP handshake", errorCode: 10, ports: "TCP 48010", blocked: true)
        #expect(blocked.sentence == L("stream_result_blocked"))
        #expect(blocked.details?.hasSuffix(L("stream_result_ports_hint") + "\nTCP 48010") == true)
    }

    @Test func anUnansweredLaunchIsAskedTwiceMoreThenTimesOut() {
        #expect(LaunchRetry.isUnanswered(HostError.timedOut))
        #expect(!LaunchRetry.isUnanswered(HostError.hostStatus(code: 500, message: nil)))
        #expect(LaunchRetry.after(attempt: 0, test: .inconclusive) == nil)
        #expect(LaunchRetry.after(attempt: 1, test: .passed) == nil)
        guard case .unreachable(-408, _, false)? = LaunchRetry.after(attempt: 2, test: .passed) else {
            Issue.record("the third is no time-out")
            return
        }
        guard case .unreachable(0, _, true)? = LaunchRetry.after(attempt: 0, test: .blocked(1)) else {
            Issue.record("a blocked network is asked again")
            return
        }
    }

    @Test func theWarningsFollowAndroidsConditions() {
        var settings = StreamSettings()
        settings.hdr = true
        settings.codec = .av1
        let warnings = StreamWarnings.of(settings: settings, decodable: [.h264, .hevc], displaySupportsHDR: true, metered: true)
        #expect(warnings == [L("conn_metered"), L("stream_warn_decoder_no_hdr10"), L("stream_warn_no_av1_decoder")])
        #expect(StreamWarnings.of(settings: settings, decodable: [.h264, .hevc, .hevcMain10, .av1Main8], displaySupportsHDR: false, metered: false)
            == [L("stream_warn_display_no_hdr10")])
    }

    @Test func theExitSceneSaysQuittingTheAppWithoutAName() {
        #expect(StreamText.quitting(appName: "") == L("stream_exit_quitting_game"))
        #expect(StreamText.quitting(appName: "Hades") == L("stream_exit_quitting", "Hades"))
    }
}
