import DelosCore
import DelosData
@testable import DelosHost
import DelosInput
import Foundation
import Synchronization
import Testing
@testable import DelosUI

/// A PC's clipboard command that records what it was sent.
final class FakeClipboardHost: ClipboardHost {
    let remote: Mutex<String>
    let sent = Mutex<[String]>([])
    let failure: HostError?
    let supported: Bool
    var clipboardURL: String { "https://pc:47984/actions/clipboard" }

    init(remote: String = "from the PC", failure: HostError? = nil, supported: Bool = true) {
        self.remote = Mutex(remote)
        self.failure = failure
        self.supported = supported
    }

    func clipboard() async throws -> String {
        if let failure { throw failure }
        return remote.withLock { $0 }
    }

    func sendClipboard(_ text: String) async throws -> Bool {
        if let failure { throw failure }
        sent.withLock { $0.append(text) }
        return supported
    }
}

@MainActor
final class ToastRecorder {
    var shown: [(String, ToastKind)] = []
    var running = true
    func show(_ text: String, _ kind: ToastKind) { shown.append((text, kind)) }
}

/// `StreamClipboardSyncTest.java` of DELOS for Android, against a clipboard in memory and a fake PC.
@MainActor
@Suite struct ClipboardSyncTests {
    let toasts = ToastRecorder()

    func sync(
        _ pasteboard: MemoryPasteboard, host: FakeClipboardHost = FakeClipboardHost(), options: ClipboardSync.Options = .init()
    ) -> ClipboardSync {
        ClipboardSync(options: options, host: host, pasteboard: pasteboard) { [toasts] in toasts.show($0, $1) }
    }

    @Test func anEmptyClipboardHasNoContent() {
        let sync = sync(MemoryPasteboard())
        #expect(sync.content(force: false) == nil)
        #expect(sync.content(force: true) == nil)
    }

    @Test func aClipIsReadOnceThenMarkedUnlessForced() {
        let pasteboard = MemoryPasteboard(items: [.init(text: "hello")])
        let sync = sync(pasteboard)
        #expect(sync.content(force: false) == "hello")
        #expect(pasteboard.items == [.init(text: "hello", own: true)])
        #expect(sync.content(force: false) == nil)
        #expect(sync.content(force: true) == "hello")
    }

    @Test func aClipDelosPutThereIsNotSentBackUnlessForced() {
        let sync = sync(MemoryPasteboard(items: [.init(text: "from host", own: true)]))
        #expect(sync.content(force: false) == nil)
        #expect(sync.content(force: true) == "from host")
    }

    @Test func aClipWithoutTextHasNoContentButIsMarked() {
        let pasteboard = MemoryPasteboard(items: [.init(text: nil), .init(text: "second")])
        #expect(sync(pasteboard).content(force: false) == nil)
        // Android's clone keeps the first item only
        #expect(pasteboard.items == [.init(text: nil, own: true)])
    }

    @Test func smartSyncSendsWhenTheStreamGainsFocusAndOnlyWhenConnected() async {
        let host = FakeClipboardHost()
        let pasteboard = MemoryPasteboard(items: [.init(text: "hello")])
        let off = sync(pasteboard, host: host)
        #expect(off.handleFocusChange(true, connected: true) == nil, "smart sync is off by default")

        let sync = sync(pasteboard, host: host, options: .init(smartSync: true))
        #expect(sync.handleFocusChange(true, connected: false) == nil)
        await sync.handleFocusChange(true, connected: true)?.value
        #expect(host.sent.withLock { $0 } == ["hello"])
        #expect(toasts.shown.map(\.0) == [L("send_clipboard_success")])
        #expect(toasts.shown.map(\.1) == [.success])
        // Already sent: the clip has the mark now
        #expect(sync.handleFocusChange(true, connected: true) == nil)
    }

    @Test func losingFocusAndDisconnectingFetchTheHostsClipboardWithSmartSync() async {
        let host = FakeClipboardHost(remote: "copied on the PC")
        let pasteboard = MemoryPasteboard(items: [.init(text: "local")])
        #expect(sync(pasteboard, host: host).disconnecting() == nil)

        let sync = sync(pasteboard, host: host, options: .init(smartSync: true, hideContent: false))
        await sync.handleFocusChange(false, connected: true)?.value
        #expect(pasteboard.items == [.init(text: "copied on the PC", own: true, concealed: false)])
        host.remote.withLock { $0 = "later" }
        await sync.disconnecting()?.value
        #expect(pasteboard.items == [.init(text: "later", own: true, concealed: false)])
        #expect(toasts.shown.map(\.0) == [L("get_clipboard_success"), L("get_clipboard_success")])
    }

    @Test func theHostsClipIsConcealedWhileHideContentIsOn() async {
        let pasteboard = MemoryPasteboard()
        await sync(pasteboard).get().value
        #expect(pasteboard.items == [.init(text: "from the PC", own: true, concealed: true)])
    }

    @Test func sendingForcedSendsAClipDelosMarked() async {
        let host = FakeClipboardHost()
        let sync = sync(MemoryPasteboard(items: [.init(text: "mine", own: true)]), host: host)
        #expect(sync.send(force: false) == nil)
        await sync.send(force: true)?.value
        #expect(host.sent.withLock { $0 } == ["mine"])
    }

    @Test func aHostWithoutClipboardSupportIsAWarning() async {
        let sync = sync(MemoryPasteboard(items: [.init(text: "x")]), host: FakeClipboardHost(supported: false))
        await sync.send(force: true)?.value
        #expect(toasts.shown.map(\.0) == [L("clipboard_sync_unsupported")])
        #expect(toasts.shown.map(\.1) == [.warning])
    }

    @Test func failuresNameTheReasonAsAndroidsMessagesDo() async {
        let missing = sync(MemoryPasteboard(items: [.init(text: "x")]), host: FakeClipboardHost(failure: .httpStatus(404)))
        await missing.send(force: true)?.value
        await missing.get().value
        let refused = sync(MemoryPasteboard(), host: FakeClipboardHost(failure: .hostStatus(code: 503, message: "Busy")))
        await refused.get().value
        #expect(toasts.shown.map(\.0) == [
            L("send_clipboard_failed") + "https://pc:47984/actions/clipboard",
            L("get_clipboard_failed") + "https://pc:47984/actions/clipboard",
            L("get_clipboard_failed") + "Host PC returned error: Busy (Error code: 503)",
        ])
        #expect(toasts.shown.allSatisfy { $0.1 == .error })
    }

    @Test func withoutToastsTheTransfersAreSilent() async {
        let pasteboard = MemoryPasteboard(items: [.init(text: "x")])
        let sync = sync(pasteboard, options: .init(toast: false))
        await sync.send(force: true)?.value
        await sync.get().value
        #expect(toasts.shown.isEmpty)
        #expect(pasteboard.items.first?.text == "from the PC")
    }

    @Test func theSwitchesAreReadFromTheProfile() {
        var settings = StreamSettings()
        #expect(ClipboardSync.Options(settings) == .init(smartSync: false, toast: true, hideContent: true))
        settings.set(.smartClipboardSync, .bool(true))
        settings.set(.smartClipboardSyncToast, .bool(false))
        settings.set(.hideClipboardContent, .bool(false))
        #expect(ClipboardSync.Options(settings) == .init(smartSync: true, toast: false, hideContent: false))
    }
}

/// `applyBitrate` (StreamMenu.kt:308-331) and its texts (`StreamMenuLayoutTest`).
@MainActor
@Suite struct StreamBitrateTests {
    @Test func theAppliedBitrateIsAcceptedOrLimited() async {
        let bitrate = StreamBitrate()
        await bitrate.apply(50000, connected: { true }, change: { $0 })?.value
        #expect(bitrate.result == .accepted(kbps: 50000))
        #expect(bitrate.appliedKbps == 50000)
        #expect(bitrate.statusText == L("stream_menu_bitrate_accepted", 50))
        await bitrate.apply(150_000, connected: { true }, change: { _ in 80000 })?.value
        #expect(bitrate.result == .limited(kbps: 80000))
        #expect(bitrate.statusText == L("stream_menu_bitrate_limited", 80))
        #expect(bitrate.failureText == nil)
    }

    @Test func aStreamThatDoesNotRunFailsAtOnce() {
        let bitrate = StreamBitrate()
        #expect(bitrate.apply(50000, connected: { false }, change: { $0 }) == nil)
        #expect(bitrate.result == .failed(.notConnected))
        #expect(bitrate.statusText == L("stream_menu_bitrate_failed"))
        #expect(bitrate.failureText == L("stream_menu_bitrate_not_connected"))
    }

    @Test func oneChangeRunsAtATimeAndSaysSo() async {
        let bitrate = StreamBitrate()
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let first = bitrate.apply(50000, connected: { true }) { kbps in
            for await _ in gate { break }
            return kbps
        }
        #expect(bitrate.busy)
        #expect(bitrate.statusText == L("stream_menu_bitrate_applying"))
        #expect(bitrate.apply(60000, connected: { true }, change: { $0 }) == nil)
        open.yield()
        await first?.value
        #expect(!bitrate.busy)
        #expect(bitrate.result == .accepted(kbps: 50000))
    }

    @Test func anAnswerAfterTheStreamEndedIsDropped() async {
        let bitrate = StreamBitrate()
        let state = ToastRecorder()
        await bitrate.apply(50000, connected: { state.running }, change: { kbps in
            state.running = false
            return kbps
        })?.value
        #expect(bitrate.result == nil)
        #expect(bitrate.appliedKbps == nil)
        #expect(!bitrate.busy)
    }

    @Test func failuresAreToldApartAsOnAndroid() async {
        let cases: [(any Error, BitrateFailure)] = [
            (HostError.httpStatus(404), .unsupported),
            (HostError.hostStatus(code: 403, message: "Forbidden"), .denied),
            (HostError.hostStatus(code: 500, message: "Encoder busy"), .rejected("Host PC returned error: Encoder busy (Error code: 500)")),
            (HostError.timedOut, .unconfirmed),
            (HostError.malformedResponse("no bitrate"), .unconfirmed),
            (HostError.certificateMismatch, .unconfirmed),
            (RuntimeBitrateOutOfRange(kbps: 1), .unconfirmed),
        ]
        for (error, failure) in cases {
            let bitrate = StreamBitrate()
            await bitrate.apply(50000, connected: { true }, change: { _ in throw error })?.value
            #expect(bitrate.result == .failed(failure))
        }
    }

    @Test func aRejectionsDetailIsCutToFit() {
        #expect(BitrateFailure.rejected(nil) == BitrateFailure(name: "stream_menu_bitrate_rejected", detail: nil))
        #expect(BitrateFailure.rejected(" \n ") == BitrateFailure(name: "stream_menu_bitrate_rejected", detail: nil))
        #expect(BitrateFailure.rejected("a\nb").detail == "a b")
        let long = BitrateFailure.rejected(String(repeating: "x", count: 500))
        #expect(long.detail == String(repeating: "x", count: 59) + "\u{2026}")
        #expect(long.text.count < 100)
        #expect(BitrateFailure.rejected(String(repeating: "x", count: 60)).detail?.count == 60)
    }
}

/// A stream that is up at once, with a PC that answers the clipboard and bitrate commands.
@MainActor
final class CommandSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    var input: (any StreamInputSink)? { nil }
    let clipboard: ClipboardSync?
    private(set) var asked: [Int] = []

    init(clipboard: ClipboardSync) {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.clipboard = clipboard
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {}
    func connect() async throws(StreamError) { continuation.yield(.connectionStarted) }
    func stop() async { continuation.finish() }
    func quitApp() async -> Bool { true }
    func setRuntimeBitrate(_ kbps: Int) async throws -> Int {
        asked.append(kbps)
        return min(kbps, 100_000)
    }
}

@MainActor
@Suite struct StreamCommandsControllerTests {
    let host = FakeClipboardHost(remote: "from the PC")
    let pasteboard = MemoryPasteboard(items: [.init(text: "on this device")])

    func streaming(smartSync: Bool) async -> (StreamController, CommandSteps) {
        let sync = ClipboardSync(options: .init(smartSync: smartSync), host: host, pasteboard: pasteboard) { _, _ in }
        let steps = CommandSteps(clipboard: sync)
        let controller = StreamController { steps }
        controller.start(display: DisplayInfo(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60))
        for _ in 0..<500 where controller.phase != .streaming { try? await Task.sleep(for: .milliseconds(2)) }
        return (controller, steps)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func smartSyncSendsOnceTheStreamRunsAndFetchesOnDisconnect() async {
        let (controller, _) = await streaming(smartSync: true)
        await settle { host.sent.withLock { !$0.isEmpty } }
        #expect(host.sent.withLock { $0 } == ["on this device"])
        await controller.leave(quit: false)
        await settle { pasteboard.items.first?.text == "from the PC" }
        #expect(pasteboard.items == [.init(text: "from the PC", own: true, concealed: true)])
    }

    @Test func quittingDoesNotFetchAndWithoutSmartSyncNothingMoves() async {
        let (quitting, _) = await streaming(smartSync: true)
        await settle { host.sent.withLock { !$0.isEmpty } }
        await quitting.leave(quit: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pasteboard.items.first?.text == "on this device")

        pasteboard.items = [.init(text: "new")]
        let (controller, _) = await streaming(smartSync: false)
        await controller.leave(quit: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.sent.withLock { $0 } == ["on this device"])
        #expect(pasteboard.items == [.init(text: "new")])
    }

    @Test func theMenusClipboardActionsAlwaysTransfer() async {
        let (controller, _) = await streaming(smartSync: false)
        controller.sendClipboard()
        await settle { host.sent.withLock { !$0.isEmpty } }
        #expect(host.sent.withLock { $0 } == ["on this device"])
        // Send again: the clip DELOS marked goes too, the player asked for it
        controller.sendClipboard()
        await settle { host.sent.withLock { $0.count == 2 } }
        #expect(host.sent.withLock { $0 } == ["on this device", "on this device"])
        controller.getClipboard()
        await settle { pasteboard.items.first?.text == "from the PC" }
        #expect(pasteboard.items.first?.text == "from the PC")
    }

    @Test func applyAsksThePCWhileTheStreamRuns() async {
        let (controller, steps) = await streaming(smartSync: false)
        controller.applyBitrate(150_000)
        await settle { !controller.bitrate.busy }
        #expect(steps.asked == [150_000])
        #expect(controller.bitrate.result == .limited(kbps: 100_000))
        await controller.leave(quit: false)
        controller.applyBitrate(50000)
        #expect(controller.bitrate.result == .failed(.notConnected))
        #expect(steps.asked == [150_000])
    }
}
