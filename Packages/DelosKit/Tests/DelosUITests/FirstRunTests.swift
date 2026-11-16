import CoreGraphics
import Foundation
import Testing
@testable import DelosUI

@Suite struct AvatarTests {
    @Test func everyAvatarImageDecodesAtItsFullSize() throws {
        // WebP through ImageIO, as on iOS and tvOS
        for avatar in Avatar.all {
            let image = try #require(AvatarImages.decode(avatar.asset), "\(avatar.asset).webp")
            #expect(image.width == 384 && image.height == 384, "\(avatar.asset)")
        }
    }

    @Test func theSetKeepsAndroidsOrder() {
        // A profile stores the index: the order is the one of DELOS for Android and only grows at the end
        #expect(Avatar.all.map(\.asset) == [
            "sailor", "voyager", "player", "fox", "spark", "calm", "knight", "robot",
            "cat", "wizard", "racer", "ghost", "owl", "hacker", "wolf", "dragon",
        ])
        #expect(Avatar.all.map(\.index) == Array(0..<16))
    }

    @Test func anUnknownIndexIsClamped() {
        #expect(Avatar.of(-1).asset == "sailor")
        #expect(Avatar.of(99).asset == "dragon")
    }

    @Test func everyAvatarHasItsImportedColors() throws {
        #expect(AvatarGradient.imported.count == 16)
        let fox = try #require(AvatarGradient.imported["fox"])
        // "#4a2f26" and "#201613"
        #expect(fox.c0 == RGBA(red: 0x4A / 255.0, green: 0x2F / 255.0, blue: 0x26 / 255.0))
        #expect(fox.c1 == RGBA(red: 0x20 / 255.0, green: 0x16 / 255.0, blue: 0x13 / 255.0))
        #expect(Avatar.of(3).gradient == fox)
    }

    @Test func invalidColorFilesAreRejected() {
        // Not an object, an entry that is not an object, a missing color, capitals, not #rrggbb
        for json in [##"[]"##, ##"{"fox": 3}"##, ##"{"fox": {"c0": "#4a2f26"}}"##, ##"{"fox": {"c0": "#4A2F26", "c1": "#201613"}}"##,
                     ##"{"fox": {"c0": "4a2f26a", "c1": "#201613"}}"##] {
            #expect(throws: AvatarGradient.Invalid.self, "\(json)") { try AvatarGradient.parse(Data(json.utf8)) }
        }
    }

    @Test func aMissingImageIsNotDecoded() {
        #expect(AvatarImages.decode("no-such-avatar") == nil)
    }
}

@MainActor
@Suite struct NavigatorTests {
    @Test func backReturnsToTheScreenBelowWithItsFocus() {
        let navigator = Navigator(root: .start, focus: "pair")
        navigator.focus.focus("settings")
        navigator.push(.profile, focus: "change-avatar")
        #expect(navigator.current == .profile)
        #expect(navigator.focus.focused == AnyHashable("change-avatar"))
        #expect(navigator.back())
        #expect(navigator.current == .start)
        #expect(navigator.focus.focused == AnyHashable("settings"))
        // The root stays; the system handles B there
        #expect(!navigator.back())
        #expect(navigator.current == .start)
    }

    @Test func resetReplacesTheWholeStack() {
        let navigator = Navigator(root: .boot)
        navigator.push(.createProfile(editing: false))
        navigator.reset(to: .start, focus: "pair")
        #expect(navigator.stack.map(\.screen) == [.start])
        #expect(!navigator.canGoBack)
    }

    @Test func theReturnThatEndsTypingDoesNotActivateTheFocusedItem() {
        let navigator = Navigator(root: .start)
        #expect(!navigator.swallowsAccept())
        navigator.isEditingText = true
        navigator.isEditingText = false
        #expect(navigator.swallowsAccept())
        #expect(!navigator.swallowsAccept(at: .now.addingTimeInterval(1)))
    }
}

@MainActor
@Suite struct FocusMoveTests {
    @Test func aRowsEndContinuesInTheNextRow() {
        // Two rows of two: "b" ends the first row and leads to "c" at the start of the second
        let model = FocusModel(initial: AnyHashable("b"))
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        model.register("b", frame: CGRect(x: 20, y: 0, width: 10, height: 10), moves: [.right: "c"]) {}
        model.register("c", frame: CGRect(x: 0, y: 20, width: 10, height: 10), moves: [.left: "b"]) {}
        model.register("d", frame: CGRect(x: 20, y: 20, width: 10, height: 10)) {}
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("c"))
        #expect(model.handle(.left))
        #expect(model.focused == AnyHashable("b"))
        // Directions without a move stay spatial
        #expect(model.handle(.down))
        #expect(model.focused == AnyHashable("d"))
    }

    @Test func aMoveToAnItemThatIsGoneFallsBackToGeometry() {
        let model = FocusModel(initial: AnyHashable("a"))
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10), moves: [.right: "gone"]) {}
        model.register("b", frame: CGRect(x: 20, y: 0, width: 10, height: 10)) {}
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("b"))
    }
}

@Suite struct ProfileStringTests {
    @Test func theSignedInLineCountsTheProfiles() {
        let one = L("profile_signed_in", "iPad", 1)
        let two = L("profile_signed_in", "iPad", 2)
        #expect(one.contains("iPad"))
        #expect(one.contains("1"))
        #expect(two.contains("2"))
        // The plural forms differ in English: "profile" and "profiles"
        #expect(one != two.replacingOccurrences(of: "2", with: "1"))
    }

    @Test func theGreetingNamesTheProfile() {
        #expect(L("devices_start_greeting", "Ann").contains("Ann"))
    }
}
