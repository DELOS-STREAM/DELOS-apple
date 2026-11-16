import CoreGraphics
import DelosCore
import Foundation
import Testing
@testable import DelosInput

@MainActor
private final class FakeBackend: PointerLockBackend {
    private(set) var calls: [String] = []
    func lock() { calls.append("lock") }
    func unlock() { calls.append("unlock") }
}

@MainActor
@Suite struct PointerLockTests {
    @Test func locksOnlyWhileTheStreamWantsItAndTheAppCanHaveIt() {
        let backend = FakeBackend()
        let lock = PointerLock(backend: backend)
        lock.setWanted(true)
        #expect(!lock.isLocked && backend.calls.isEmpty, "the window is not key yet")
        lock.setEligible(true)
        #expect(lock.isLocked && backend.calls == ["lock"])
        lock.setWanted(false)
        #expect(!lock.isLocked && backend.calls == ["lock", "unlock"])
    }

    @Test func anotherAppOrWindowTakingOverFreesThePointerAndReturningLocksItAgain() {
        let backend = FakeBackend()
        let lock = PointerLock(backend: backend)
        lock.setEligible(true)
        lock.setWanted(true)
        lock.setEligible(false)
        #expect(!lock.isLocked)
        lock.setEligible(true)
        #expect(lock.isLocked)
        #expect(backend.calls == ["lock", "unlock", "lock"])
    }

    @Test func repeatingAStateDoesNotLockTwice() {
        let backend = FakeBackend()
        let lock = PointerLock(backend: backend)
        lock.setEligible(true)
        for _ in 0..<3 { lock.setWanted(true) }
        for _ in 0..<3 { lock.setEligible(true) }
        #expect(backend.calls == ["lock"])
    }

    @Test func releaseGivesThePointerBackForGood() {
        let backend = FakeBackend()
        let lock = PointerLock(backend: backend)
        lock.setEligible(true)
        lock.setWanted(true)
        lock.release()
        #expect(!lock.isLocked && !lock.wanted)
        // The window staying key does not lock it again
        lock.setEligible(false)
        lock.setEligible(true)
        #expect(backend.calls == ["lock", "unlock"])
    }

    @Test func theParkingPointIsTheMiddleOfTheWindowInDisplayCoordinates() {
        // A window 400 × 200 at (100, 300) of a 1000-point-high main screen: Cocoa counts y up, Core Graphics down
        let frame = CGRect(x: 100, y: 300, width: 400, height: 200)
        let point = PointerLockGeometry.parkingPoint(windowFrame: frame, mainScreenHeight: 1000)
        #expect(point == CGPoint(x: 300, y: 600))
        // A window above the main screen (a second display) has a negative y in Core Graphics
        let above = CGRect(x: 0, y: 1000, width: 100, height: 100)
        #expect(PointerLockGeometry.parkingPoint(windowFrame: above, mainScreenHeight: 1000).y == -50)
    }
}

@Suite struct MenuKeyShortcutTests {
    private let leftControl = 0xE0, leftShift = 0xE1, leftOption = 0xE2, rightControl = 0xE4, rightShift = 0xE5
    private let rightOption = 0xE6

    @Test func mWithControlOptionAndShiftCompletesTheChord() {
        #expect(MenuKeyShortcut.completesChord(usage: 0x10, held: [leftControl, leftOption, leftShift]))
        #expect(MenuKeyShortcut.completesChord(usage: 0x10, held: [rightControl, rightOption, rightShift]))
        #expect(MenuKeyShortcut.completesChord(usage: 0x10, held: [leftControl, rightOption, leftShift, 0x04]))
        // 0x10 is M in the HID usage table (A is 0x04)
        #expect(MenuKeyShortcut.chordKey == 0x04 + 12)
    }

    @Test func anIncompleteChordOrAnotherKeyDoesNot() {
        #expect(!MenuKeyShortcut.completesChord(usage: 0x10, held: []))
        #expect(!MenuKeyShortcut.completesChord(usage: 0x10, held: [leftControl, leftOption]))
        #expect(!MenuKeyShortcut.completesChord(usage: 0x10, held: [leftControl, leftShift]))
        #expect(!MenuKeyShortcut.completesChord(usage: 0x10, held: [leftOption, leftShift]))
        #expect(!MenuKeyShortcut.completesChord(usage: 0x11, held: [leftControl, leftOption, leftShift]))
        // The Command key (0xE3) is the PC's Windows key and no part of the chord
        #expect(!MenuKeyShortcut.completesChord(usage: 0x10, held: [0xE3, leftOption, leftShift]))
    }
}

/// Records what reaches the PC.
private final class RecordingSink: StreamInputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [(code: Int16, pressed: Bool)] = []

    var sentKeys: [(code: Int16, pressed: Bool)] { lock.withLock { keys } }

    func sendControllerArrival(
        number: UInt8, activeGamepadMask: UInt16, type: ControllerType, supportedButtons: ControllerButtons,
        capabilities: ControllerCapabilities
    ) throws(InputError) {}
    func sendController(number: UInt8, activeGamepadMask: UInt16, state: ControllerState) throws(InputError) {}
    func sendMouseMove(deltaX: Int16, deltaY: Int16) throws(InputError) {}
    func sendMouseButton(_ button: MouseButton, pressed: Bool) throws(InputError) {}
    func sendKey(code: Int16, pressed: Bool, modifiers: KeyModifiers, nonNormalized: Bool) throws(InputError) {
        lock.withLock { keys.append((code, pressed)) }
    }
    func sendHighResolutionScroll(amount: Int16) throws(InputError) {}
    func sendHighResolutionHorizontalScroll(amount: Int16) throws(InputError) {}
}

@MainActor
@Suite struct KeyboardMenuTests {
    private func key(_ usage: Int) -> Int16 { KeyboardMapping.keyCode(KeyboardMapping.virtualKey(hidUsage: usage)!) }

    @Test func theChordOpensTheMenuKeepsTheMFromThePCAndLetsGoOfTheModifiers() {
        let sink = RecordingSink()
        var opened = 0
        let input = GameInput(sink: sink) { opened += 1 }
        for usage in [0xE0, 0xE2, 0xE1] { input.key(usage, pressed: true) }
        #expect(sink.sentKeys.count == 3, "the modifiers go to the PC as they are pressed")
        input.key(0x10, pressed: true)
        #expect(opened == 1)
        #expect(!sink.sentKeys.contains { $0.code == key(0x10) }, "the M never reached the PC")
        // The menu pauses the input, as `StreamController.openMenu` does, which lets go of the modifiers
        input.paused = true
        let released = sink.sentKeys.filter { !$0.pressed }.map(\.code)
        #expect(Set(released) == [key(0xE0), key(0xE2), key(0xE1)])
        // Letting go of M afterwards sends nothing
        let count = sink.sentKeys.count
        input.key(0x10, pressed: false)
        #expect(sink.sentKeys.count == count)
    }

    @MainActor
    private final class Holder {
        weak var input: GameInput?
    }

    @Test func aQuickEscapeReachesThePCAndOpensNothing() async throws {
        let sink = RecordingSink()
        var opened = 0
        let input = GameInput(sink: sink, escapeHold: .milliseconds(150)) { opened += 1 }
        input.key(0x29, pressed: true)
        input.key(0x29, pressed: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(opened == 0)
        #expect(sink.sentKeys.map(\.pressed) == [true, false])
        #expect(sink.sentKeys.allSatisfy { $0.code == key(0x29) })
    }

    @Test func aHeldEscapeOpensTheMenuOnceAndThePauseLetsGoOfIt() async throws {
        let sink = RecordingSink()
        var opened = 0
        let holder = Holder()
        let input = GameInput(sink: sink, escapeHold: .milliseconds(100)) {
            opened += 1
            holder.input?.paused = true
        }
        holder.input = input
        input.key(0x29, pressed: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(opened == 1)
        #expect(sink.sentKeys.map(\.pressed) == [true, false], "the PC saw Escape go down and, with the menu, up")
        input.key(0x29, pressed: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened == 1)
    }

    @Test func nothingOpensWhilePaused() async throws {
        let sink = RecordingSink()
        var opened = 0
        let input = GameInput(sink: sink, escapeHold: .milliseconds(50)) { opened += 1 }
        input.paused = true
        input.key(0x29, pressed: true)
        for usage in [0xE0, 0xE2, 0xE1, 0x10] { input.key(usage, pressed: true) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened == 0 && sink.sentKeys.isEmpty)
    }
}
