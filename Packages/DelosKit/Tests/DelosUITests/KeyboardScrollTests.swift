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
        targets.append(LibraryScroll.step(from: before, to: now, count: count))
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
        #expect(row.targets == [.follow(to: 1)])
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
        input.press(.right, from: "key right")
        #expect(row.focusSteps == 2)
        #expect(row.targets == [.follow(to: 1), .follow(to: 2)])
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
        // Every step, the press and each repeat, is the same retargeted glide to the next cover
        #expect(row.targets == (1...seen).map { .follow(to: $0) })
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

/// The glide of a focus-driven scroll (R2-15): SwiftUI's animated scroll started every new target from rest after a frame
/// without movement, so a held arrow hopped one cover per step at 20 Hz. The glide's spring keeps its speed.
@Suite struct GlideSpringTests {
    /// The positions of a glide over [distance] from rest, stepped at 120 Hz for [seconds].
    private func run(_ pace: GlideSpring.Pace, distance: Double, seconds: Double) -> [Double] {
        var spring = GlideSpring(pace: pace)
        spring.retarget(distance: distance)
        var position = 0.0, positions: [Double] = []
        for _ in 0..<Int(seconds * 120) {
            position += spring.step(1.0 / 120)
            positions.append(position)
        }
        return positions
    }

    @Test func aStepOfTheLibraryEasesInAndLandsExactlyWithinItsSettleTime() {
        let positions = run(LibraryScroll.pace, distance: 400, seconds: 0.5)
        // It starts from rest: the first frame moves under 2 % of the step, and nothing ever goes back or beyond
        #expect(positions[0] > 0 && positions[0] < 8)
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(positions.allSatisfy { $0 <= 400 })
        // About Android's 200 ms ease-out: 90 % after 167 ms, within 2 % at 250 ms, landed exactly by 400 ms
        #expect(abs(positions[19] - 360) < 8)
        #expect(positions[29] > 391)
        #expect(abs(positions[47] - 400) < 1e-9)
    }

    @Test func aHeldArrowIsOneGlideWithoutAStopAtAnyStep() {
        // The press, then a repeat every 50 ms, each one cover (400 points) further
        let repeats = (1...10).map { (0.05 * Double($0), 400.0) }
        var spring = GlideSpring(pace: LibraryScroll.pace)
        spring.retarget(distance: 400)
        var position = 0.0, target = 400.0, moves: [Double] = []
        for frame in 0..<72 {
            let time = Double(frame) / 120
            if let step = repeats.first(where: { abs($0.0 - time) < 1e-9 }) {
                target += step.1
                spring.retarget(distance: target - position)
            }
            let move = spring.step(1.0 / 120)
            position += move
            moves.append(move)
        }
        // Every frame of the hold moves the row forward; past the first frames the speed stays within a narrow band
        #expect(moves.prefix(66).allSatisfy { $0 > 0 })
        let steady = moves[24..<60]
        #expect(steady.max()! / steady.min()! < 1.6)
    }

    @Test func aRetargetKeepsTheSpeed() {
        var spring = GlideSpring(pace: .list)
        spring.retarget(distance: 300)
        for _ in 0..<6 { _ = spring.step(1.0 / 120) }
        let before = spring.step(1.0 / 120)
        spring.retarget(distance: spring.remaining + 300)
        let after = spring.step(1.0 / 120)
        // The frame after the new target moves at least as far as the one before: no stop, no restart from rest
        #expect(after >= before)
    }

    @Test func aFastRetargetCloseByBrakesInsteadOfOvershooting() {
        var spring = GlideSpring(pace: .list)
        spring.retarget(distance: 600)
        for _ in 0..<20 { _ = spring.step(1.0 / 120) }
        // A new target just ahead while the glide is fast
        spring.retarget(distance: 5)
        var travelled = 0.0
        for _ in 0..<240 { travelled += spring.step(1.0 / 120) }
        #expect(abs(travelled - 5) < 0.01)
        #expect(!spring.active)
    }

    @Test func centeringKeepsTheItemInTheMiddleWithinTheContent() {
        let geometry = GlideGeometry(offset: 100, maxOffset: 500)
        // An item at 700…800 of a viewport spanning 0…1000: 250 further
        #expect(geometry.centering(itemStart: 700, itemEnd: 800, viewStart: 0, viewEnd: 1000) == 350)
        // Never before the start nor past the end
        #expect(geometry.centering(itemStart: 0, itemEnd: 50, viewStart: 0, viewEnd: 1000) == 0)
        #expect(geometry.centering(itemStart: 1900, itemEnd: 2000, viewStart: 0, viewEnd: 1000) == 500)
    }
}
