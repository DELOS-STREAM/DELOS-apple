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

    @Test func touchAndPointerKeepOnlyThePrimaryAction() {
        var context = ShellHints.Context(screen: .home(hostID: "h"))
        context.hasContextMenu = true
        #expect(adapted(.touch, context) == [.tap])
        #expect(adapted(.pointer, context) == [.click])
        let hints = ShellHints.adapt(ShellHints.hints(context, kind: .controller), to: .touch)
        #expect(hints.first?.label == ShellHints.hints(context, kind: .controller).first?.label)
    }

    @Test func theKeyboardHasReturnEscapeAndTheArrows() {
        var settings = ShellHints.Context(screen: .settings)
        settings.screenHints.adjustable = true
        #expect(adapted(.keyboard, settings) == [.key(.arrows), .key(.returnKey), .key(.escape)])
        // No key for the tabs, search (Y) or the menu buttons
        #expect(adapted(.keyboard, ShellHints.Context(screen: .home(hostID: "h"))) == [.key(.returnKey)])
        #expect(adapted(.controller, settings) == buttons(settings))
    }

    @Test func theBackArrowIsForEveryInputButAController() {
        for kind in InputKind.allCases { #expect(InputKindRule.withoutController.shows(kind) == (kind != .controller)) }
        #expect(InputKindRule.withController.shows(.controller))
        #expect(!InputKindRule.withController.shows(.touch))
    }
}
