import DelosData
import DelosInput
import Foundation
import Testing
@testable import DelosUI

@MainActor
@Suite struct ArtworkInputTests {
    @Test func aScreenThatIsLeftDoesNotClearTheCaptureOfTheOneThatCame() {
        // The library is removed after the Artwork screen appeared (the transition), and cleared the capture it no longer owned:
        // X, Y and the directions of the open sheet then went to the focus of the grid.
        let navigator = Navigator(root: .start)
        let library = FocusModel(), artwork = FocusModel()
        navigator.takeInput(library) { _ in false }
        navigator.takeInput(artwork) { _ in true }
        navigator.screenHints = ScreenHints(sheetOpen: true)
        navigator.releaseInput(library)
        #expect(navigator.commandCapture?(.toastAction) == true)
        #expect(navigator.screenHints.sheetOpen)
        // Its own release still clears
        navigator.releaseInput(artwork)
        #expect(navigator.commandCapture == nil && navigator.screenHints == ScreenHints())
    }

    @Test func theScreensCommandsAreXSearchYSheetAndTheSheetTakesEverything() {
        func route(_ command: MenuCommand, sheet: Bool = false, toast: Bool = false) -> ArtworkCommand {
            ArtworkCommand.route(command, sheetOpen: sheet, toastOwnsY: toast)
        }
        #expect(route(.options) == .search)
        #expect(route(.toastAction) == .openSheet)
        #expect(route(.toastAction, toast: true) == .pass)
        #expect(route(.previousTab) == .tab(-1) && route(.nextTab) == .tab(1))
        for command in [MenuCommand.up, .down, .left, .right, .accept, .back, .menu] { #expect(route(command) == .pass) }
        // The open sheet consumes every command: none reaches the grid behind it
        let all: [MenuCommand] = [.up, .down, .left, .right, .accept, .back, .menu, .options, .toastAction, .previousTab, .nextTab]
        for command in all { #expect(route(command, sheet: true) != .pass, "\(command) with the sheet open") }
        #expect(route(.up, sheet: true) == .sheetMove && route(.right, sheet: true) == .sheetMove)
        #expect(route(.back, sheet: true) == .closeSheet && route(.toastAction, sheet: true, toast: true) == .closeSheet)
        #expect(route(.options, sheet: true) == .resetFilters && route(.accept, sheet: true) == .sheetAccept)
    }

    @Test func theFilterSheetTrapsTheFocusAndBGivesItBackToThePill() async {
        let model = await makeArtworkModel()
        await model.load()
        // The grid's focus: on the Filter pill, with a tile below it
        let focus = FocusModel(initial: ArtworkScreen.filterID)
        for (id, y) in [(ArtworkScreen.searchID, 0.0), (ArtworkScreen.filterID, 0), (ArtworkScreen.tileID(1), 200)] {
            focus.register(AnyHashable(id), frame: CGRect(x: id == ArtworkScreen.searchID ? 0 : 300, y: y, width: 200, height: 60), action: {})
        }
        // Y opens the sheet; its focus is its own and starts on its first option
        #expect(ArtworkCommand.route(.toastAction, sheetOpen: model.sheetOpen, toastOwnsY: false) == .openSheet)
        model.openSheet(returningTo: focus.focused)
        #expect(model.sheetOpen)
        #expect(model.sheetFocus.focused == AnyHashable(ArtworkFilterSheet.startID(kind: .cover, filters: ArtFilters())))
        // The sheet's chips are in one row and one below; the directions move the sheet's focus and never the grid's
        let first = ArtworkFilterSheet.optionID("type:all"), second = ArtworkFilterSheet.optionID("type:still")
        let below = ArtworkFilterSheet.optionID("style:")
        for (id, x, y) in [(first, 0.0, 0.0), (second, 200.0, 0.0), (below, 0.0, 100.0)] {
            model.sheetFocus.register(AnyHashable(id), frame: CGRect(x: x, y: y, width: 150, height: 60), action: {})
        }
        #expect(ArtworkCommand.route(.right, sheetOpen: true, toastOwnsY: false) == .sheetMove)
        #expect(model.sheetFocus.handle(.right) && model.sheetFocus.focused == AnyHashable(second))
        #expect(model.sheetFocus.handle(.left) && model.sheetFocus.handle(.down) && model.sheetFocus.focused == AnyHashable(below))
        #expect(focus.focused == AnyHashable(ArtworkScreen.filterID))
        // B closes it and the focus is back on the pill
        #expect(ArtworkCommand.route(.back, sheetOpen: true, toastOwnsY: false) == .closeSheet)
        model.closeSheet(restoring: focus)
        #expect(!model.sheetOpen && focus.focused == AnyHashable(ArtworkScreen.filterID))
    }
}
