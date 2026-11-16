import GameController
import Testing
@testable import DelosInput

@Suite struct MenuInputTests {
    @Test func theStickFiresOncePerPush() {
        // Below the press threshold: nothing
        #expect(MenuInput.stickCommand(x: 0.4, y: 0, previous: nil) == nil)
        // Past it: the direction; held there, the same direction (no new command)
        #expect(MenuInput.stickCommand(x: 0.8, y: 0.1, previous: nil) == .right)
        #expect(MenuInput.stickCommand(x: 0.4, y: 0, previous: .right) == .right)
        // Back inside the release threshold: released
        #expect(MenuInput.stickCommand(x: 0.2, y: 0, previous: .right) == nil)
    }

    @Test func theLargerAxisWinsAndUpIsPositive() {
        #expect(MenuInput.stickCommand(x: 0.3, y: 0.9, previous: nil) == .up)
        #expect(MenuInput.stickCommand(x: -0.3, y: -0.9, previous: nil) == .down)
        #expect(MenuInput.stickCommand(x: -0.9, y: 0.6, previous: nil) == .left)
    }

    @Test func keysMapToCommands() {
        #expect(MenuInput.keyCommand(.upArrow) == .up)
        #expect(MenuInput.keyCommand(.returnOrEnter) == .accept)
        #expect(MenuInput.keyCommand(.escape) == .back)
        #expect(MenuInput.keyCommand(.keyA) == nil)
    }
}
