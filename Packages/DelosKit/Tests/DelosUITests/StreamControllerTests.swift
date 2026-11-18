import DelosData
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
    /// `launch` waits for ``finishLaunch()``, `stop` for ``finishStop()``.
    var holdsLaunch = false
    var holdsStop = false
    private(set) var launchedOn: DisplayInfo?
    private(set) var stops = 0
    private(set) var quits = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var launchGate: CheckedContinuation<Void, Never>?
    private var stopGate: CheckedContinuation<Void, Never>?

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {
        launchedOn = display
        if holdsLaunch { await withCheckedContinuation { launchGate = $0 } }
        if let launchFailure { throw launchFailure }
    }

    func finishLaunch() {
        launchGate?.resume()
        launchGate = nil
    }

    var isLaunching: Bool { launchGate != nil }

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

    /// Ends a connect that waits, as a real session's stop does; here the connect returns normally, as a start that
    /// won the race against the stop would.
    func stop() async {
        stops += 1
        finishConnect()
        continuation.finish()
        if holdsStop { await withCheckedContinuation { stopGate = $0 } }
    }

    func finishStop() {
        stopGate?.resume()
        stopGate = nil
    }

    var isStopping: Bool { stopGate != nil }

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

    @Test func theBackgroundClosesTheStreamAndTheReturnConnectsAgain() async {
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController {
            let steps = FakeSteps()
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps.last?.isConnecting == true }
        made.steps.last?.finishConnect()
        await eventually { controller.phase == .streaming }
        await controller.enteredBackground()?.value
        // Closed at once, no failure shown, the loader waits for the return
        #expect(made.steps[0].stops == 1)
        #expect(controller.phase == .connecting)
        controller.returnedToForeground()
        await eventually { made.steps.count == 2 && made.steps[1].isConnecting }
        made.steps[1].finishConnect()
        await eventually { controller.phase == .streaming }
        #expect(controller.phase == .streaming)
        #expect(made.steps[1].launchedOn == iPhone)
    }

    @Test func theReturnLaunchesOnlyOnceTheClosedConnectionHasStopped() async {
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController {
            let steps = FakeSteps()
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps.last?.isConnecting == true }
        made.steps[0].finishConnect()
        await eventually { controller.phase == .streaming }
        made.steps[0].holdsStop = true

        let closed = controller.enteredBackground()
        controller.returnedToForeground()
        await eventually { made.steps[0].isStopping }
        // The core still stops: the new attempt waits instead of finding it taken
        #expect(made.steps.count == 2)
        #expect(made.steps[1].launchedOn == nil)
        made.steps[0].finishStop()
        await closed?.value
        await eventually { made.steps[1].isConnecting }
        #expect(made.steps[1].launchedOn == iPhone)
    }

    @Test func aLaunchThatFailsAfterTheReturnDoesNotFailTheNewAttempt() async {
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController {
            let steps = FakeSteps()
            if made.steps.isEmpty {
                steps.holdsLaunch = true
                steps.launchFailure = .offline
            }
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps[0].isLaunching }
        await controller.enteredBackground()?.value
        controller.returnedToForeground()
        await eventually { made.steps.count == 2 && made.steps[1].isConnecting }

        // The first attempt's launch ends only now, and fails
        made.steps[0].finishLaunch()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(controller.phase == .connecting)
        made.steps[1].finishConnect()
        await eventually { controller.phase == .streaming }
        #expect(controller.phase == .streaming)
    }

    @Test func aConnectionThatCompletesAfterTheBackgroundIsNotShown() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }

        // The stop lets the waiting connect return normally
        await controller.enteredBackground()?.value
        try? await Task.sleep(for: .milliseconds(50))

        #expect(controller.phase == .connecting)
        #expect(controller.suspended)
    }

    @Test func tryAgainAfterALostConnectionLaunchesOnceTheOldOneHasStopped() async {
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController {
            let steps = FakeSteps()
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps.last?.isConnecting == true }
        made.steps[0].finishConnect()
        await eventually { controller.phase == .streaming }
        made.steps[0].holdsStop = true
        made.steps[0].continuation.yield(.terminated(.noVideoTraffic))
        await eventually { controller.phase != .streaming }

        controller.retry()
        await eventually { made.steps[0].isStopping }
        #expect(made.steps[0].stops == 1)
        #expect(made.steps.count == 2 && made.steps[1].launchedOn == nil)
        made.steps[0].finishStop()
        await eventually { made.steps[1].isConnecting }
        #expect(made.steps[1].launchedOn == iPhone)
    }

    @Test func returningWithoutHavingLeftDoesNothing() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        controller.returnedToForeground()
        #expect(steps.stops == 0)
        #expect(controller.phase == .connecting)
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
                // The lost video ports are listed; the fake's test cannot tell whether they are blocked
                let ports = PortTest.describe(PortTest.ports(termination: termination))
                #expect(controller.phase == .failed(StreamText.termination(termination, ports: ports)!))
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

    @Test func aSecondLeaveWaitsForTheFirstToFinish() async {
        let steps = FakeSteps()
        steps.holdsStop = true
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        let first = Task { await controller.leave(quit: false) }
        await eventually { steps.isStopping }
        // What the app does on Command-Q after the screen's own leaving has begun
        var secondReturned = false
        let second = Task {
            await controller.leave(quit: false)
            secondReturned = true
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!secondReturned && controller.phase != .ended, "the disconnect is not over")
        steps.finishStop()
        await first.value
        await second.value
        #expect(secondReturned && controller.phase == .ended)
        #expect(steps.stops == 1)
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
        controller.loaderEnded()
        // The stream owns every command while the menu is closed
        #expect(StreamScreen.capture(.accept, controller: controller, focus: focus))
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus))
        #expect(controller.phase == .streaming)
        controller.openMenu()
        // The menu's focus gets the directions and A; B closes the menu
        let later = Date.now.addingTimeInterval(1)
        #expect(StreamScreen.capture(.right, controller: controller, focus: focus, at: later) == false)
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus))
        #expect(!controller.menuOpen)
    }

    @Test func aDirectionOrAcceptHeldFromTheGameNeverReachesTheMenuOrWrapsOntoQuit() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        let focus = FocusModel()
        var cancelled = 0
        controller.menuOpened = { cancelled += 1 }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
        controller.openMenu()
        #expect(cancelled == 1)
        // Just opened: the held direction and its repeats, and a press of A, are swallowed
        for repeats in 0..<3 {
            #expect(StreamScreen.capture(.left, controller: controller, focus: focus, repeatCount: repeats))
        }
        #expect(StreamScreen.capture(.accept, controller: controller, focus: focus))
        // Later a new press is the player's, a repeat of a held direction still is not
        let later = Date.now.addingTimeInterval(1)
        #expect(StreamScreen.capture(.left, controller: controller, focus: focus, repeatCount: 0, at: later) == false)
        #expect(StreamScreen.capture(.left, controller: controller, focus: focus, repeatCount: 3, at: later))
    }

    @Test func theSiriRemoteOpensTheStreamMenuWithPlayPauseAndWithoutAControllerWithMenu() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        let focus = FocusModel()
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
        // A controller's Menu button reaches the app as Menu too, but it is Start for the PC: nothing opens
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus, fromRemote: true, hasGamepad: true))
        #expect(!controller.menuOpen)
        // X of a controller is the same command as Play/Pause, but not from the remote: the PC gets it
        #expect(StreamScreen.capture(.options, controller: controller, focus: focus, fromRemote: false, hasGamepad: true))
        #expect(!controller.menuOpen)
        // Play/Pause opens the menu and closes it again; so does Menu while it is open
        #expect(StreamScreen.capture(.options, controller: controller, focus: focus, fromRemote: true, hasGamepad: true))
        #expect(controller.menuOpen)
        #expect(StreamScreen.capture(.options, controller: controller, focus: focus, fromRemote: true, hasGamepad: true))
        #expect(!controller.menuOpen)
        // Without a controller the remote's Menu opens it, and closes it
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus, fromRemote: true, hasGamepad: false))
        #expect(controller.menuOpen)
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus, fromRemote: true, hasGamepad: false))
        #expect(!controller.menuOpen)
    }

    @Test func touchesAreIgnoredOutsideTheRunningStream() {
        let controller = StreamController { FakeSteps() }
        // No crash and no effect while connecting
        let area = StreamController.TouchArea(width: 1000, height: 600)
        controller.touch(1, .began, at: CGPoint(x: 500, y: 550), area: area, time: 0)
        controller.touch(1, .moved, at: CGPoint(x: 500, y: 100), area: area, time: 0.05)
        controller.touch(1, .ended, at: .zero, area: area, time: 0.1)
        #expect(!controller.menuOpen)
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

@MainActor
extension StreamControllerTests {
    @Test func aLeavingFromTheMenuKeepsTheExitSceneForItsHoldThenEnds() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.leavingHold = .milliseconds(300)
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        let began = ContinuousClock.now
        let leaving = Task { await controller.leave(quit: true, scene: true) }
        await eventually { if case .leaving = controller.phase { true } else { false } }
        #expect(controller.leavingScene && controller.leavingQuit)
        try? await Task.sleep(for: .milliseconds(100))
        if case .leaving = controller.phase {} else { Issue.record("the scene ended before its hold") }
        await leaving.value
        #expect(controller.phase == .ended)
        #expect(ContinuousClock.now - began >= .milliseconds(290))
        #expect(steps.quits == 1)
    }

    @Test func aLeavingWithoutTheSceneEndsAsSoonAsTheStreamStopped() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.leavingHold = .seconds(30)
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        await controller.leave(quit: false)
        #expect(controller.phase == .ended)
        #expect(!controller.leavingScene && !controller.leavingQuit)
    }

    @Test func aFailedQuitShowsTheResultWithoutWaitingForTheScene() async {
        let steps = FakeSteps()
        steps.quitSucceeds = false
        let controller = StreamController { steps }
        controller.leavingHold = .seconds(30)
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        await controller.leave(quit: true, scene: true)
        if case .failed = controller.phase {} else { Issue.record("expected the result overlay") }
    }

    @Test func theNameOfTheGameAndThePCAreTheLaunchScenesWords() {
        let controller = StreamController { FakeSteps() }
        #expect(controller.appName == "Desktop" && controller.pcName == "Gaming-PC")
    }
}

@Suite struct LaunchChoiceTests {
    @Test func aLaunchNeverQuitsAnotherRunningApp() {
        #expect(LaunchChoice.of(app: 7, running: 0) == .launch)
        #expect(LaunchChoice.of(app: 7, running: 7) == .resume)
        #expect(LaunchChoice.of(app: 7, running: 9) == .otherAppRunning)
        #expect(StreamText.launchFailure(.otherAppRunning, pcName: "PC", appName: "A").sentence
            == "Another app is already running · quit it from Delos first")
    }
}

/// Cancelling the loader (issue #5, Android #92): B, Escape and the Cancel pill end this client's attempt in every phase; the game
/// is never quit on the PC and the library comes back.
@MainActor
@Suite struct LoaderCancelTests {
    @Test func theStateMachineCancelsOnceWhileTheSceneIsUp() {
        var loader = LoaderCancel()
        #expect(loader.phase == .connecting && loader.cancellable)
        loader.connected()
        #expect(loader.phase == .opening && loader.cancellable)
        let first = loader.request()
        #expect(first)
        #expect(loader.phase == .cancelled && !loader.cancellable)
        let second = loader.request()
        #expect(!second, "one cancel for one attempt")
        loader.ended()
        #expect(loader.phase == .cancelled, "a cancelled loader stays cancelled")
        loader.connected()
        #expect(loader.phase == .cancelled)
    }

    @Test func aFinishedSceneCannotBeCancelled() {
        var loader = LoaderCancel()
        loader.connected()
        loader.ended()
        #expect(loader.phase == .gone && !loader.cancellable)
        let late = loader.request()
        #expect(!late)
        var early = LoaderCancel()
        early.ended()
        let earlyRequest = early.request()
        #expect(early.phase == .gone && !earlyRequest)
    }

    @Test func aCancelOnlyStopsTheConnectionAndGoesBack() {
        let plan = LoaderCancel.plan
        #expect(plan.stopConnection && plan.returnToLibrary)
        #expect(!plan.quitGame && !plan.showResult)
    }

    @Test func cancelWhileLaunchingStopsTheAttemptAndNeverQuitsTheGame() async {
        let steps = FakeSteps()
        steps.holdsLaunch = true
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isLaunching }
        #expect(controller.loaderCancellable)
        await controller.cancelLoader()
        #expect(controller.phase == .ended)
        #expect(steps.stops == 1)
        #expect(steps.quits == 0)
        #expect(controller.loader.phase == .cancelled)
        steps.finishLaunch()
    }

    @Test func cancelWhileConnectingEndsWithoutAResultOverlay() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        await controller.cancelLoader()
        #expect(controller.phase == .ended)
        #expect(steps.quits == 0)
        // Asking again changes nothing
        await controller.cancelLoader()
        #expect(steps.stops == 1)
    }

    @Test func bAndEscapeCancelWhileConnecting() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        #expect(StreamScreen.capture(.accept, controller: controller, focus: FocusModel()))
        #expect(controller.phase == .connecting)
        #expect(StreamScreen.capture(.back, controller: controller, focus: FocusModel()))
        await eventually { controller.phase == .ended }
        #expect(controller.phase == .ended)
        #expect(steps.quits == 0)
    }

    @Test func whileTheSceneOpensOverTheStreamBCancelsAndNothingElseGetsThrough() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        let focus = FocusModel()
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        #expect(controller.loader.phase == .opening && controller.loaderCancellable)
        // The other buttons are the loader's too: no menu opens from the remote, nothing moves
        #expect(StreamScreen.capture(.options, controller: controller, focus: focus, fromRemote: true, hasGamepad: false))
        #expect(!controller.menuOpen)
        // A touch is not the PC's trackpad and not the menu's swipe
        let area = StreamController.TouchArea(width: 2796, height: 1290, gestureInset: 63, scale: 3)
        controller.touch(1, .began, at: CGPoint(x: 1400, y: 1150), area: area, time: 0)
        controller.touch(1, .moved, at: CGPoint(x: 1400, y: 600), area: area, time: 0.1)
        #expect(!controller.menuOpen)
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus))
        await eventually { controller.phase == .ended }
        #expect(controller.phase == .ended)
        #expect(steps.quits == 0)
    }

    @Test func onceTheSceneIsOverBIsTheMenusAndNoLongerCancels() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
        #expect(!controller.loaderCancellable)
        await controller.cancelLoader()
        #expect(controller.phase == .streaming)
        #expect(steps.stops == 0)
    }

    /// A running stream on an iPhone 18 Pro Max in landscape (pixels): the home indicator keeps the bottom 21 points.
    private static let phone = StreamController.TouchArea(width: 2868, height: 1320, gestureInset: 63, scale: 3)

    private func runningStream(swipe: Bool = true) async -> StreamController {
        let steps = FakeSteps()
        let controller = StreamController(menuSwipe: swipe) { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
        return controller
    }

    @Test func aSwipeUpFromTheBandAboveTheBottomEdgeOpensTheMenu() async {
        let controller = await runningStream()
        let area = Self.phone
        // The band: from 82 % of the height down to the edge's strip, at least 24 points (72 px) even though the home
        // indicator keeps only 21 (63 px)
        let zone = area.swipeZone
        #expect(abs(zone.top - 1082.4) < 1e-6 && zone.bottom == CGFloat(1248))
        controller.touch(1, .began, at: CGPoint(x: 1400, y: 1200), area: area, time: 0)
        // 12 % of the height up (158.4 px) opens it, not before
        controller.touch(1, .moved, at: CGPoint(x: 1400, y: 1042), area: area, time: 0.05)
        #expect(!controller.menuOpen)
        controller.touch(1, .moved, at: CGPoint(x: 1420, y: 1040), area: area, time: 0.1)
        #expect(controller.menuOpen)
        controller.touch(1, .ended, at: CGPoint(x: 1420, y: 1040), area: area, time: 0.2)
        #expect(controller.menuOpen)
    }

    @Test func theLeftEdgeTheSystemStripAndASidewaysDragDoNotOpenIt() async {
        let controller = await runningStream()
        let area = Self.phone
        // The old left-edge swipe
        controller.touch(1, .began, at: CGPoint(x: 10, y: 600), area: area, time: 0)
        controller.touch(1, .moved, at: CGPoint(x: 900, y: 600), area: area, time: 0.1)
        controller.touch(1, .ended, at: CGPoint(x: 900, y: 600), area: area, time: 0.2)
        // A start in the home indicator's strip
        controller.touch(2, .began, at: CGPoint(x: 1400, y: 1300), area: area, time: 1)
        controller.touch(2, .moved, at: CGPoint(x: 1400, y: 500), area: area, time: 1.1)
        controller.touch(2, .ended, at: CGPoint(x: 1400, y: 500), area: area, time: 1.2)
        // More sideways than up
        controller.touch(3, .began, at: CGPoint(x: 1000, y: 1200), area: area, time: 2)
        controller.touch(3, .moved, at: CGPoint(x: 1400, y: 900), area: area, time: 2.1)
        controller.touch(3, .ended, at: CGPoint(x: 1400, y: 900), area: area, time: 2.2)
        #expect(!controller.menuOpen)
    }

    @Test func theProfileCanTurnTheSwipeOff() async {
        let controller = await runningStream(swipe: false)
        controller.touch(1, .began, at: CGPoint(x: 1400, y: 1200), area: Self.phone, time: 0)
        controller.touch(1, .moved, at: CGPoint(x: 1400, y: 700), area: Self.phone, time: 0.1)
        #expect(!controller.menuOpen)
    }

    @Test func aScreenWithoutAHomeIndicatorStillKeeps24PointsAtTheEdge() {
        let area = StreamController.TouchArea(width: 2420, height: 1668, gestureInset: 0, scale: 2)
        #expect(area.swipeZone.bottom == CGFloat(1668 - 48))
    }

    @Test func aNewAttemptHasAFreshLoader() async {
        let steps = FakeSteps()
        steps.connectFailure = .stageFailed(.rtspHandshake, errorCode: -408)
        var made = [FakeSteps]()
        let controller = StreamController {
            let next = made.isEmpty ? steps : FakeSteps()
            made.append(next)
            return next
        }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase != .connecting }
        controller.retry()
        #expect(controller.loader.phase == .connecting && controller.loaderCancellable)
    }
}

/// A tap outside the stream menu: the popover closes first, then the menu; the stream is never left and no click reaches the game.
@MainActor
@Suite struct StreamMenuOutsideTapTests {
    @Test func theNavigationClosesThePopoverBeforeTheMenu() {
        #expect(StreamMenuNavigation.afterOutsideTap(.main) == .closeMenu)
        #expect(StreamMenuNavigation.afterOutsideTap(.more) == .dismissPopover(PageExit(page: .main, focusTile: .more, focusRow: nil)))
        #expect(StreamMenuNavigation.afterOutsideTap(.keys) == .dismissPopover(PageExit(page: .main, focusTile: .more, focusRow: nil)))
    }

    @Test func twoTapsOutsideCloseThePopoverThenTheMenuAndTheStreamKeepsRunning() async {
        let steps = FakeSteps()
        let controller = StreamController { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        controller.loaderEnded()
        controller.tapOutside()
        #expect(!controller.menuOpen, "no menu: nothing to close")
        controller.openMenu()
        controller.openMenuPage(.more)
        #expect(controller.menu.isOpen)
        controller.tapOutside()
        #expect(controller.menuOpen && !controller.menu.isOpen, "the popover closes first")
        controller.tapOutside()
        #expect(!controller.menuOpen)
        #expect(controller.phase == .streaming)
        #expect(steps.stops == 0 && steps.quits == 0)
    }
}

/// The connected time of a stream goes to the playtime store (`PlaytimeTracker` of DELOS for Android).
@MainActor
@Suite struct StreamPlaytimeTests {
    /// A clock the test moves and the slices the tracker wrote.
    @MainActor private final class Ledger {
        var now = 1000.0
        var slices: [Double] = []
        var total: Double { slices.reduce(0, +) }
        lazy var tracker = PlaytimeTracker(clock: { [unowned self] in now }, sink: { [unowned self] in slices.append($0) })
    }

    private func streaming(_ ledger: Ledger, steps: FakeSteps = FakeSteps(), interval: Duration = .seconds(30)) async -> StreamController {
        let controller = StreamController(playtime: ledger.tracker, playtimeFlushInterval: interval) { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        steps.finishConnect()
        await eventually { controller.phase == .streaming }
        return controller
    }

    @Test func aNormalEndWritesTheConnectedTimeOnce() async {
        let ledger = Ledger()
        let controller = await streaming(ledger)
        ledger.now += 125
        await controller.leave(quit: false)
        #expect(ledger.total == 125)
        // Leaving again, dismissing and the screen closing add nothing
        ledger.now += 50
        await controller.leave(quit: false)
        controller.dismiss()
        #expect(ledger.slices == [125])
    }

    @Test func nothingIsRecordedBeforeTheFirstConnectedMoment() async {
        let ledger = Ledger()
        let steps = FakeSteps()
        steps.holdsLaunch = true
        let controller = StreamController(playtime: ledger.tracker) { steps }
        controller.start(display: iPhone)
        await eventually { steps.isLaunching }
        ledger.now += 40
        await controller.leave(quit: false)
        steps.finishLaunch()
        ledger.now += 40
        #expect(ledger.slices.isEmpty)
        #expect(!ledger.tracker.running)
    }

    @Test func aCancelWhileConnectingRecordsNothing() async {
        let ledger = Ledger()
        let steps = FakeSteps()
        let controller = StreamController(playtime: ledger.tracker) { steps }
        controller.start(display: iPhone)
        await eventually { steps.isConnecting }
        ledger.now += 20
        await controller.leave(quit: false)
        #expect(ledger.slices.isEmpty)
    }

    @Test func aFailedLaunchRecordsNothing() async {
        let ledger = Ledger()
        let steps = FakeSteps()
        steps.launchFailure = .denied
        let controller = StreamController(playtime: ledger.tracker) { steps }
        controller.start(display: iPhone)
        await eventually { controller.phase != .connecting }
        ledger.now += 20
        #expect(ledger.slices.isEmpty && !ledger.tracker.running)
    }

    @Test func theTimeIsFlushedWhileStreamingAndTheRestAtTheEnd() async {
        let ledger = Ledger()
        let controller = await streaming(ledger, interval: .milliseconds(5))
        ledger.now += 30
        await eventually { ledger.total == 30 }
        #expect(ledger.total == 30, "written while the stream still runs")
        ledger.now += 7
        await controller.leave(quit: false)
        #expect(ledger.total == 37)
        let written = ledger.slices.count
        try? await Task.sleep(for: .milliseconds(30))
        #expect(ledger.slices.count == written, "no flush after the end")
    }

    @Test func theBackgroundEndsTheTimeAndTheReturnCountsAgainFromTheNewConnection() async {
        let ledger = Ledger()
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController(playtime: ledger.tracker) {
            let steps = FakeSteps()
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps[0].isConnecting }
        made.steps[0].finishConnect()
        await eventually { controller.phase == .streaming }
        ledger.now += 60
        await controller.enteredBackground()?.value
        #expect(ledger.slices == [60])
        // Away from the app: no time
        ledger.now += 600
        controller.returnedToForeground()
        await eventually { made.steps.count == 2 && made.steps[1].isConnecting }
        ledger.now += 15
        #expect(ledger.slices == [60], "reconnecting is not counted")
        made.steps[1].finishConnect()
        await eventually { controller.phase == .streaming }
        ledger.now += 30
        await controller.leave(quit: false)
        #expect(ledger.slices == [60, 30])
    }

    @Test func aDroppedConnectionWritesTheTimeUpToIt() async {
        let ledger = Ledger()
        let steps = FakeSteps()
        let controller = await streaming(ledger, steps: steps)
        ledger.now += 90
        steps.continuation.yield(.terminated(.unexpectedEarlyTermination))
        await eventually { controller.phase != .streaming }
        #expect(ledger.slices == [90])
        ledger.now += 500
        await controller.leave(quit: false)
        #expect(ledger.slices == [90])
    }

    @Test func tryAgainCountsOnlyTheNewConnection() async {
        let ledger = Ledger()
        final class Made { var steps: [FakeSteps] = [] }
        let made = Made()
        let controller = StreamController(playtime: ledger.tracker) {
            let steps = FakeSteps()
            made.steps.append(steps)
            return steps
        }
        controller.start(display: iPhone)
        await eventually { made.steps[0].isConnecting }
        made.steps[0].finishConnect()
        await eventually { controller.phase == .streaming }
        ledger.now += 10
        made.steps[0].continuation.yield(.terminated(.unexpectedEarlyTermination))
        await eventually { controller.phase != .streaming }
        ledger.now += 100
        controller.retry()
        await eventually { made.steps.count == 2 && made.steps[1].isConnecting }
        made.steps[1].finishConnect()
        await eventually { controller.phase == .streaming }
        ledger.now += 5
        await controller.leave(quit: false)
        #expect(ledger.slices == [10, 5])
    }
}

/// When the stream screen wants the pointer locked (``PointerLock``, issue #17): only over the running stream.
@MainActor
@Suite struct StreamPointerCaptureTests {
    @Test func onlyTheRunningStreamWithNothingOverItTakesThePointer() {
        #expect(StreamContent.capturesPointer(phase: .streaming, menuOpen: false, loaderUp: false))
        #expect(!StreamContent.capturesPointer(phase: .streaming, menuOpen: true, loaderUp: false), "the stream menu")
        #expect(!StreamContent.capturesPointer(phase: .streaming, menuOpen: false, loaderUp: true), "the loader opening over the picture")
        #expect(!StreamContent.capturesPointer(phase: .connecting, menuOpen: false, loaderUp: true), "connecting, or back from the background")
        let result = ResultText(title: "t", sentence: "s", details: nil)
        for phase: StreamController.Phase in [.failed(result), .leaving("Disconnecting"), .ended] {
            #expect(!StreamContent.capturesPointer(phase: phase, menuOpen: false, loaderUp: false))
        }
    }
}
