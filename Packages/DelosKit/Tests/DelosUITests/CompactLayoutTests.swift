import CoreGraphics
import Testing
@testable import DelosUI

@Suite struct CompactLayoutTests {
    private func stage(_ width: Double, _ height: Double) -> Stage { Stage(size: CGSize(width: width, height: height)) }

    @Test func theCompactScaleIsOneOffACompactStage() {
        #expect(stage(1920, 1080).compactScale == 1)
        #expect(stage(1000, 3000).compact)
    }

    @Test func theCompactScaleFollowsTheHeightAndStopsAtItsFloor() {
        // 390 x 844 points: 907 x 1963 stage pixels, taller than the design, so 1
        let phone = stage(390, 844)
        #expect(phone.compact && phone.compactScale == 1)
        // A short compact stage: 957 high is 0.886...
        let squat = stage(1200 * 0.43, 957 * 0.43)
        #expect(squat.compact && abs(squat.compactScale - 957 / 1080) < 0.01)
        let tiny = stage(1000 * 0.43, 400 * 0.43)
        #expect(tiny.compactScale == Stage.minCompactScale)
    }

    @Test func aCenteredColumnKeepsClearOfTheBarsOnlyWhenCompact() {
        let wide = CenterColumnLayout.clearance(stage(1920, 1080))
        #expect(wide.top == 0 && wide.bottom == 0)
        let phone = CenterColumnLayout.clearance(stage(390, 844))
        #expect(phone.top == 104 && phone.bottom == 92)
    }

    @Test func aCenteredColumnsGapShrinksOnlyToItsFloor() {
        #expect(CenterColumnLayout.gap(40, min: FocusSpacing.pillLineGap, stage(1920, 1080)) == 40)
        // At the lowest compact scale 40 px would be 24.8: Change name and Create keep the pills' gap
        let tiny = stage(1000 * 0.43, 400 * 0.43)
        #expect(CenterColumnLayout.gap(40, min: FocusSpacing.pillLineGap, tiny) == FocusSpacing.pillLineGap)
        #expect(CenterColumnLayout.gap(54, min: 0, tiny) == 54 * Stage.minCompactScale)
    }

    @Test func theAvatarGridTakesAsManyColumnsAsFit() {
        #expect(AvatarGridLayout.columns(stage(1920, 1080)) == 8)
        // 688 points are 1600 stage pixels (the floor): a narrow tall window is compact and takes four
        let narrow = stage(688, 1200)
        #expect(narrow.width == 1600 && AvatarGridLayout.columns(narrow) == 4)
        // A phone in portrait is compact: four at most, two at least
        let phone = AvatarGridLayout.columns(stage(390, 844))
        #expect((2...4).contains(phone))
    }

    @Test func aFocusedCircleKeepsItsRingClearOfTheLabelAndTheNextRow() {
        // 144 px circle: growth 5.76, ring 11.6
        #expect(abs(AvatarGridLayout.focusReach(144) - (144 * 0.08 + 11.6)) < 0.001)
        #expect(AvatarGridLayout.labelGap(144) == AvatarGridLayout.focusReach(144) + 8)
        #expect(AvatarGridLayout.rowGap(144) == AvatarGridLayout.focusReach(144) + 12)
    }

    @Test func theHelpDockIsAQuarterOfTheStageWhereThereIsRoom() {
        #expect(HelpDockLayout.height(stageHeight: 1000) == 250)
        #expect(HelpDockLayout.height(stageHeight: 400) == HelpDockLayout.minHeight)
        #expect(HelpDockLayout.height(stageHeight: 2000) == HelpDockLayout.maxHeight)
        // Room for three whole rows above it
        #expect(HelpDockLayout.height(stageHeight: 1100, rowsTop: 260, bottom: 96, rowHeight: 80) == 270)
        // Too short for both: never under the minimum
        #expect(HelpDockLayout.height(stageHeight: 850, rowsTop: 260, bottom: 96, rowHeight: 80) == 212.5)
        // A short stage lets the dock give way
        #expect(HelpDockLayout.height(stageHeight: 722, rowsTop: 260, bottom: 96, rowHeight: 80) == HelpDockLayout.shortMinHeight)
    }

    @Test func settingsKeepsItsMarginsAndBottom() {
        #expect(SettingsLayout.margin(stage(1920, 1080)) == 150)
        #expect(SettingsLayout.margin(stage(390, 844)) == 48)
        #expect(SettingsLayout.bottom(scale: 1) == 96)
        #expect(abs(SettingsLayout.bottom(scale: 1.3) - (96 + 0.3 * 92)) < 0.0001)
    }

    @Test func theNavigationWrapsAtItsEnds() {
        let ids = ["a", "b", "c"]
        #expect(TopNav.wrap(0, of: ids).mapValues { $0 as? String } == [.left: "c"])
        #expect(TopNav.wrap(1, of: ids).isEmpty)
        #expect(TopNav.wrap(2, of: ids).mapValues { $0 as? String } == [.right: "a"])
        #expect(TopNav.wrap(0, of: ["a"]).isEmpty)
    }
}

@Suite struct AboutRowsTests {
    @Test func aboutLeadsWithTheVersionWhatDelosIsBasedOnAndReplayingTheWelcomeThenTheDiagnosticLog() {
        let rows = AboutSetting.rows(.about, diagnosticLogs: false)
        #expect(rows.map(\.id) == [AboutSetting.versionID, AboutSetting.basedID, AboutSetting.welcomeID, AboutSetting.diagLogsID])
        #expect(rows[1].value == .info("Artemis · Moonlight"))
        #expect(rows[3].value == .toggle(false) && rows[3].section == "Diagnostics")
        #expect(AboutSetting.rows(.stream).isEmpty)
        #expect(AboutSetting.firstID == SettingsScreen.firstRow(.about))
    }

    @Test func debugInfoIsTheLastRowOfTheMiscSectionAfterTheLanguage() {
        let rows = (AboutSetting.rows(.about) + AppLanguageSetting.rows(.about, supported: true) + DebugInfoSetting.rows(.about)).groupedBySection()
        #expect(rows.suffix(2).map(\.id) == [AppLanguageSetting.id, DebugInfoSetting.id])
        #expect(rows.last?.value == .action(label: nil) && rows.last?.icon == Symbols.debug)
        #expect(DebugInfoSetting.rows(.stream).isEmpty)
    }

    @Test func coversSaysWhereToChooseArtwork() {
        let rows = CoversForm(enabled: false, automatic: true, pcName: nil).rows(.covers)
        #expect(rows.last?.id == CoversForm.choose)
        guard case .info = rows.last?.value else { Issue.record("not an info row"); return }
    }
}
