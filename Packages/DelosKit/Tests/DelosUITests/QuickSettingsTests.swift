import DelosData
import Testing
@testable import DelosUI

@Suite struct QuickSettingsTests {
    @Test func theRowsAreTheThemeMaterialYouTheBackgroundTheSoundsAndTheHaptics() {
        let rows = QuickSettings.rows(Appearance())
        #expect(rows.map(\.id) == QuickSettings.ids)
        // Material You colors only where the system has a color to follow (the Mac)
        let materialYou = SystemAccent.supported ? [AppearanceForm.materialYou] : []
        #expect(rows.map(\.id) == [AppearanceForm.theme] + materialYou + [AppearanceForm.background, AppearanceForm.sounds, AppearanceForm.haptics])
        #expect(rows.map(\.label) == [L("shell_side_theme")] + (SystemAccent.supported ? [L("shell_side_material_you")] : [])
            + [L("shell_side_background"), L("shell_side_sounds"), L("shell_side_haptics")])
    }

    @Test func theRowsShowTheCurrentValues() {
        var appearance = Appearance()
        appearance.dark = false
        appearance.background = .aurora
        appearance.sounds = false
        let rows = QuickSettings.rows(appearance)
        func value(_ id: String) -> SettingValue? { rows.first { $0.id == id }?.value }
        guard case let .choice(theme, themes, themeIndex) = value(AppearanceForm.theme) else {
            Issue.record("theme is not a choice")
            return
        }
        #expect(theme == L("shell_side_theme_light") && themes.count == 2 && themeIndex == 1)
        guard case let .choice(background, backgrounds, backgroundIndex) = value(AppearanceForm.background) else {
            Issue.record("background is not a choice")
            return
        }
        #expect(background == AppearanceForm.label(.aurora) && backgrounds.count == BackgroundKind.allCases.count)
        #expect(backgroundIndex == BackgroundKind.allCases.firstIndex(of: .aurora))
        #expect(value(AppearanceForm.sounds) == .toggle(false))
        #expect(value(AppearanceForm.haptics) == .toggle(true))
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
