import DelosCore
import DelosInput
import Foundation
import Testing
@testable import DelosUI

/// Records what the menu sends to the PC.
private final class RecordingSink: StreamInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var keyEvents: [(code: Int16, pressed: Bool)] = []
    private var commands: [UInt8] = []
    private var texts: [String] = []

    var keys: [(code: Int16, pressed: Bool)] { lock.withLock { keyEvents } }
    var serverCommands: [UInt8] { lock.withLock { commands } }
    var typed: [String] { lock.withLock { texts } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {}
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {
        lock.withLock { keyEvents.append((code, pressed)) }
    }
    func sendText(_ text: String) throws(InputError) { lock.withLock { texts.append(text) } }
    func sendServerCommand(_ id: UInt8) throws(InputError) { lock.withLock { commands.append(id) } }
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
}

/// A stream that is up at once.
@MainActor
private final class RunningSteps: StreamSteps {
    let pcName = "Gaming-PC"
    let appName = "Desktop"
    let events: AsyncStream<StreamEvent>
    private let continuation: AsyncStream<StreamEvent>.Continuation
    let sink = RecordingSink()
    var input: (any StreamInputSink)? { sink }
    var serverCommands: [String] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
    }

    func launch(display: DisplayInfo) async throws(LaunchFailure) {}
    func connect() async throws(StreamError) { continuation.yield(.connectionStarted) }
    func stop() async { continuation.finish() }
    func quitApp() async -> Bool { true }
}

@MainActor
private final class FakeBrightness: ScreenBrightness {
    var percent = 62
    private(set) var original: Int?
    private(set) var restored = 0

    func set(_ percent: Int) {
        if original == nil { original = self.percent }
        self.percent = percent
    }

    func restore() {
        restored += 1
        if let original { percent = original }
        original = nil
    }
}

private let screen = DisplayInfo(pixelWidth: 2048, pixelHeight: 2732, maxFramesPerSecond: 120)
private let phone = StreamMenuCapabilities(keyboard: true, brightness: true)

@MainActor
private func streaming(
    capabilities: StreamMenuCapabilities = phone, brightness: FakeBrightness? = nil, commands: [String] = []
) async -> (StreamController, RunningSteps) {
    let steps = RunningSteps()
    steps.serverCommands = commands
    let controller = StreamController(capabilities: capabilities, brightness: brightness) { steps }
    controller.start(display: screen)
    for _ in 0..<500 where controller.phase != .streaming { try? await Task.sleep(for: .milliseconds(2)) }
    return (controller, steps)
}

@MainActor
@Suite struct StreamMenuControllerTests {
    private let later = Date.now.addingTimeInterval(1)

    @Test func theTilesAreTheDevicesAndBrightnessNeedsADeviceToSetItOn() async {
        let (phoneController, _) = await streaming(brightness: FakeBrightness())
        #expect(phoneController.capabilities.tiles == [.resume, .keyboard, .overlay, .brightness, .more, .disconnect, .quit])
        // Brightness is a tile only where there is a screen to set it on
        let (withoutScreen, _) = await streaming(brightness: nil)
        #expect(withoutScreen.capabilities.tiles == [.resume, .keyboard, .overlay, .more, .disconnect, .quit])
        let (desktop, _) = await streaming(capabilities: StreamMenuCapabilities(keyboard: false, brightness: false))
        #expect(desktop.capabilities.tiles == [.resume, .overlay, .more, .disconnect, .quit])
    }

    @Test func aPageOpensFromItsTileAndItsOwnTileClosesIt() async {
        let (controller, _) = await streaming()
        controller.openMenuPage(.more)
        #expect(controller.menu.page == .main, "no page while the menu is closed")
        controller.openMenu()
        controller.openMenuPage(.more)
        #expect(controller.menu.page == .more && controller.menu.isOpen)
        // The focus starts on the page's first row; the popover has a focus of its own
        #expect(controller.menu.focus.focused == AnyHashable(StreamMenuState.rowID(MenuRowID.keys.rawValue)))
        controller.openMenuPage(.more)
        #expect(controller.menu.page == .main && controller.menuOpen, "the same tile again closes the popover, not the menu")
    }

    @Test func anotherTilesPageReplacesTheOpenOneAndMorphsTheCard() async {
        let (controller, _) = await streaming(brightness: FakeBrightness())
        controller.openMenu()
        controller.openMenuPage(.more)
        #expect(!controller.menu.morph)
        controller.openMenuPage(.brightness)
        #expect(controller.menu.page == .brightness && controller.menu.morph)
        #expect(controller.menu.shownPage == .brightness)
    }

    @Test func bGoesToTheRowThatOpenedThePageThenToTheTileThenResumes() async {
        let (controller, _) = await streaming()
        controller.openMenu()
        controller.openMenuPage(.more)
        controller.menu.open(.keys, focusing: StreamMenuState.pillID("0"))
        #expect(controller.menu.page == .keys)
        controller.menuBack()
        #expect(controller.menu.page == .more)
        #expect(controller.menu.focus.focused == AnyHashable(StreamMenuState.rowID(MenuRowID.keys.rawValue)))
        controller.menuBack()
        #expect(controller.menu.page == .main && controller.menuOpen)
        controller.menuBack()
        #expect(!controller.menuOpen)
    }

    @Test func aTapOutsideClosesThePopoverOnlyAndNeverResumes() async {
        let (controller, _) = await streaming()
        controller.openMenu()
        controller.dismissPopover()
        #expect(controller.menuOpen, "no popover: nothing to close, the stream is not resumed")
        controller.openMenuPage(.more)
        controller.dismissPopover()
        #expect(controller.menu.page == .main && controller.menuOpen)
    }

    @Test func theMenuClosingTakesItsPageWithIt() async {
        let (controller, _) = await streaming()
        controller.openMenu()
        controller.openMenuPage(.more)
        controller.closeMenu()
        #expect(controller.menu.page == .main && !controller.menuOpen)
    }

    @Test func theBrightnessSliderStepsByFiveWithinItsRangeAndAcceleratesNever() async {
        let brightness = FakeBrightness()
        let (controller, _) = await streaming(brightness: brightness)
        // The device's 62 % starts on the slider's grid
        #expect(controller.brightnessPercent == 60)
        controller.openMenu()
        controller.openMenuPage(.brightness)
        #expect(controller.adjustFocusedRow(1))
        #expect(controller.brightnessPercent == 65 && brightness.percent == 65)
        #expect(controller.adjustFocusedRow(-1, repeatCount: 50))
        #expect(controller.brightnessPercent == 60, "a 19-step slider moves one step per repeat, however long the key is held")
        for _ in 0..<20 { controller.adjustFocusedRow(-1) }
        #expect(controller.brightnessPercent == 5)
        for _ in 0..<30 { controller.adjustFocusedRow(1) }
        #expect(controller.brightnessPercent == 100)
    }

    @Test func leftAndRightAdjustNothingOnAnActionRow() async {
        let (controller, _) = await streaming()
        controller.openMenu()
        controller.openMenuPage(.more)
        #expect(!controller.adjustFocusedRow(1))
    }

    @Test func theSlidersAccelerationFollowsItsRange() {
        let row = StreamMenuRow(
            id: "bitrate", icon: "", label: "", value: .slider(value: 20_000, range: 1000...1_000_000, step: 1000, unit: ""),
            help: "", activate: {}, set: { _ in })
        #expect(row.acceleration(repeatCount: 0) == 1 && row.acceleration(repeatCount: 8) == 5)
        // At most a fortieth of the range (999 steps: 24), so a held key crosses it in about a second
        #expect(row.acceleration(repeatCount: 20) == 10 && row.acceleration(repeatCount: 40) == 24)
        #expect(row.stepped(1, steps: 5) == 25_000)
        let small = StreamMenuRow(
            id: "brightness", icon: "", label: "", value: .slider(value: 50, range: 5...100, step: 5, unit: " %"), help: "", activate: {}, set: { _ in })
        #expect(small.acceleration(repeatCount: 40) == 1)
        #expect(small.stepped(1) == 55 && small.stepped(-1) == 45)
        let top = StreamMenuRow(
            id: "brightness", icon: "", label: "", value: .slider(value: 100, range: 5...100, step: 5, unit: " %"), help: "", activate: {}, set: { _ in })
        #expect(top.stepped(1) == 100)
    }

    @Test func theBrightnessIsGivenBackWhenTheAppLeavesAndSetAgainOnReturn() async {
        let brightness = FakeBrightness()
        let (controller, _) = await streaming(brightness: brightness)
        controller.setBrightness(30)
        #expect(brightness.percent == 30)
        _ = controller.enteredBackground()
        #expect(brightness.percent == 62 && brightness.restored == 1)
        controller.returnedToForeground()
        #expect(brightness.percent == 30)
        controller.restoreBrightness()
        #expect(brightness.percent == 62)
    }

    @Test func theKeyboardTileClosesTheMenuAndTogglesTheKeyboard() async {
        let (controller, _) = await streaming()
        controller.openMenu()
        controller.toggleKeyboard()
        #expect(!controller.menuOpen && controller.keyboardShown)
        controller.openMenu()
        controller.toggleKeyboard()
        #expect(!controller.keyboardShown)
        // The system hid it
        controller.openMenu()
        controller.toggleKeyboard()
        controller.keyboardDismissed()
        #expect(!controller.keyboardShown)
        let (desktop, _) = await streaming(capabilities: StreamMenuCapabilities(keyboard: false, brightness: false))
        desktop.toggleKeyboard()
        #expect(!desktop.keyboardShown)
    }

    @Test func aKeyCombinationClosesTheMenuAndReachesThePC() async {
        let (controller, steps) = await streaming()
        controller.openMenu()
        controller.send(SpecialKeys.taskManager)
        #expect(!controller.menuOpen)
        #expect(steps.sink.keys.count == 6)
        #expect(steps.sink.keys.map(\.pressed) == [true, true, true, false, false, false])
    }

    @Test func aServerCommandClosesTheMenuAndRunsByItsPosition() async {
        let (controller, steps) = await streaming(commands: ["Steam", "Restart"])
        controller.openMenu()
        controller.openMenuPage(.more)
        controller.runServerCommand(1)
        #expect(!controller.menuOpen)
        #expect(steps.sink.serverCommands == [1])
    }

    @Test func typedTextGoesAsTextAndReturnTabAndBackspaceAsKeys() async {
        let (controller, steps) = await streaming()
        controller.typed("ab\ncd")
        #expect(steps.sink.typed == ["ab", "cd"])
        #expect(steps.sink.keys.count == 2, "Return pressed and released")
        controller.typedBackspace()
        #expect(steps.sink.keys.count == 4)
    }

    @Test func theKeyboardGoesAwayWhenTheStreamStopsRunning() async {
        let (controller, _) = await streaming()
        controller.toggleKeyboard()
        #expect(controller.keyboardShown)
        await controller.leave(quit: false)
        #expect(!controller.keyboardShown, "not over the exit scene or the result")
    }

    @Test func thePagesHaveTheContentOfTheMenusRows() async {
        let long = "A very long command name that goes on and on forever"
        let (controller, _) = await streaming(brightness: FakeBrightness(), commands: ["Steam", long])
        guard case let .rows(more) = controller.menuContent(.more) else { Issue.record("More has rows"); return }
        #expect(more.map(\.id) == ["more-keys", "more-commands", "more-task-manager"])
        guard case let .pills(keys, _) = controller.menuContent(.keys) else { Issue.record("Keys has pills"); return }
        #expect(keys.count == 14 && keys.first?.label == L("game_menu_send_keys_esc"))
        #expect(keys.first?.help == L("stream_help_format_keys", L("game_menu_send_keys_esc")))
        guard case let .pills(commands, empty) = controller.menuContent(.commands) else { Issue.record("Commands has pills"); return }
        #expect(commands.map(\.label) == ["Steam", long] && empty == nil)
        #expect(commands[1].help == L("stream_help_format_command", String(long.prefix(35)) + "\u{2026}"))
        let (none, _) = await streaming()
        guard case let .pills(noCommands, text) = none.menuContent(.commands) else { Issue.record("Commands has pills"); return }
        #expect(noCommands.isEmpty && text == L("stream_menu_no_commands"))
    }

    // MARK: Controller input

    @Test func withAPageOpenTheCommandsGoToThePopoverNotTheDock() async {
        let (controller, steps) = await streaming()
        let focus = FocusModel(initial: BarItem.more.id)
        controller.openMenu()
        controller.openMenuPage(.more)
        let ready = Date.now.addingTimeInterval(1)
        // The commands are consumed by the popover: the dock's focus stays on the tile that opened the page
        #expect(StreamScreen.capture(.down, controller: controller, focus: focus, at: ready))
        #expect(focus.focused == AnyHashable(BarItem.more.id))
        #expect(controller.menu.page == .more)
        // B goes up one level: the dock, the menu stays; B again resumes
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus, at: ready))
        #expect(controller.menu.page == .main && controller.menuOpen)
        #expect(StreamScreen.capture(.back, controller: controller, focus: focus, at: ready))
        #expect(!controller.menuOpen)
        #expect(steps.sink.keys.isEmpty)
    }

    @Test func theAThatOpenedAPageIsNotAChoiceInIt() async {
        let (controller, steps) = await streaming()
        let focus = FocusModel()
        controller.openMenu()
        let task = StreamMenuState.rowID(MenuRowID.taskManager.rawValue)
        controller.menu.open(.more, focusing: task)
        controller.menu.focus.register(AnyHashable(task), frame: CGRect(x: 0, y: 0, width: 1, height: 1)) {
            if case let .rows(rows) = controller.menuContent(.more) { rows[2].activate() }
        }
        // A within the page's grace is the press that opened it: the Task manager row does not run
        #expect(StreamScreen.capture(.accept, controller: controller, focus: focus, at: .now))
        #expect(controller.menuOpen && steps.sink.keys.isEmpty)
        // A later press is
        #expect(StreamScreen.capture(.accept, controller: controller, focus: focus, at: .now.addingTimeInterval(1)))
        #expect(!controller.menuOpen && steps.sink.keys.count == 6)
    }

    @Test func leftAndRightStepTheFocusedSliderAndTheDocksRepeatsStayOut() async {
        let brightness = FakeBrightness()
        let (controller, _) = await streaming(brightness: brightness)
        let focus = FocusModel()
        controller.openMenu()
        // The dock: a repeat of a held direction never reaches the menu
        #expect(StreamScreen.capture(.right, controller: controller, focus: focus, repeatCount: 3, at: later))
        controller.openMenuPage(.brightness)
        #expect(StreamScreen.capture(.right, controller: controller, focus: focus, repeatCount: 0, at: later))
        #expect(controller.brightnessPercent == 65)
        #expect(StreamScreen.capture(.right, controller: controller, focus: focus, repeatCount: 4, at: later))
        #expect(controller.brightnessPercent == 70)
        #expect(StreamScreen.capture(.left, controller: controller, focus: focus, repeatCount: 0, at: later))
        #expect(controller.brightnessPercent == 65)
    }
}
