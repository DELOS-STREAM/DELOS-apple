import GameController
import Testing
@testable import DelosInput

/// One press is one command, whoever reports it and however the input kind and the keyboard's owner change around it: a
/// key's own repeat is no press, a key that came up can be pressed again, and the repeats are `MenuInput`'s alone.
@MainActor
@Suite(.serialized) struct MenuInputGatingTests {
    /// A `MenuInput` whose own repeats never fire: only presses and lifts are under test.
    private func input(_ log: Log) -> MenuInput {
        MenuInput(repeatAfter: .seconds(3600), repeatEvery: .seconds(3600)) { command, count in log.items.append((command, count)) }
    }

    final class Log {
        var items: [(MenuCommand, Int)] = []
        var commands: [MenuCommand] { items.map(\.0) }
    }

    @Test func aSecondDownOfTheSameKeyIsTheSystemsRepeatNotAPress() {
        let log = Log()
        let input = input(log)
        input.press(.down, from: "key down", input: .keyboard)
        // The keyboard's own repeat reaches the app as more "down" events of the key that is still down
        for _ in 0..<5 { input.press(.down, from: "key down", input: .keyboard) }
        #expect(log.commands == [.down])
        input.lift("key down")
        input.press(.down, from: "key down", input: .keyboard)
        #expect(log.commands == [.down, .down])
    }

    @Test func aKeyAndAButtonAreTwoSources() {
        let log = Log()
        let input = input(log)
        input.press(.accept, from: "key return", input: .keyboard)
        input.press(.accept, from: "pad A")
        #expect(log.commands == [.accept, .accept])
        input.lift("key return")
        input.lift("pad A")
    }

    @Test func aTurnOfTheStickIsOneCommandPerDirection() {
        let log = Log()
        let input = input(log)
        input.press(.right, from: "stick right")
        input.lift("stick right")
        input.press(.down, from: "stick down")
        #expect(log.commands == [.right, .down])
    }

    @Test func forgettingWhatIsDownLetsAKeyThatLostItsUpBePressedAgain() {
        let log = Log()
        let input = input(log)
        input.press(.right, from: "key right", input: .keyboard)
        // The app lost the keyboard (another app, a locked screen) and the "up" never came
        input.forgetDown()
        input.press(.right, from: "key right", input: .keyboard)
        #expect(log.commands == [.right, .right])
    }

    @Test func endingTheRepeatsKeepsTheKeyDownSoItsOwnRepeatIsStillNoPress() {
        let log = Log()
        let input = input(log)
        input.press(.down, from: "key down", input: .keyboard)
        // The stream menu opens while the key is held: the repeats end, but the key is still down
        input.cancelRepeats()
        input.press(.down, from: "key down", input: .keyboard)
        #expect(log.commands == [.down])
    }

    @Test func theKindOfInputFollowsRealPressesAndNotTheKeyboardsRepeat() {
        let glyphs = ControllerGlyphs.shared
        let before = glyphs.kind
        defer { glyphs.note(before) }
        let log = Log()
        let input = input(log)
        input.press(.down, from: "key down", input: .keyboard)
        #expect(glyphs.kind == .keyboard)
        // The player touches the screen while the key is still down: the key's repeats must not take the hints back
        glyphs.note(.touch)
        input.press(.down, from: "key down", input: .keyboard)
        #expect(glyphs.kind == .touch)
        input.lift("key down")
        // A fresh press of the key is the keyboard again
        input.press(.down, from: "key down", input: .keyboard)
        #expect(glyphs.kind == .keyboard)
        input.lift("key down")
    }

    @Test func onlyTheDirectionsRepeat() {
        for command in [MenuCommand.up, .down, .left, .right] { #expect(MenuInput.repeats(command)) }
        for command in [MenuCommand.accept, .back, .previousTab, .nextTab, .menu, .options, .toastAction] { #expect(!MenuInput.repeats(command)) }
    }

    @Test func aHeldDirectionRepeatsWithItsCountAndAnotherPressTakesTheRepeatsOver() async {
        let log = Log()
        let (stream, continuation) = AsyncStream<Int>.makeStream()
        let input = MenuInput(repeatAfter: .milliseconds(1), repeatEvery: .milliseconds(1)) { command, count in
            log.items.append((command, count))
            continuation.yield(count)
        }
        input.press(.right, from: "key right", input: .keyboard)
        // Wait for events, not for a time: the second repeat of the hold
        for await count in stream where count >= 2 { break }
        input.press(.up, from: "key up", input: .keyboard)
        // Up took the repeats over: from here on the commands are Up's
        for await count in stream where count >= 2 && log.commands.last == .up { break }
        input.lift("key up")
        input.lift("key right")
        continuation.finish()
        #expect(log.items.first?.0 == .right && log.items.first?.1 == 0)
        let afterTakeover = log.items.drop { $0.0 != .up }
        #expect(afterTakeover.allSatisfy { $0.0 == .up })
        #expect(afterTakeover.first?.1 == 0)
    }
}
