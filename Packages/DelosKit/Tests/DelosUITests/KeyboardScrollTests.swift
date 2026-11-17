import CoreGraphics
import Foundation
import GameController
import Testing
@testable import DelosInput
@testable import DelosUI

/// What the owner's iPad with a Magic Keyboard showed: the arrow keys moved the focus and the row scrolled twice. The
/// system's own scrolling is switched off in UIKit (``MenuKeys``); what is left is ours, and it must be exactly one focus
/// step and one scroll target for every press and every repeat of a hold.
@MainActor
final class LibraryRow {
    let model = FocusModel(initial: AnyHashable("c0"))
    let count: Int
    private(set) var index = 0
    /// What the screen does for each focus step, as `GameLibrary` does: one ``LibraryScroll/Step``.
    private(set) var targets: [LibraryScroll.Step] = []
    private(set) var focusSteps = 0
    private var pace = ScrollPace()
    /// The time of the command being handled (a clock the test drives).
    var now = Date(timeIntervalSince1970: 1000)

    init(count: Int) {
        self.count = count
        let ids = (0..<count).map { AnyHashable("c\($0)") }
        for index in 0..<count {
            model.register(
                ids[index], frame: CGRect(x: Double(index) * 100, y: 0, width: 80, height: 100),
                moves: LibraryWrap.moves(index: index, ids: ids), action: {})
        }
    }

    func handle(_ command: MenuCommand) {
        let before = index
        model.handle(command)
        guard let focused = model.focused as? String, let now = Int(focused.dropFirst()), now != before else { return }
        index = now
        focusSteps += 1
        targets.append(LibraryScroll.step(from: before, to: now, count: count, pace: pace.move(at: self.now)))
    }
}

@MainActor
@Suite struct KeyboardScrollTests {
    @Test func onePressIsOneFocusStepAndOneScrollTarget() {
        let row = LibraryRow(count: 8)
        let input = MenuInput { command, _ in row.handle(command) }
        input.press(.right, from: "key right")
        input.lift("key right")
        #expect(row.focusSteps == 1)
        #expect(row.targets == [.follow(to: 1, pace: .single)])
    }

    @Test func theKeyboardsOwnRepeatIsNotAnotherPress() {
        // The system repeats a held key as more "down" events without an "up": none of them is a press
        let row = LibraryRow(count: 8)
        let input = MenuInput(repeatAfter: .seconds(60), repeatEvery: .seconds(60)) { command, _ in row.handle(command) }
        for _ in 0..<12 { input.press(.right, from: "key right") }
        #expect(row.focusSteps == 1)
        #expect(row.targets.count == 1)
        input.lift("key right")
        // Up, then down again a moment later: a new press
        row.now.addTimeInterval(1)
        input.press(.right, from: "key right")
        #expect(row.focusSteps == 2)
        #expect(row.targets == [.follow(to: 1, pace: .single), .follow(to: 2, pace: .single)])
        input.lift("key right")
    }

    @Test func aHoldIsOneStepAndOneTargetPerRepeat() async throws {
        let row = LibraryRow(count: 40)
        var counts: [Int] = []
        var input: MenuInput?
        final class Flag: @unchecked Sendable { var on = false }
        let released = Flag()
        input = MenuInput(repeatAfter: .milliseconds(30), repeatEvery: .milliseconds(10)) { command, count in
            counts.append(count)
            // The clock of a real hold: the press, the first repeat 500 ms later, then one every 50 ms
            row.now = Date(timeIntervalSince1970: 1000 + (count == 0 ? 0 : 0.5 + 0.05 * Double(count - 1)))
            row.handle(command)
            // The keyboard's own repeats arrive meanwhile and change nothing
            if !released.on { input?.press(.right, from: "key right") }
        }
        input?.press(.right, from: "key right")
        // Wait for the repeats instead of a fixed time: a busy machine delays timers
        for _ in 0..<1000 where counts.count < 6 { try await Task.sleep(for: .milliseconds(10)) }
        released.on = true
        input?.lift("key right")
        let seen = counts.count
        #expect(seen >= 5)
        // The press is 0 and each repeat the next number: none is missing and none comes twice
        #expect(counts == Array(0..<seen))
        #expect(row.focusSteps == seen)
        #expect(row.targets.count == seen)
        // The press and the first repeat glide; the repeats after it are short steps
        #expect(row.targets.first == .follow(to: 1, pace: .single))
        #expect(row.targets[1] == .follow(to: 2, pace: .single))
        #expect(row.targets.dropFirst(2).allSatisfy { if case .follow(_, .held) = $0 { true } else { false } })
        // Up: it stops
        // A repeat already on its way may still land; after that it stays quiet
        try await Task.sleep(for: .milliseconds(100))
        let settled = counts.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(counts.count == settled)
    }

    @Test func aSecondKeyTakesTheRepeatsAndTheFirstKeysUpKeepsThem() async throws {
        var seen: [(MenuCommand, Int)] = []
        let input = MenuInput(repeatAfter: .milliseconds(20), repeatEvery: .milliseconds(10)) { command, count in
            seen.append((command, count))
        }
        input.press(.right, from: "key right")
        input.press(.down, from: "key down")
        // Right comes up while down is held: down goes on repeating
        input.lift("key right")
        try await Task.sleep(for: .milliseconds(120))
        input.lift("key down")
        #expect(seen.first?.0 == .right)
        #expect(seen.dropFirst().first?.0 == .down)
        #expect(seen.dropFirst().allSatisfy { $0.0 == .down })
        #expect(seen.dropFirst().map(\.1) == Array(0..<(seen.count - 1)))
    }

    @Test func aStickDirectionIsPressedOnceAndAnotherOneIsAnotherPress() {
        var seen: [MenuCommand] = []
        let input = MenuInput(repeatAfter: .seconds(60), repeatEvery: .seconds(60)) { command, _ in seen.append(command) }
        input.press(.right, from: "stick right")
        input.lift("stick right")
        input.press(.up, from: "stick up")
        input.press(.up, from: "stick up")
        input.lift("stick up")
        #expect(seen == [.right, .up])
    }

    @Test func forgettingWhatIsDownLetsTheKeyBePressedAgain() {
        var seen = 0
        let input = MenuInput(repeatAfter: .seconds(60), repeatEvery: .seconds(60)) { _, _ in seen += 1 }
        input.press(.accept, from: "key return")
        // The app lost the keyboard: the "up" never came
        input.forgetDown()
        input.press(.accept, from: "key return")
        #expect(seen == 2)
    }

    @Test func aWrapIsOneTargetToo() {
        let row = LibraryRow(count: 5)
        let input = MenuInput(repeatAfter: .seconds(60), repeatEvery: .seconds(60)) { command, _ in row.handle(command) }
        input.press(.left, from: "key left")
        #expect(row.focusSteps == 1)
        #expect(row.targets == [.wrap])
        #expect(row.index == 4)
    }
}

@Suite struct ScrollPaceTests {
    @Test func aSinglePressGlidesAndAFastSequenceStepsShort() {
        var pace = ScrollPace()
        let start = Date(timeIntervalSince1970: 0)
        #expect(pace.move(at: start) == .single)
        // A held key: the first repeat comes 500 ms after the press, the next ones every 50 ms
        #expect(pace.move(at: start.addingTimeInterval(0.5)) == .single)
        #expect(pace.move(at: start.addingTimeInterval(0.55)) == .held)
        #expect(pace.move(at: start.addingTimeInterval(0.60)) == .held)
        // A pause: a single press again
        #expect(pace.move(at: start.addingTimeInterval(1.5)) == .single)
    }

    @Test func aHeldMoveIsOneShortLinearStep() {
        var pace = ScrollPace()
        let start = Date(timeIntervalSince1970: 0)
        _ = pace.animation(.easeOut(duration: 0.3), at: start)
        #expect(pace.animation(.easeOut(duration: 0.3), at: start.addingTimeInterval(0.05)) == ScrollPace.heldStep)
        #expect(pace.animation(.easeOut(duration: 0.3), at: start.addingTimeInterval(2)) == .easeOut(duration: 0.3))
    }
}
