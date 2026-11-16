import CoreGraphics
import SwiftUI
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

/// Cases from StagePlannerTest in DELOS for Android, plus the owner's Apple devices.
@Suite struct StageTests {
    @Test func theOdinKeepsTheFullStage() {
        // AYN Odin 2 Portal: 1920 × 1080 px at 2.306 px per dp
        let stage = Stage(size: CGSize(width: 1920 / 2.306, height: 1080 / 2.306))
        #expect(stage.width == 1920 && stage.height == 1080)
        #expect(abs(stage.scale - 0.4336) < 0.0001)
        #expect(stage.shape == .standard)
    }

    @Test func aSmallWindowKeepsTheLegibilityFloorAndGetsFewerPixels() {
        let stage = Stage(size: CGSize(width: 800, height: 450))
        #expect(stage.scale == Stage.minPointsPerPixel)
        #expect(abs(stage.width - 800 / 0.43) < 0.01 && abs(stage.height - 450 / 0.43) < 0.01)
        #expect(stage.shape == .standard)
    }

    @Test func iPhone14ProMaxInLandscapeIsAWideStageAtTheFloor() {
        let stage = Stage(size: CGSize(width: 932, height: 430))
        #expect(stage.scale == Stage.minPointsPerPixel)
        #expect(abs(stage.height - 430 / 0.43) < 0.01)
        #expect(stage.shape == .wide)
        #expect(abs(stage.px(1000) - 430) < 1e-9)
    }

    @Test func iPadPro13InLandscapeIsATallStage() {
        let stage = Stage(size: CGSize(width: 1376, height: 1032))
        #expect(stage.width == 1920)
        #expect(stage.height > 1080)
        #expect(stage.shape == .tall)
    }

    @Test func shapesFollowTheAspect() {
        #expect(Stage(size: CGSize(width: 1024, height: 768)).height == 1440)
        #expect(Stage(size: CGSize(width: 1024, height: 768)).shape == .tall)
        #expect(Stage(size: CGSize(width: 1000, height: 625)).shape == .tall)
        #expect(Stage(size: CGSize(width: 1000, height: 1000)).shape == .compact)
        #expect(Stage(size: CGSize(width: 1000, height: 800)).shape == .compact)
        #expect(Stage(size: CGSize(width: 1100, height: 470)).shape == .wide)
        #expect(Stage.classify(width: 1920, height: 1056) == .standard)
        #expect(Stage.classify(width: 1976, height: 1080) == .standard)
        #expect(Stage.classify(width: 2100, height: 1080) == .wide)
    }

    @Test func theSafeAreaIsInStagePixels() {
        let stage = Stage(size: CGSize(width: 932, height: 430), safeArea: EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59))
        #expect(abs(stage.safe.leading - 59 / 0.43) < 1e-9)
        #expect(abs(stage.safe.bottom - 21 / 0.43) < 1e-9)
    }
}
