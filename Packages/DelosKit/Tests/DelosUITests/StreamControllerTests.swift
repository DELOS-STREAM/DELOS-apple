import DelosCore
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// A stream attempt driven by the test: it records the calls and fails or reports what it is told to.
@MainActor
private final class FakeSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    let continuation: AsyncStream<StreamEvent>.Continuation
    var input: (any StreamInputSink)? { nil }

    var launchFailure: LaunchFailure?
    var connectFailure: StreamError?
    /// Reported while connecting, before `connect` waits for ``finishConnect()``.
    var stages: [StreamStage] = []
    var quitSucceeds = true
    private(set) var launchedOn: DisplayInfo?
    private(set) var stops = 0
    private(set) var quits = 0
    private var gate: CheckedContinuation<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {
        launchedOn = display
        if let launchFailure { throw launchFailure }
    }

    func connect() async throws(StreamError) {
        for stage in stages { continuation.yield(.stageStarting(stage)) }
        await withCheckedContinuation { gate = $0 }
        if let connectFailure { throw connectFailure }
        continuation.yield(.connectionStarted)
    }

    func finishConnect() {
        gate?.resume()
        gate = nil
    }

    var isConnecting: Bool { gate != nil }

    func stop() async {
        stops += 1
        finishConnect()
        continuation.finish()
    }

    func quitApp() async -> Bool {
        quits += 1
        return quitSucceeds
    }
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let iPhone = DisplayInfo(pixelWidth: 1290, pixelHeight: 2796, maxFramesPerSecond: 120)

@MainActor
@Suite struct StreamControllerTests {
    @Test func stagesTellTheirLinesThenTheStreamRuns() async {
        let steps = FakeSteps()
        steps.stages = [.platformInit, .rtspHandshake]
        let controller = StreamController { steps }
        #expect(controller.greeting == L("stream_loader_greeting", "Gaming-PC"))
        controller.start(display: iPhone)
        await eventually { steps.isConnecting && controller.progress > 0.1 }
        #expect(steps.launchedOn == iPhone)
        #expect(controller.phase == .connecting)
        #expect(abs(controller.progress - 0.16) < 0.001)
        #expect(StageLines.options(.rtsp, pcName: "Gaming-PC").contains(controller.line))
        // A second report of the display (a new layout) does not start again
        controller.start(display: iPhone)
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        #expect(controller.phase == .streaming)
        #expect(controller.progress == 1)
    }

    @Test func aLaunchFailureShowsAndroidsMessage() async {
        let steps = FakeSteps()
        steps.launchFailure = .resumeForeign(code: 470)
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { controller.phase != .connecting }
        #expect(controller.phase == .failed(ResultText(
            title: L("stream_result_start_title"), sentence: L("conn_resume_foreign", Int32(470)), details: nil)))
        #expect(steps.stops == 1)
    }

    @Test func aFailedStageNamesTheStageAndTheCode() async {
        let steps = FakeSteps()
        steps.connectFailure = .stageFailed(.rtspHandshake, errorCode: -408)
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase != .connecting }
        guard case .failed(let text) = controller.phase else {
            Issue.record("not failed: \(controller.phase)")
            return
        }
        #expect(text.sentence == L("stream_result_timeout"))
        #expect(text.details?.hasPrefix(L("stream_result_failed_stage", StreamStage.rtspHandshake.name, Int32(-408))) == true)
    }

    @Test func tryAgainStartsANewAttempt() async {
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController {
            let steps = FakeSteps()
            steps.launchFailure = made.steps.isEmpty ? .offline : nil
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { controller.phase != .connecting }
        #expect(controller.phase == .failed(StreamText.launchFailure(.offline, pcName: "Gaming-PC", appName: "Desktop")))
        controller.retry()
        #expect(controller.phase == .connecting)
        await eventually { made.steps.count == 2 && made.steps[1].isConnecting }
        made.steps[1].finishConnect()
        await eventually { controller.phase == .streaming }
        #expect(controller.phase == .streaming)
    }

    @Test func aLostConnectionShowsTheResultAndANormalEndGoesBack() async {
        for (termination, ended) in [(StreamTermination.noVideoTraffic, false), (.graceful, true)] {
            let steps = FakeSteps()
            let controller = StreamController { steps }
            controller.start(display: iPhone)
            await eventually { steps.isConnecting }
            steps.finishConnect()
            await eventually { controller.phase == .streaming }
            steps.continuation.yield(.terminated(termination))
            await eventually { controller.phase != .streaming }
            if ended {
                #expect(controller.phase == .ended)
            } else {
                #expect(controller.phase == .failed(StreamText.termination(termination)!))
            }
        }
    }

    @Test func disconnectStopsAndQuitAlsoQuitsTheApp() async {
        for quit in [false, true] {
            let steps = FakeSteps()
            let controller = StreamController { steps }
            controller.start(display: iPhone)
            await eventually { steps.isConnecting }
            steps.finishConnect()
            await eventually { controller.phase == .streaming }
            controller.openMenu()
            #expect(controller.menuOpen)
            await controller.leave(quit: quit)
            #expect(controller.phase == .ended)
            #expect(!controller.menuOpen)
            #expect(steps.stops == 1)
            #expect(steps.quits == (quit ? 1 : 0))
        }
    }

    @Test func aRefusedQuitIsReported() async {
        let steps = FakeSteps()
        steps.quitSucceeds = false
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        await controller.leave(quit: true)
        #expect(controller.phase == .failed(StreamText.quitFailure(appName: "Desktop")))
    }

    @Test func leavingWhileConnectingIsNoFailure() async {
        let steps = FakeSteps()
        steps.connectFailure = .cancelled
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        await controller.leave(quit: false)
        #expect(controller.phase == .ended)
    }

    @Test func theMenuTakesTheControllerAndBClosesIt() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        let focus = FocusModel()
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        // The stream owns every command while the menu is closed
        #expect(StreamScreen.capture(.accept, controller: controller, focus: focus))
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus))
        #expect(controller.phase == .streaming)
        controller.openMenu()
        // The menu's focus gets the directions and A; B closes the menu
        #expect(StreamScreen.capture(.right, controller: controller, focus: focus) == false)
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus))
        #expect(!controller.menuOpen)
    }

    @Test func touchesAreIgnoredOutsideTheRunningStream() {
        let controller = StreamController { FakeSteps() }
        // No crash and no effect while connecting
        controller.touch(1, .began, at: .zero, width: 1000, time: 0)
        controller.touch(1, .ended, at: .zero, width: 1000, time: 0.1)
        #expect(controller.phase == .connecting)
    }
}

@MainActor
@Suite struct StreamTextTests {
    @Test func failuresUseAndroidsTexts() {
        let denied = StreamText.stageFailure(stage: "RTSP handshake", errorCode: 403)
        #expect(denied.title == L("stream_result_start_title"))
        #expect(denied.sentence == L("stream_result_denied"))
        #expect(denied.details == L("stream_result_failed_stage", "RTSP handshake", Int32(403)) + "\n\n" + L("stream_result_denied_details"))
        #expect(StreamText.stageFailure(stage: "x", errorCode: 61).sentence == L("stream_result_connecting"))
        #expect(StreamText.startFailure(.cancelled) == nil)
        #expect(StreamText.termination(.graceful) == nil)
        #expect(StreamText.termination(.protectedContent)?.title == L("stream_result_closed_title"))
        #expect(StreamText.termination(.noVideoFrame)?.sentence == L("stream_result_slow"))
    }

    @Test func largeErrorCodesAreHexadecimalLikeAndroid() {
        #expect(StreamText.errorCode(-1) == "-1")
        #expect(StreamText.errorCode(1000) == "1000")
        #expect(StreamText.errorCode(Int32(bitPattern: 0x800E_0001)) == "800e0001")
        #expect(StreamText.errorCode(4096) == "1000")
    }

    @Test func theHostsLaunchAnswersMapLikeNvConnection() {
        #expect(LiveStream.resumeFailure(HostError.hostStatus(code: 470, message: nil)) == .resumeForeign(code: 470))
        #expect(LiveStream.resumeFailure(HostError.hostStatus(code: 525, message: nil)) == .appMinimized)
        #expect(LiveStream.quitFailure(HostError.hostStatus(code: 599, message: "x")) == .quitForeign(code: 599))
        #expect(LiveStream.resumeFailure(HostError.refused) == .resumeFailed(detail: String(describing: HostError.refused)))
        #expect(LiveStream.detail(HostError.hostStatus(code: 500, message: "Busy")) == "Busy (500)")
    }

    @Test func everyStageHasLinesInEveryGroup() {
        for stage in StreamStage.allCases {
            let options = StageLines.options(StageLines.group(stage), pcName: "PC")
            #expect(options.count == 3)
            #expect(Set(options).count == 3)
        }
    }
}
