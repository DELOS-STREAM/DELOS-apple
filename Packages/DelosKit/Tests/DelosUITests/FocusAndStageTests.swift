import CoreGraphics
import DelosInput
import Testing
@testable import DelosUI

@Suite struct FocusGeometryTests {
    let current = CGRect(x: 100, y: 100, width: 100, height: 100)

    @Test func movesToTheItemInTheDirection() {
        let next = FocusGeometry.next(from: current, direction: .right, candidates: [
            "left": CGRect(x: -100, y: 100, width: 100, height: 100),
            "right": CGRect(x: 300, y: 100, width: 100, height: 100),
        ])
        #expect(next == "right")
    }

    @Test func prefersAnItemStraightAheadOverACloserOneOffToTheSide() {
        let next = FocusGeometry.next(from: current, direction: .right, candidates: [
            "ahead": CGRect(x: 500, y: 100, width: 100, height: 100),
            "diagonal": CGRect(x: 260, y: 300, width: 100, height: 100),
        ])
        #expect(next == "ahead")
    }

    @Test func staysWhenNothingLiesInTheDirection() {
        let next = FocusGeometry.next(from: current, direction: .up, candidates: [
            "right": CGRect(x: 300, y: 100, width: 100, height: 100),
        ])
        #expect(next == nil)
    }
}

@MainActor
@Suite struct FocusModelTests {
    @Test func commandsMoveTheFocusAndActivateTheFocusedItem() {
        let model = FocusModel(initial: AnyHashable("a"))
        var activated: [String] = []
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) { activated.append("a") }
        model.register("b", frame: CGRect(x: 50, y: 0, width: 10, height: 10)) { activated.append("b") }
        #expect(model.handle(.left) == false)
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("b"))
        #expect(model.handle(.accept))
        #expect(activated == ["b"])
        model.unregister("b")
        #expect(model.focused == AnyHashable("a"))
    }
}

@Suite struct StageTests {
    @Test func aWiderScreenWidensTheStage() {
        // iPhone 14 Pro Max in landscape: 932 × 430 points
        let stage = Stage(size: CGSize(width: 932, height: 430))
        #expect(abs(stage.height - 1080) < 1e-9)
        #expect(stage.width > 1920)
        #expect(abs(stage.px(1080) - 430) < 1e-9)
    }

    @Test func aTallerScreenHeightensTheStage() {
        // iPad Pro 13-inch in landscape: 1376 × 1032 points
        let stage = Stage(size: CGSize(width: 1376, height: 1032))
        #expect(abs(stage.width - 1920) < 1e-9)
        #expect(stage.height > 1080)
    }
}
