import DelosData
import Testing
@testable import DelosUI

@Suite struct QuickSettingsTests {
    @Test func theRowsAreTheThemeTheBackgroundTheSoundsAndTheHaptics() {
        let rows = QuickSettings.rows(Appearance())
        #expect(rows.map(\.id) == QuickSettings.ids)
        #expect(rows.map(\.id) == [AppearanceForm.theme, AppearanceForm.background, AppearanceForm.sounds, AppearanceForm.haptics])
        #expect(rows.map(\.label) == [L("shell_side_theme"), L("shell_side_background"), L("shell_side_sounds"), L("shell_side_haptics")])
    }

    @Test func theRowsShowTheCurrentValues() {
        var appearance = Appearance()
        appearance.dark = false
        appearance.background = .aurora
        appearance.sounds = false
        let rows = QuickSettings.rows(appearance)
        guard case let .choice(theme, themes, themeIndex) = rows[0].value else {
            Issue.record("theme is not a choice")
            return
        }
        #expect(theme == L("shell_side_theme_light") && themes.count == 2 && themeIndex == 1)
        guard case let .choice(background, backgrounds, backgroundIndex) = rows[1].value else {
            Issue.record("background is not a choice")
            return
        }
        #expect(background == AppearanceForm.label(.aurora) && backgrounds.count == BackgroundKind.allCases.count)
        #expect(backgroundIndex == BackgroundKind.allCases.firstIndex(of: .aurora))
        #expect(rows[2].value == .toggle(false))
        #expect(rows[3].value == .toggle(true))
    }

    @Test func steppingChangesOnlyTheRowsSetting() throws {
        let start = Appearance()
        let light = try #require(QuickSettings.step(AppearanceForm.theme, by: 1, from: start))
        #expect(!light.dark && light.background == start.background && light.sounds == start.sounds)
        let quiet = try #require(QuickSettings.step(AppearanceForm.sounds, by: 1, from: start))
        #expect(!quiet.sounds && quiet.dark)
        let still = try #require(QuickSettings.step(AppearanceForm.haptics, by: -1, from: start))
        #expect(!still.haptics)
    }

    @Test func theBackgroundStepsBothWaysAndWrapsRound() throws {
        var appearance = Appearance()
        appearance.background = BackgroundKind.allCases[0]
        let last = try #require(QuickSettings.step(AppearanceForm.background, by: -1, from: appearance))
        #expect(last.background == BackgroundKind.allCases[BackgroundKind.allCases.count - 1])
        let next = try #require(QuickSettings.step(AppearanceForm.background, by: 1, from: appearance))
        #expect(next.background == BackgroundKind.allCases[1])
    }

    @Test func aRowThatIsNotAQuickSettingChangesNothing() {
        #expect(QuickSettings.step(AppearanceForm.palette, by: 1, from: Appearance()) == nil)
        #expect(QuickSettings.step(SideMenu.settingsID, by: 1, from: Appearance()) == nil)
    }
}
