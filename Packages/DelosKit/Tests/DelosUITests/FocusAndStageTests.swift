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
    @Test func commandsMoveTheFocusAndActivateTheFocusedItem() async {
        let model = FocusModel(initial: AnyHashable("a"))
        var activated: [String] = []
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) { activated.append("a") }
        model.register("b", frame: CGRect(x: 50, y: 0, width: 10, height: 10)) { activated.append("b") }
        #expect(model.handle(.left) == false)
        #expect(model.handle(.right))
        #expect(model.focused == AnyHashable("b"))
        #expect(model.handle(.accept))
        #expect(activated == ["b"])
        // The focused item goes away while another stays: the focus moves on once the layout has settled
        model.unregister("b")
        await Task.yield()
        #expect(model.focused == AnyHashable("a"))
    }

    @Test func aScreenThatLeavesKeepsItsFocusForTheWayBack() async {
        let model = FocusModel(initial: AnyHashable("b"))
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        model.register("b", frame: CGRect(x: 50, y: 0, width: 10, height: 10)) {}
        // Every item of the screen unregisters as it goes, the focused one first
        model.unregister("b")
        model.unregister("a")
        await Task.yield()
        #expect(model.focused == AnyHashable("b"))
        // When the screen is back its items register again, and the focus is where it was
        model.register("a", frame: CGRect(x: 0, y: 0, width: 10, height: 10)) {}
        model.register("b", frame: CGRect(x: 50, y: 0, width: 10, height: 10)) {}
        #expect(model.focused == AnyHashable("b"))
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

@Suite struct TVStageTests {
    @Test func theTVTitleSafeAreaRaisesTheSystemOnesAndNothingElse() {
        let system = EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)
        let safe = Stage.safeArea(system: system, minimum: Stage.tvTitleSafeArea)
        #expect(safe.top == 60 && safe.bottom == 60 && safe.leading == 90 && safe.trailing == 90)
        #expect(Stage.safeArea(system: EdgeInsets(top: 0, leading: 59, bottom: 0, trailing: 0), minimum: EdgeInsets()).leading == 59)
        // A 1080p and a 4K Apple TV both give the app 1920 × 1080 points: one stage pixel is one point
        let stage = Stage(size: CGSize(width: 1920, height: 1080), safeArea: safe, minimumText: Stage.tvMinimumText)
        #expect(stage.scale == 1 && stage.safe.leading == 90)
    }

    @Test func captionsAreRaisedToTheTVMinimumAndLargerTextIsKept() {
        let tv = Stage(size: CGSize(width: 1920, height: 1080), minimumText: Stage.tvMinimumText)
        #expect(tv.tpx(16) == 24 && tv.tpx(26) == 26)
        #expect(Stage(size: CGSize(width: 1920, height: 1080), minimumText: 0).tpx(16) == 16)
    }

    @Test func aWiredConnectionShowsNoWiFiIconOnlyWhenTold() {
        #expect(WifiStatus(satisfied: true, usesWifi: false, wired: true).icon == nil)
        #expect(WifiStatus(satisfied: true, usesWifi: false).icon == Symbols.wifiOff)
    }

    @Test func theTVCommandsAreTheOnesTheSystemHasNoEventFor() {
        #expect(MenuInput.tvCommands == [.menu, .options, .toastAction, .previousTab, .nextTab])
    }
}
