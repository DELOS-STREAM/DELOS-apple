import DelosData
import Foundation
import Testing
@testable import DelosUI

@MainActor @Suite struct AppearanceSettingsTests {
    @Test func theRowsSitInAndroidsTabsAndOrder() {
        let form = AppearanceForm(appearance: Appearance())
        #expect(form.rows(.appearance).map(\.id) == [
            "ui_dark", "ui_palette", "ui_match_game_colors", "ui_clock", "ui_background", "ui_hero_background", "ui_hero_blur",
            "ui_hero_opacity", "ui_scale", "ui_reduced_motion",
        ])
        #expect(form.rows(.audio).map(\.id) == ["ui_sounds"])
        #expect(form.rows(.controls).map(\.id) == ["ui_haptics"])
        #expect(form.rows(.stream).isEmpty)
        #expect(Set(SettingsTab.allCases.flatMap { form.rows($0) }.map(\.section)) == ["Interface"])
        #expect(Set(SettingsTab.allCases.flatMap { form.rows($0) }.map(\.id)) == AppearanceForm.ids)
        for tab in SettingsTab.availableCases {
            let all = StreamSettingsForm(settings: StreamSettings(), device: device).rows(tab)
                + form.rows(tab) + CoversForm(enabled: false, automatic: true, pcName: nil).rows(tab) + AppLanguageSetting.rows(tab)
            #expect(all.first?.id == SettingsScreen.firstRow(tab))
        }
    }

    @Test func theChoicesListEveryOptionWithAndroidsLabels() throws {
        let rows = AppearanceForm(appearance: Appearance()).rows(.appearance)
        guard case let .choice(theme, themes, selectedTheme) = rows[0].value else { Issue.record("theme"); return }
        #expect(theme == "Dark" && themes == ["Dark", "Light"] && selectedTheme == 0)
        guard case let .choice(palette, palettes, selectedPalette) = rows[1].value else { Issue.record("palette"); return }
        #expect(palette == "Delos" && selectedPalette == 0)
        #expect(palettes == ["Delos", "Cinder", "Peony", "Nebula", "Twilight", "Cobalt", "Glacier", "Seafoam"])
        guard case let .choice(clock, clocks, selectedClock) = rows[3].value else { Issue.record("clock"); return }
        #expect(clock == "System" && clocks == ["System", "12-hour", "24-hour"] && selectedClock == 0)
        guard case let .choice(background, backgrounds, selectedBackground) = rows[4].value else { Issue.record("background"); return }
        #expect(background == "Contour" && selectedBackground == 3)
        #expect(backgrounds == ["Aurora", "Tide", "Silk", "Contour", "Nebula", "Plasma", "Lava", "Caustics", "Bokeh", "Orbit", "Still"])
        #expect(rows[8].value == .slider(value: 100, range: 100...130, step: 5, divisor: 1, unit: " %"))
        guard case let .choice(motion, motions, selectedMotion) = rows[9].value else { Issue.record("motion"); return }
        #expect(motion == "Full" && motions == ["Full", "Reduced"] && selectedMotion == 0)
    }

    @Test func theClockAndScaleRowsHaveAndroidsHelp() {
        var appearance = Appearance()
        #expect(AppearanceForm(appearance: appearance).rows(.appearance)[3].help == "System\n\nTime format in the status bar.")
        appearance.clock = .h12
        let rows = AppearanceForm(appearance: appearance).rows(.appearance)
        #expect(rows[3].help == "12-hour\n12-hour clock with AM or PM.\n\nTime format in the status bar.")
        #expect(rows[8].label == "Interface scale")
        #expect(rows[8].help == "Size of text, status bar and button hints.")
    }

    @Test func theScaleStepsOnItsGridAndStopsAtItsEnds() {
        var form = AppearanceForm(appearance: Appearance())
        let atStart = form.step("ui_scale", by: -1)
        #expect(!atStart && form.appearance.uiScale == 100)
        form.step("ui_scale", by: 1)
        #expect(form.appearance.uiScale == 105)
        form.step("ui_scale", by: 9)
        #expect(form.appearance.uiScale == 130)
        let atEnd = form.step("ui_scale", by: 1)
        #expect(!atEnd)
        form.slide("ui_scale", to: 112)
        #expect(form.appearance.uiScale == 110)
        form.slide("ui_scale", to: 113)
        #expect(form.appearance.uiScale == 115)
        form.slide("ui_scale", to: 90)
        #expect(form.appearance.uiScale == 100)
        form.slide("ui_dark", to: 130)
        #expect(form.appearance.uiScale == 100 && form.appearance.dark)
        form.step("ui_clock", by: -1)
        #expect(form.appearance.clock == .h24)
        form.step("ui_clock", by: 1)
        #expect(form.appearance.clock == .system)
        form.pick("ui_clock", option: 1)
        #expect(form.appearance.clock == .h12)
        form.pick("ui_clock", option: 3)
        #expect(form.appearance.clock == .h12)
    }

    @Test func thePaletteRowShowsItsHueAndTheHelpExplainsTheChoice() {
        var appearance = Appearance()
        appearance.palette = .mint
        let rows = AppearanceForm(appearance: appearance).rows(.appearance)
        #expect(rows[1].swatch == hsl(150, 90, 60))
        #expect(rows[0].swatch == nil)
        #expect(rows[0].help == "Dark\nDark surfaces with light text.\n\nDark or light interface.")
        #expect(rows[1].help == "Seafoam\n\nColors of the interface and animated backgrounds.")
        #expect(rows[4].help == "Contour\nSmooth moving contour lines in the selected colors.")
        #expect(AppearanceForm(appearance: appearance).rows(.audio)[0].value == .toggle(true))
    }

    @Test func theGameColorAndAppBackgroundRowsAreAndroids() {
        var appearance = Appearance()
        var rows = AppearanceForm(appearance: appearance).rows(.appearance)
        #expect(rows[2].label == "Match the app's colors" && rows[2].value == .toggle(true))
        #expect(rows[2].help == "The animated background takes the main color of the selected app's background image.")
        #expect(rows[5].label == "App background" && rows[5].value == .toggle(true))
        #expect(rows[6].label == "App background blur")
        #expect(rows[6].value == .slider(value: 5, range: 0...40, step: 5, divisor: 1, unit: " px"))
        #expect(rows[7].label == "App background opacity")
        #expect(rows[7].value == .slider(value: 80, range: 0...100, step: 5, divisor: 1, unit: " %"))
        #expect(rows[6].enabled && rows[7].enabled)
        // Without the app background its blur and opacity are unavailable and keep their values
        appearance.heroBackground = false
        var form = AppearanceForm(appearance: appearance)
        rows = form.rows(.appearance)
        #expect(!rows[6].enabled && !rows[7].enabled && rows[5].enabled)
        let unavailable = form.step("ui_hero_blur", by: 1)
        #expect(!unavailable)
        form.slide("ui_hero_opacity", to: 20)
        #expect(form.appearance.heroBlur == 5 && form.appearance.heroOpacity == 80)
    }

    @Test func theAppBackgroundSlidersStepOnTheirGridsAndStoreTogglesFlip() {
        var form = AppearanceForm(appearance: Appearance())
        form.step("ui_hero_blur", by: -1)
        #expect(form.appearance.heroBlur == 0)
        let atStart = form.step("ui_hero_blur", by: -1)
        #expect(!atStart)
        form.slide("ui_hero_blur", to: 38)
        #expect(form.appearance.heroBlur == 40)
        form.step("ui_hero_opacity", by: 4)
        #expect(form.appearance.heroOpacity == 100)
        form.slide("ui_hero_opacity", to: 12)
        #expect(form.appearance.heroOpacity == 10)
        form.step("ui_match_game_colors", by: 1)
        form.step("ui_hero_background", by: -1)
        #expect(!form.appearance.matchGameColors && !form.appearance.heroBackground)
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppearanceStore(suiteName: suite)
        store.save(form.appearance, profile: "a")
        #expect(store.load(profile: "a") == form.appearance)
    }

    @Test func leftAndRightStepAndWrapTogglesFlip() {
        var form = AppearanceForm(appearance: Appearance())
        let changed = form.step("ui_dark", by: 1)
        #expect(changed)
        #expect(!form.appearance.dark)
        form.step("ui_dark", by: 1)
        #expect(form.appearance.dark)
        form.step("ui_palette", by: -1)
        #expect(form.appearance.palette == .mint)
        form.step("ui_palette", by: 1)
        #expect(form.appearance.palette == .delos)
        form.step("ui_background", by: 1)
        #expect(form.appearance.background == .nebula)
        for _ in 0..<7 { form.step("ui_background", by: 1) }
        #expect(form.appearance.background == .aurora)
        form.step("ui_reduced_motion", by: -1)
        #expect(form.appearance.reducedMotion)
        form.step("ui_sounds", by: 1)
        form.step("ui_haptics", by: -1)
        #expect(!form.appearance.sounds && !form.appearance.haptics)
        let unknown = form.step("list_fps", by: 1)
        #expect(!unknown)
    }

    @Test func aPickedValueIsSetAndOutOfRangePicksAreIgnored() {
        var form = AppearanceForm(appearance: Appearance())
        form.pick("ui_palette", option: 5)
        form.pick("ui_background", option: 10)
        form.pick("ui_dark", option: 1)
        form.pick("ui_reduced_motion", option: 1)
        #expect(form.appearance.palette == .iris)
        #expect(form.appearance.background == .still)
        #expect(!form.appearance.dark && form.appearance.reducedMotion)
        let before = form.appearance
        form.pick("ui_palette", option: 8)
        form.pick("ui_background", option: -1)
        #expect(form.appearance == before)
    }

    @Test func changesAreStoredPerProfile() {
        let suite = "delos.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AppearanceStore(suiteName: suite)
        var form = AppearanceForm(appearance: store.load(profile: "a"))
        form.pick("ui_palette", option: 2)
        form.pick("ui_background", option: 8)
        form.step("ui_dark", by: 1)
        form.step("ui_reduced_motion", by: 1)
        form.step("ui_sounds", by: 1)
        form.step("ui_haptics", by: 1)
        store.save(form.appearance, profile: "a")
        let loaded = store.load(profile: "a")
        #expect(loaded == form.appearance)
        #expect(loaded.palette == .rose && loaded.background == .bokeh && !loaded.dark && loaded.reducedMotion)
        #expect(!loaded.sounds && !loaded.haptics)
        #expect(store.load(profile: "b") == Appearance())
    }
}

/// A 1080p display at 60 Hz decoding H.264 and HEVC.
private let device = StreamDevice(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60, decodable: [.h264, .hevc])
