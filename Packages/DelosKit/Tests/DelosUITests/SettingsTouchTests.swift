import CoreGraphics
import Foundation
import Testing
@testable import DelosUI

/// Touch on the settings rows (Android issue #92): what a tap does, the stepping, typing and holding of the slider popover, and where
/// the card of a row's popover lies.
@Suite struct RowTouchTests {
    private let toggle = SettingValue.toggle(true)
    private let choice = SettingValue.choice(label: "Auto", options: ["Auto", "H.264", "HEVC"], selected: 0)
    private let slider = SettingValue.slider(value: 60, range: 0...120, step: 10, divisor: 1, unit: " %")

    @Test func theFirstTapOnASwitchChoiceOrSliderOnlyFocusesIt() {
        for value in [toggle, choice, slider] {
            #expect(RowTouch.of(value, wasFocused: false, enabled: true) == .focusOnly)
        }
    }

    @Test func aTapOnTheFocusedRowChangesIt() {
        #expect(RowTouch.of(toggle, wasFocused: true, enabled: true) == .activate)
        #expect(RowTouch.of(choice, wasFocused: true, enabled: true) == .pick)
        #expect(RowTouch.of(slider, wasFocused: true, enabled: true) == .adjust)
    }

    @Test func aChoiceWithoutAPopoverStepsAndASliderWithoutOneWaitsForItsTrack() {
        #expect(RowTouch.of(choice, wasFocused: true, enabled: true, canPopup: false) == .activate)
        #expect(RowTouch.of(slider, wasFocused: true, enabled: true, canPopup: false) == .none)
    }

    @Test func aRowThatOpensSomethingOpensOnTheFirstTap() {
        #expect(RowTouch.of(.action(label: nil), wasFocused: false, enabled: true) == .activate)
        #expect(RowTouch.of(.appSettings(language: "English"), wasFocused: false, enabled: true) == .activate)
        #expect(RowTouch.of(.action(label: nil), wasFocused: false, enabled: false) == .error)
    }

    @Test func anUnavailableRowFocusesFirstThenSaysNo() {
        #expect(RowTouch.of(toggle, wasFocused: false, enabled: false) == .focusOnly)
        for value in [toggle, choice, slider] {
            #expect(RowTouch.of(value, wasFocused: true, enabled: false) == .error)
        }
    }

    @Test func anInfoRowDoesNothing() {
        #expect(RowTouch.of(.info("x"), wasFocused: false, enabled: true) == .none)
        #expect(RowTouch.of(.info("x"), wasFocused: true, enabled: true) == .none)
    }

    @Test func onlyChoicesWithOptionsAndSlidersHaveAPopover() {
        func row(_ value: SettingValue) -> SettingRow {
            SettingRow(id: "r", tab: .stream, section: "s", icon: "", label: "L", value: value, help: "")
        }
        #expect(RowPopupKind.of(row(choice)) == .options)
        #expect(RowPopupKind.of(row(slider)) == .slider)
        #expect(RowPopupKind.of(row(.choice(label: "", options: [], selected: nil))) == nil)
        #expect(RowPopupKind.of(row(toggle)) == nil)
        #expect(RowPopupKind.of(row(.action(label: nil))) == nil)
        #expect(RowPopupKind.of(row(.info("x"))) == nil)
    }
}

@Suite struct SliderSpecTests {
    /// The video bitrate: kbit/s on a 1 Mbit/s grid, read in Mbit/s.
    private let bitrate = SliderSpec(value: 40_000, min: 1_000, max: 150_000, step: 1_000, divisor: 1_000, unit: " Mbps")
    private let percent = SliderSpec(value: 60, min: 0, max: 120, step: 10, unit: " %")
    private let gyro = SliderSpec(value: 0, min: 0, max: 100, step: 5, unit: " %", minText: "Off")
    private let us = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")

    @Test func steppingMovesOneGridStepEitherWay() {
        #expect(bitrate.stepped(from: 40_000, by: 1) == 41_000)
        #expect(bitrate.stepped(from: 40_000, by: -1) == 39_000)
        #expect(bitrate.stepped(from: 40_000, by: 10) == 50_000)
    }

    @Test func steppingClampsAtBothEnds() {
        #expect(bitrate.stepped(from: 149_500, by: 1) == 150_000)
        #expect(bitrate.stepped(from: 150_000, by: 50) == 150_000)
        #expect(bitrate.stepped(from: 1_000, by: -1) == 1_000)
        #expect(bitrate.stepped(from: 3_000, by: -50) == 1_000)
        #expect(percent.stepped(from: Int.max, by: Int.max) == 120)
        #expect(percent.stepped(from: Int.min, by: Int.min) == 0)
    }

    @Test func aStoredValueBetweenStepsSnapsToTheGrid() {
        #expect(bitrate.stepped(from: 40_250, by: 1) == 41_000)
        #expect(bitrate.stepped(from: 40_250, by: 0) == 40_000)
        #expect(percent.snap(64) == 60)
        #expect(percent.snap(65) == 70)
        #expect(percent.snap(9_999) == 120)
        #expect(percent.snap(-50) == 0)
    }

    @Test func numberAndLabelReadInTheRowsUnit() {
        #expect(bitrate.numberText(40_000, locale: us) == "40")
        #expect(bitrate.numberText(37_500, locale: us) == "37.5")
        #expect(bitrate.numberText(37_500, locale: de) == "37,5")
        #expect(bitrate.label(40_000, locale: us) == "40 Mbps")
        #expect(percent.label(60, locale: us) == "60 %")
        #expect(gyro.label(0, locale: us) == "Off")
        #expect(gyro.label(5, locale: us) == "5 %")
    }

    @Test func typedMbitIsConvertedToKbit() {
        #expect(bitrate.parse("40") == 40_000)
        #expect(bitrate.parse(" 40 ") == 40_000)
        #expect(bitrate.parse("100") == 100_000)
    }

    @Test func typedDecimalsRoundToTheGridWithAPointOrAComma() {
        #expect(bitrate.parse("37.5") == 38_000)
        #expect(bitrate.parse("37,4") == 37_000)
        #expect(bitrate.parse("0.6") == 1_000)
    }

    @Test func typedValuesOutsideTheRangeAreClamped() {
        #expect(bitrate.parse("400") == 150_000)
        #expect(bitrate.parse("99999999999999999999") == 150_000)
        #expect(bitrate.parse("999999999999999999999999999999999999999999") == 150_000)
        #expect(bitrate.parse("0") == 1_000)
        #expect(bitrate.parse("-5") == 1_000)
        #expect(percent.parse("500") == 120)
    }

    @Test func aSliderWithoutADivisorTakesTheNumberAsIs() {
        #expect(percent.parse("55") == 60)
        #expect(percent.parse("54") == 50)
        #expect(percent.parse("0") == 0)
    }

    @Test func textThatIsNoNumberIsRejected() {
        for text in ["", "   ", "abc", ".", ",", "1 2", "4o", "Mbps", "--3", "1.2.3", "+", "-"] {
            #expect(bitrate.parse(text) == nil, "'\(text)'")
        }
    }

    @Test func onlyDigitsAndOneSeparatorCanBeTyped() {
        for text in ["", "125", "12.5", "12,"] { #expect(SliderSpec.typable(text), "'\(text)'") }
        for text in ["12.5.1", "12,5.1", "1a", "-3", "1 2"] { #expect(!SliderSpec.typable(text), "'\(text)'") }
    }

    @Test func aHeldButtonAcceleratesLikeAHeldKey() {
        let wide = SliderSpec(value: 5_000, min: 1_000, max: 1_000_000, step: 1_000, divisor: 1_000, unit: " Mbps")
        #expect(HoldRepeat.steps(wide, repeatCount: 1) == 1)
        #expect(HoldRepeat.steps(wide, repeatCount: 7) == 1)
        #expect(HoldRepeat.steps(wide, repeatCount: 8) == 5)
        #expect(HoldRepeat.steps(wide, repeatCount: 20) == 10)
        #expect(HoldRepeat.steps(wide, repeatCount: 35) == 24)
        #expect(HoldRepeat.steps(percent, repeatCount: 99) == 1)
    }

    @Test func holdingReachesTheEndExactlyAndNeverPassesIt() {
        let wide = SliderSpec(value: 5_000, min: 1_000, max: 1_000_000, step: 1_000, divisor: 1_000, unit: " Mbps")
        var value = 5_000
        var repeats = 0
        var presses = 0
        while value < wide.max, presses < 10_000 {
            let before = value
            repeats += 1
            value = wide.stepped(from: value, by: HoldRepeat.steps(wide, repeatCount: repeats))
            #expect(value >= before)
            #expect((value - wide.min) % wide.step == 0)
            presses += 1
        }
        #expect(value == wide.max)
        repeats = 0
        while value > wide.min, presses < 20_000 {
            repeats += 1
            value = wide.stepped(from: value, by: -HoldRepeat.steps(wide, repeatCount: repeats))
            #expect(value >= wide.min)
            presses += 1
        }
        #expect(value == wide.min)
    }

    @Test func theSliderModelAppliesOnlyChangesAndFollowsTheRow() async {
        await MainActor.run {
            var applied: [Int] = []
            let model = SliderPopupModel(spec: percent) { applied.append($0) }
            #expect(model.step(1))
            #expect(!model.apply(70), "the same value again is no change")
            #expect(model.apply(500))
            #expect(!model.step(1), "at the end")
            model.follow(30)
            #expect(model.value == 30)
            #expect(applied == [70, 120])
        }
    }
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

/// The card of a row's popover: vertically centered on the row, inside the stage's margins, its caret on the card's left edge pointing
/// into the row with the card to its right; flipped only where the right has no room (the same geometry as DELOS for Android).
@Suite struct RowPopoverLayoutTests {
    typealias G = RowPopoverLayout
    private let stage = CGSize(width: 1920, height: 1080)
    /// A row of the settings list: x 150..1200, 92 high, its middle at y 346.
    private let row = CGRect(x: 150, y: 300, width: 1050, height: 92)

    @Test func theCardIsCenteredOnTheRowAndItsCaretIsLevelWithTheRowsMiddle() {
        let p = G.slider(row: row, stage: stage)
        #expect(near(p.card.midY, row.midY))
        #expect(near(p.tip.y, row.midY))
        #expect(near(p.caretY, p.card.height / 2))
        #expect(near(p.card.height, G.sliderHeight) && near(p.card.width, G.sliderWidth))
        let o = G.options(row: row, count: 3, stage: stage)
        #expect(near(o.placement.card.midY, row.midY))
        #expect(near(o.placement.card.width, G.optionsWidth))
        #expect(near(o.placement.card.height, G.chrome + G.listHeight(count: 3)))
    }

    @Test func theCaretIsOnTheLeftEdgeLeftOfTheValueAndTheCardGrowsToTheRight() {
        let p = G.options(row: row, count: 3, stage: stage).placement
        #expect(!p.flipped)
        #expect(near(p.tip.x, row.maxX - G.valueInset))
        #expect(near(p.card.minX, p.tip.x + G.caretHeight))
        #expect(p.card.maxX <= stage.width - G.sideMargin)
    }

    @Test func aWideCardIsPulledLeftToEndBeforeTheStagesEdgeAndNeverPastTheRowsLeftEnd() {
        let p = G.slider(row: row, stage: stage)
        #expect(!p.flipped)
        #expect(near(p.card.maxX, stage.width - G.sideMargin))
        #expect(p.tip.x + G.caretHeight >= row.minX + G.minTipInset - 0.001)
        #expect(p.tip.x < row.maxX, "the tip is in the row")
    }

    @Test func theCardFlipsOnlyWhenTheRightHasNoRoom() {
        // A narrow stage and a row at its right end: the card does not fit to the right of the caret
        let narrow = CGSize(width: 1500, height: 1080)
        let wideRow = CGRect(x: 600, y: 300, width: 860, height: 92)
        let p = G.slider(row: wideRow, stage: narrow)
        #expect(p.flipped)
        // The tip is 120 px inside the row's right edge, the caret on the card's right edge
        #expect(near(p.tip.x, wideRow.maxX - G.flipTipInset))
        #expect(near(p.card.maxX + G.caretHeight, p.tip.x))
        #expect(near(p.card.width, G.sliderWidth))
        #expect(p.card.minX >= G.sideMargin)
        // With room on the right it does not
        #expect(!G.options(row: row, count: 3, stage: stage).placement.flipped)
    }

    @Test func whenNeitherSideHasRoomTheCardIsNarrowedLast() {
        let tiny = CGSize(width: 700, height: 1080)
        let r = CGRect(x: 24, y: 300, width: 650, height: 92)
        let p = G.slider(row: r, stage: tiny)
        #expect(p.card.width < G.sliderWidth)
        #expect(p.card.minX >= G.sideMargin - 0.001)
        #expect(p.card.maxX <= tiny.width - G.sideMargin + 0.001)
    }

    @Test func theCardStaysInsideTheMarginsAboveAndBelow() {
        let high = G.options(row: CGRect(x: 150, y: 100, width: 1050, height: 92), count: 4, stage: stage).placement
        #expect(near(high.card.minY, G.topMargin))
        // The row's middle (146) is above the card's reach: the caret goes as high as it may, never onto a rounded corner
        #expect(near(high.tip.y, high.card.minY + G.caretMinInset))
        let low = G.slider(row: CGRect(x: 150, y: 990, width: 1050, height: 92), stage: stage)
        #expect(near(low.card.maxY, stage.height - G.bottomMargin))
        #expect(low.tip.y >= low.card.minY + G.caretMinInset)
        #expect(low.tip.y <= low.card.maxY - G.caretMinInset + 0.001)
    }

    @Test func aLongListIsCutToTheRoomAndScrolls() {
        let o = G.options(row: row, count: 40, stage: stage)
        let room = stage.height - G.topMargin - G.bottomMargin
        #expect(near(o.placement.card.height, room))
        #expect(near(o.list, room - G.chrome))
        #expect(near(o.placement.card.minY, G.topMargin))
        #expect(o.list < G.listHeight(count: 40))
    }

    @Test func theTouchPartsAreSizedForAFinger() {
        // 96 stage px is 41 points at the smallest scale of a stage pixel, 59 at the iPad's
        for part in [G.touch, G.fieldHeight] {
            #expect(part * Stage.minPointsPerPixel >= 37)
        }
        #expect(near(G.sliderHeight, 2 * G.sliderPad + G.sliderTitle + G.sliderGap + G.fieldHeight + G.sliderGap + G.touch))
        #expect(near(G.sliderHeight, 300) && near(G.sliderWidth, 1040))
    }
}
