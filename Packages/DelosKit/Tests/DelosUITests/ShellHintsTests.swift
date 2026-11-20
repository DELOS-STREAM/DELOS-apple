import DelosInput
import Testing
@testable import DelosUI

@MainActor @Suite struct ShellHintsTests {
    private func buttons(_ context: ShellHints.Context) -> [HintButton] { ShellHints.hints(context, kind: .controller).map(\.button) }

    @Test func theHomeScreenStartsMenuAndOptions() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        #expect(buttons(context) == [.pad(.south), .pad(.menuLeft)])
        context.hasContextMenu = true
        #expect(buttons(context) == [.pad(.south), .pad(.menuLeft), .pad(.menuRight)])
    }

    @Test func layersAndThePortalComeFirst() {
        var context = ShellHints.Context(screen: .settings)
        context.layer = .context(root: true)
        #expect(buttons(context) == [.pad(.south), .pad(.east)])
        context.sideMenu = true
        #expect(buttons(context) == [.pad(.south), .pad(.east)])
        // Adjust only on a side row with values (Theme, Background), not on a toggle or All settings
        context.sideMenuAdjustable = true
        #expect(buttons(context) == [.adjust, .pad(.south), .pad(.east)])
        context.portalCancellable = true
        #expect(buttons(context) == [.pad(.east)])
        context.portalCancellable = false
        #expect(buttons(context).isEmpty)
    }

    @Test func settingsAdjustOnlyWhenTheRowDoes() {
        var context = ShellHints.Context(screen: .settings)
        #expect(!buttons(context).contains(.adjust))
        context.screenHints.adjustable = true
        #expect(buttons(context) == [.adjust, .pad(.leftShoulder), .pad(.rightShoulder), .pad(.north), .pad(.south), .pad(.east)])
    }

    @Test func theArtworkSheetHasItsOwnButtons() {
        var context = ShellHints.Context(screen: .artwork(hostID: "h", appID: 1))
        #expect(buttons(context).contains(.pad(.north)) && buttons(context).contains(.pad(.leftShoulder)))
        context.screenHints.sheetOpen = true
        #expect(buttons(context) == [.pad(.south), .pad(.west), .pad(.north), .pad(.east)])
    }

    /// The hint of [button] on the Artwork screen with [focused] focused (nil: no such hint).
    private func artworkHint(_ button: GlyphRole, focused: String?, sheetOpen: Bool = false) -> String? {
        var context = ShellHints.Context(screen: .artwork(hostID: "h", appID: 1))
        context.screenHints = ScreenHints(sheetOpen: sheetOpen, artworkSouth: ArtworkSouth.of(focused))
        return ShellHints.hints(context, kind: .controller).first { $0.button == .pad(button) }?.label
    }

    @Test func theArtworkScreenKeepsXForTheSearchAndOnlyTheSheetResets() {
        // On every item of the screen X is the search by name and Y the filter sheet (Android's mapping) ...
        let items = [
            "art-12", ArtworkScreen.noneID, ArtworkScreen.searchID, ArtworkScreen.filterID, ArtworkScreen.tabID(.hero),
            ArtworkEmpty.resetID, ArtworkEmpty.changeID, ArtworkFilterStrip.resetID, ArtworkFilterStrip.chipID(.style("material")),
        ]
        for id in items {
            #expect(artworkHint(.west, focused: id) == L("shell_hint_search_name"), "X on \(id)")
            #expect(artworkHint(.north, focused: id) == L("shell_hint_filter"), "Y on \(id)")
        }
        // ... and X resets the filters only with the sheet open
        #expect(artworkHint(.west, focused: ArtworkEmpty.resetID, sheetOpen: true) == L("shell_hint_reset_filters"))
        #expect(artworkHint(.north, focused: nil, sheetOpen: true) == L("shell_hint_done"))
    }

    @Test func theEmptyStateButtonsCarryOnlyGlyphsThatDoWhatTheyClaim() {
        // Reset claims no button: neither X (the search by name) nor anything else the hint bar names for another action
        #expect(ArtworkEmpty.resetGlyph == nil)
        // Change filters claims Y, and Y opens the sheet
        let change = ArtworkEmpty.changeGlyph
        #expect(change == .north)
        if let change { #expect(artworkHint(change, focused: ArtworkEmpty.changeID) == L("shell_hint_filter")) }
    }

    @Test func aButtonNamesWhatItDoesOnTheFocusedArtworkItem() {
        #expect(artworkHint(.south, focused: "art-12") == L("shell_hint_use_image"))
        #expect(artworkHint(.south, focused: ArtworkScreen.noneID) == L("shell_hint_use_image"))
        #expect(artworkHint(.south, focused: ArtworkEmpty.resetID) == L("shell_hint_reset_filters"))
        #expect(artworkHint(.south, focused: ArtworkFilterStrip.resetID) == L("shell_hint_reset_filters"))
        #expect(artworkHint(.south, focused: ArtworkEmpty.changeID) == L("filters_art_change"))
        #expect(artworkHint(.south, focused: ArtworkScreen.searchID) == L("shell_hint_search_name"))
        #expect(artworkHint(.south, focused: ArtworkScreen.filterID) == L("shell_hint_filter"))
        #expect(artworkHint(.south, focused: ArtworkScreen.tabID(.logo)) == L("shell_hint_select"))
        #expect(artworkHint(.south, focused: ArtworkFilterStrip.chipID(.style("material"))) == L("shell_hint_select"))
        #expect(artworkHint(.south, focused: nil) == L("shell_hint_use_image"))
    }

    @Test func aStreamHasNoHints() {
        #expect(buttons(ShellHints.Context(screen: .stream(hostID: "h", appID: 1))).isEmpty)
    }

    @Test func rankKeepsTheMainActionsLongest() {
        #expect(HintFit.rank(.pad(.south)) < HintFit.rank(.pad(.east)))
        #expect(HintFit.rank(.pad(.east)) < HintFit.rank(.pad(.west)))
        #expect(HintFit.rank(.pad(.west)) < HintFit.rank(.pad(.leftShoulder)))
        #expect(HintFit.rank(.pad(.leftShoulder)) < HintFit.rank(.pad(.menuLeft)))
        #expect(HintFit.group(.pad(.leftShoulder)) == HintFit.group(.pad(.rightShoulder)))
        #expect(HintFit.group(.pad(.south)) == nil)
    }

    @Test func theLeastImportantHintsLoseTheirLabelsFirst() {
        let items = [
            HintFitItem(rank: 0, bare: 38, short: nil, full: 150),
            HintFitItem(rank: 1, bare: 38, short: nil, full: 150),
            HintFitItem(rank: 4, bare: 38, short: nil, full: 150),
        ]
        #expect(HintFit.fitHints(items, gap: 10, available: 1000) == [.full, .full, .full])
        #expect(HintFit.fitHints(items, gap: 10, available: 360) == [.full, .full, .bare])
        #expect(HintFit.fitHints(items, gap: 10, available: 100) == [.bare, .bare, .bare])
    }

    @Test func aShorterLabelSavesAHintBeforeItsLabelGoes() {
        let items = [HintFitItem(rank: 0, bare: 38, short: nil, full: 150), HintFitItem(rank: 1, bare: 38, short: 80, full: 150)]
        #expect(HintFit.fitHints(items, gap: 10, available: 280) == [.full, .short])
        #expect(HintFit.fitHints(items, gap: 10, available: 190) == [.bare, .short])
    }

    @Test func aNoteStaysOnlyWhileEveryHintKeepsItsLabel() {
        let items = [HintFitItem(rank: 0, bare: 38, short: nil, full: 100)]
        #expect(HintFit.fitBar(noteWidths: [300, 100], noteGap: 20, items: items, hintGap: 10, available: 500).note == 0)
        #expect(HintFit.fitBar(noteWidths: [300, 100], noteGap: 20, items: items, hintGap: 10, available: 250).note == 1)
        let none = HintFit.fitBar(noteWidths: [300, 200], noteGap: 20, items: items, hintGap: 10, available: 150)
        #expect(none.note == nil)
        #expect(none.details == [.full])
    }

    private func adapted(_ kind: InputKind, _ context: ShellHints.Context) -> [HintButton] {
        ShellHints.adapt(ShellHints.hints(context, kind: .controller), to: kind).map(\.button)
    }

    @Test func touchKeepsThePrimaryActionThePointerItsClickAndRightClick() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        context.hasContextMenu = true
        #expect(adapted(.touch, context) == [.tap])
        // The pointer's secondary click is the right menu button: the cover's context menu (#16)
        #expect(adapted(.pointer, context) == [.click, .secondaryClick])
        let hints = ShellHints.adapt(ShellHints.hints(context, kind: .controller), to: .touch)
        #expect(hints.first?.label == ShellHints.hints(context, kind: .controller).first?.label)
    }

    @Test func theKeyboardShowsTheKeyOfEveryAction() {
        var settings = ShellHints.Context(screen: .settings)
        settings.screenHints.adjustable = true
        #expect(adapted(.keyboard, settings) == [
            .key(.arrows), .key(.leftBracket), .key(.rightBracket), .key(.letterF), .key(.returnKey), .key(.escape),
        ])
        var home = ShellHints.Context(screen: .home(hostID: "h"))
        home.hasContextMenu = true
        #expect(adapted(.keyboard, home) == [.key(.returnKey), .key(.tab), .key(.letterO)])
        #expect(adapted(.controller, settings) == buttons(settings))
    }

    @Test func theKeyboardPressesTheFilterKeyInsteadOfThePill() {
        var home = ShellHints.Context(screen: .home(hostID: "h"))
        home.screenHints.filterLabel = "Filter"
        let keyboard = ShellHints.adapt(ShellHints.hints(home, kind: .controller), to: .keyboard)
        #expect(keyboard.map(\.button) == [.key(.returnKey), .key(.letterF), .key(.tab)])
        #expect(keyboard.allSatisfy { !$0.tappable })
        // A finger and the pointer press the pill
        #expect(ShellHints.adapt(ShellHints.hints(home, kind: .controller), to: .pointer).map(\.tappable).contains(true))
    }

    @Test func xAndTheRightMenuButtonShareOneKeyShownOnce() {
        var app = ShellHints.Context(screen: .appSettings(hostID: "h", appID: 1))
        app.hasContextMenu = true
        app.screenHints.rowOptions = true
        let keys = adapted(.keyboard, app)
        #expect(keys.filter { $0 == .key(.letterO) }.count == 1)
        #expect(keys.contains(.key(.escape)))
    }

    @Test func theBackArrowIsForEveryInputButAController() {
        for kind in InputKind.allCases { #expect(InputKindRule.withoutController.shows(kind) == (kind != .controller)) }
        #expect(InputKindRule.withController.shows(.controller))
        #expect(!InputKindRule.withController.shows(.touch))
    }

    private func labels(_ context: ShellHints.Context) -> [String] {
        ShellHints.hints(context, kind: .controller).map(\.label)
    }

    @Test func theSettingsSearchOffersSelectAndBack() {
        var context = ShellHints.Context(screen: .settings)
        context.screenHints.adjustable = true
        #expect(labels(context) == ["Adjust", "Previous tab", "Next tab", "Search", "Change", "Back"])
        context.screenHints.rowOptions = true
        #expect(labels(context) == ["Adjust", "Previous tab", "Next tab", "Search", "Change", "Options", "Back"])
        context.screenHints = ScreenHints(settingsSearch: true)
        #expect(labels(context) == ["Select", "Back"])
    }

    @Test func appSettingsOfferOptionsOnlyWhereTheyOpenSomething() {
        var context = ShellHints.Context(screen: .appSettings(hostID: "h", appID: 1))
        context.hasContextMenu = true
        context.screenHints.adjustable = true
        #expect(labels(context) == ["Adjust", "Previous tab", "Next tab", "Change", "Back"])
        context.screenHints.rowOptions = true
        #expect(labels(context) == ["Adjust", "Previous tab", "Next tab", "Change", "Options", "Back"])
    }

    @Test func theLibraryFilterSheetClosesWithYAndB() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        context.screenHints.sheetOpen = true
        #expect(labels(context) == ["Select", "Reset", "Close", "Close"])
    }

    @Test func aRowPopoverHasThePickersHints() {
        var context = ShellHints.Context(screen: .settings)
        context.screenHints.rowPopup = .options
        #expect(labels(context) == ["Select", "Close"])
        context.screenHints.rowPopup = .slider
        #expect(labels(context) == ["Adjust", "Done", "Close"])
    }
}
