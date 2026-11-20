import CoreGraphics
import SwiftUI
import Testing
@testable import DelosUI

/// The numbers Settings takes from DELOS for Android: the list's scroll, the tab row's place, the pill's springs, the cost chips
/// and the search.
@Suite struct SettingsParityTests {
    @Test func theListScrollsOnlyWhenTheFocusedRowLeavesItsMargins() {
        // A row well inside the viewport (72 above, 110 under): no scroll
        #expect(SettingsScrollMotion.target(rowTop: 300, rowBottom: 392, current: 0, viewport: 700, maxOffset: 900, before: 72, after: 110) == nil)
        // A row whose bottom plus the 110 margin passes the viewport: scrolls just that far
        #expect(SettingsScrollMotion.target(rowTop: 600, rowBottom: 692, current: 0, viewport: 700, maxOffset: 900, before: 72, after: 110) == 102)
        // A row above the 72 margin: scrolls back up to it
        #expect(SettingsScrollMotion.target(rowTop: 200, rowBottom: 292, current: 300, viewport: 700, maxOffset: 900, before: 72, after: 110) == 128)
        // Never beyond the content
        #expect(SettingsScrollMotion.target(rowTop: 1500, rowBottom: 1592, current: 0, viewport: 700, maxOffset: 900, before: 72, after: 110) == 900)
        #expect(SettingsScrollMotion.target(rowTop: 20, rowBottom: 100, current: 0, viewport: 700, maxOffset: 900, before: 72, after: 110) == nil)
    }

    @Test func theScrollSettlesInSixHundredToNineHundredFiftyMilliseconds() {
        #expect(SettingsScrollMotion.settleMillis(distance: 90) == 600)
        #expect(SettingsScrollMotion.settleMillis(distance: 700) == 950)
        #expect(SettingsScrollMotion.settleMillis(distance: 2000) == 950)
        #expect(abs(SettingsScrollMotion.settleMillis(distance: 395) - 775) < 0.001)
    }

    @Test func aCentredTabRowStaysCentredWhileItFitsTheStage() {
        // 16:9: 1650 wide, centred on 1920
        let wide = TabRowLayout.place(stageWidth: 1920, rowWidth: 1650, outset: 10, left: 150, right: 1770, spill: true)
        #expect(wide == TabRowLayout.Placement(x: 135, width: 1650, scrolls: false))
    }

    @Test func aCompactTabRowGoesFlushRightWhenCentredItWouldRunIntoTheSearchCircle() {
        // Room 48...(900 - 64 - 26 = 810): a row 600 wide centred (150...750 visible 160...740) fits
        #expect(TabRowLayout.place(stageWidth: 900, rowWidth: 600, outset: 10, left: 48, right: 810).x == 150)
        // 700 wide: centred it would end at 900 - 100... 700 centred x = 100, visible right 790 <= 810 + 6 so it stays
        #expect(TabRowLayout.place(stageWidth: 900, rowWidth: 700, outset: 10, left: 48, right: 810).x == 100)
        // 780 wide: centred its right end passes 810 by more than the slack: flush right at 810 - 780 + 10
        let tight = TabRowLayout.place(stageWidth: 900, rowWidth: 780, outset: 10, left: 48, right: 810)
        #expect(tight.x == 40 && !tight.scrolls)
        // Wider than the room: one row that scrolls inside it
        let wider = TabRowLayout.place(stageWidth: 900, rowWidth: 900, outset: 10, left: 48, right: 810)
        #expect(wider.scrolls && wider.x == 38 && wider.width == 782)
    }

    @Test func thePillsEdgeInTheDirectionOfTravelIsTheStifferSpring() {
        #expect(SelectionPillMotion.travelsRight(fromLeft: 0, fromRight: 100, toLeft: 200, toRight: 300))
        #expect(!SelectionPillMotion.travelsRight(fromLeft: 200, fromRight: 300, toLeft: 0, toRight: 100))
        // A pill that stays put counts as rightwards
        #expect(SelectionPillMotion.travelsRight(fromLeft: 0, fromRight: 100, toLeft: 0, toRight: 100))
    }

    @Test func aDockLeavesRoomForThreeTallRows() {
        func stage(_ w: Double, _ h: Double) -> Stage { Stage(size: CGSize(width: w, height: h)) }
        #expect(SettingsLayout.tallRow(stage(1920, 1080)) == 120)
        // At a larger interface scale the two lines of a row with chips are taller than 120
        let large = Stage(size: CGSize(width: 1920, height: 1080), textScale: 1.3)
        #expect(SettingsLayout.tallRow(large) == max(120, 64.2 * 1.3 + 28))
    }

    @Test func aCompactMarginKeepsTheSameRoomAtBothSidesOfACutout() {
        let notch = Stage(size: CGSize(width: 390, height: 844), safeArea: EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 60))
        #expect(SettingsLayout.margin(notch) == 48 + 60 / notch.scale)
    }

    @Test func theCostChipsFollowTheValuesInEffect() {
        let ctx = ImpactContext(height: 1080, fps: 60, bitrateMbps: 40, codec: "auto", hdr: false, pacing: "phase-lock")
        #expect(settingImpact(id: StreamSettingsForm.resolution, context: ctx) == SettingImpact(gpu: .low, latency: .low, network: .low))
        #expect(settingImpact(id: StreamSettingsForm.frameRate, context: ctx) == SettingImpact(gpu: .low, latency: .medium, network: .low))
        #expect(settingImpact(id: StreamSettingsForm.bitrate, context: ctx) == SettingImpact(gpu: .none, latency: .low, network: .low))
        #expect(settingImpact(id: StreamSettingsForm.codec, context: ctx) == SettingImpact(gpu: .low, latency: .low, network: .low))
        // HDR off is quiet (dimmed chips), on costs a little
        #expect(settingImpact(id: StreamSettingsForm.hdr, context: ctx) == .quiet)
        var hdr = ctx
        hdr.hdr = true
        #expect(settingImpact(id: StreamSettingsForm.hdr, context: hdr) == SettingImpact(gpu: .low, latency: .none, network: .low))
        // 4K at 90 Mbps asks for a lot of the network and some of the GPU
        let big = ImpactContext(height: 2160, fps: 60, bitrateMbps: 150, codec: "forceh265", hdr: false, pacing: "warp2")
        #expect(settingImpact(id: StreamSettingsForm.resolution, context: big) == SettingImpact(gpu: .medium, latency: .medium, network: .high))
        #expect(settingImpact(id: StreamSettingsForm.bitrate, context: big) == SettingImpact(gpu: .none, latency: .medium, network: .high))
        #expect(settingImpact(id: StreamSettingsForm.framePacing, context: big) == SettingImpact(gpu: .high, latency: .low, network: .high))
        // H.264 asks the link for three times
        let h264 = ImpactContext(height: 1080, fps: 60, bitrateMbps: 20, codec: "neverh265", hdr: false, pacing: "smoothness")
        #expect(h264.recommendedMbps == 60)
        #expect(settingImpact(id: StreamSettingsForm.codec, context: h264) == SettingImpact(gpu: .low, latency: .low, network: .medium))
        #expect(settingImpact(id: StreamSettingsForm.framePacing, context: h264) == SettingImpact(gpu: .low, latency: .high, network: .none))
        // A setting without chips has none
        #expect(settingImpact(id: StreamSettingsForm.hostAudio, context: ctx) == nil)
    }

    @Test func theKanaFoldDropsDakutenSmallFormsAndTheLongVowelMark() {
        #expect(SettingsSearchText.fold("ビットレート") == "ひつとれと")
        #expect(SettingsSearchText.fold("ぎゃ") == "きや")
        #expect(SettingsSearchText.fold("ABC") == "abc")
    }

    @Test func aQueryOfKoreanInitialsFindsTheTitleWhoseSyllablesStartWithThem() {
        #expect(SettingsSearchText.initials("해상도", pinyin: false) == "ㅎㅅㄷ")
        #expect(SettingsSearchText.matches(word: "ㅎㅅㄷ", text: "해상도 비디오", titles: "해상도", language: "ko"))
        #expect(!SettingsSearchText.matches(word: "ㅎㅂㄷ", text: "해상도 비디오", titles: "해상도", language: "ko"))
        // Latin text has no initials
        #expect(SettingsSearchText.initials("Resolution", pinyin: false) == nil)
        // A double consonant of an input method is the plain one
        #expect(SettingsSearchText.plainJamo("ㄲ") == "ㄱ")
    }

    @Test func aQueryOfPinyinInitialsFindsAChineseTitle() {
        #expect(SettingsSearchText.matches(word: "sz", text: "设置", titles: "设置", language: "zh"))
        #expect(!SettingsSearchText.matches(word: "sz", text: "设置", titles: "设置", language: "en"))
    }

    @Test func theLetterPickerKeepsNineColumnsUntilSixRowsAreNotEnough() {
        #expect(LetterPicker.columns(keys: 36) == 9)
        #expect(LetterPicker.keySize(columns: 9) == 74)
        // Japanese kana: 46 keys need 8 columns of smaller keys within 820
        #expect(LetterPicker.columns(keys: 54) == 9)
        #expect(LetterPicker.columns(keys: 60) == 10)
        #expect(LetterPicker.keySize(columns: 10) == 71)
        #expect(LetterPicker.compactColumns(keys: 36) == 18)
        #expect(LetterPicker.compactColumns(keys: 37) == 19)
    }

    @Test func everyWordOfTheQueryMustMatchInAnyOrder() {
        let rows = [
            SettingRow(id: "a", tab: .stream, section: "Video", icon: "", label: "Resolution", value: .toggle(false), help: "How sharp the picture is"),
            SettingRow(id: "b", tab: .stream, section: "Video", icon: "", label: "Bitrate", value: .toggle(false), help: "How much the picture can take"),
        ]
        #expect(SettingsSearch.results(rows, query: "", language: "en").count == 2)
        #expect(SettingsSearch.results(rows, query: "PICTURE sharp", language: "en").map(\.id) == ["a"])
        #expect(SettingsSearch.results(rows, query: "picture", language: "en").count == 2)
        #expect(SettingsSearch.results(rows, query: "nothing here", language: "en").isEmpty)
    }
}
