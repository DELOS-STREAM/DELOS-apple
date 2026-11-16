import DelosData
import Foundation
import Testing
@testable import DelosUI

@MainActor @Suite struct AppearanceSettingsTests {
    @Test func theRowsSitInAndroidsTabsAndOrder() {
        let form = AppearanceForm(appearance: Appearance())
        #expect(form.rows(.appearance).map(\.id) == ["ui_dark", "ui_palette", "ui_background", "ui_reduced_motion"])
        #expect(form.rows(.audio).map(\.id) == ["ui_sounds"])
        #expect(form.rows(.controls).map(\.id) == ["ui_haptics"])
        #expect(form.rows(.stream).isEmpty)
        #expect(Set(SettingsTab.allCases.flatMap { form.rows($0) }.map(\.section)) == ["Interface"])
        #expect(Set(SettingsTab.allCases.flatMap { form.rows($0) }.map(\.id)) == AppearanceForm.ids)
        for tab in SettingsTab.allCases {
            let all = StreamSettingsForm(settings: StreamSettings(), device: device).rows(tab) + form.rows(tab)
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
        guard case let .choice(background, backgrounds, selectedBackground) = rows[2].value else { Issue.record("background"); return }
        #expect(background == "Contour" && selectedBackground == 3)
        #expect(backgrounds == ["Aurora", "Tide", "Silk", "Contour", "Nebula", "Plasma", "Lava", "Caustics", "Bokeh", "Orbit", "Still"])
        guard case let .choice(motion, motions, selectedMotion) = rows[3].value else { Issue.record("motion"); return }
        #expect(motion == "Full" && motions == ["Full", "Reduced"] && selectedMotion == 0)
    }

    @Test func thePaletteRowShowsItsHueAndTheHelpExplainsTheChoice() {
        var appearance = Appearance()
        appearance.palette = .mint
        let rows = AppearanceForm(appearance: appearance).rows(.appearance)
        #expect(rows[1].swatch == hsl(150, 90, 60))
        #expect(rows[0].swatch == nil)
        #expect(rows[0].help == "Dark\nDark surfaces with light text.\n\nDark or light interface.")
        #expect(rows[1].help == "Seafoam\n\nColors of the interface and animated backgrounds.")
        #expect(rows[2].help == "Contour\nSmooth moving contour lines in the selected colors.")
        #expect(AppearanceForm(appearance: appearance).rows(.audio)[0].value == .toggle(true))
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
