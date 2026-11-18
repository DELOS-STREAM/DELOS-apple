import Testing
@testable import DelosUI

@MainActor
struct StreamMenuModelTests {
    typealias L = StreamMenuLayout

    @Test func theTilesFollowAndroidsOrderAndTheDevice() {
        let phone = StreamMenuCapabilities(systemKeyboard: true, brightness: true)
        #expect(phone.tiles == [.resume, .keyboard, .overlay, .brightness, .more, .disconnect, .quit])
        // The Delos full keyboard is on every device; only the system keyboard's More row needs one
        let desktop = StreamMenuCapabilities(systemKeyboard: false, brightness: false)
        #expect(desktop.tiles == [.resume, .keyboard, .overlay, .more, .disconnect, .quit])
        #expect(Set(BarItem.allCases.map(\.id)).count == BarItem.allCases.count)
        #expect(BarItem(id: AnyHashable("stream-more")) == .more)
        #expect(BarItem(id: AnyHashable("elsewhere")) == nil)
        #expect(BarItem(id: nil) == nil)
    }

    @Test func theKeyboardTilesHelpNamesItsButtonsAndTheSystemKeyboardOnlyWhereMoreHasIt() {
        let phone = StreamMenuText.caption(.keyboard, capabilities: StreamMenuCapabilities(systemKeyboard: true, brightness: true))
        #expect(phone == DelosUI.L("stream_help_delos_keyboard_system", "A", "B"))
        let desktop = StreamMenuText.caption(.keyboard, capabilities: StreamMenuCapabilities(systemKeyboard: false, brightness: false))
        #expect(desktop == DelosUI.L("stream_help_delos_keyboard", "A", "B"))
        #expect(!desktop.isEmpty && desktop != phone)
    }

    @Test func backGoesOneLevelUpToTheRowOrTheTile() {
        #expect(StreamMenuNavigation.afterBack(.main) == nil)
        #expect(StreamMenuNavigation.afterBack(.more) == PageExit(page: .main, focusTile: .more, focusRow: nil))
        #expect(StreamMenuNavigation.afterBack(.brightness) == PageExit(page: .main, focusTile: .brightness, focusRow: nil))
        #expect(StreamMenuNavigation.afterBack(.keys) == PageExit(page: .more, focusTile: nil, focusRow: .keys))
        #expect(StreamMenuNavigation.afterBack(.commands) == PageExit(page: .more, focusTile: nil, focusRow: .commands))
    }

    @Test func aTapOutsideClosesThePopoverOnlyAndNeverResumes() {
        #expect(StreamMenuNavigation.afterDismiss(.main) == nil)
        #expect(StreamMenuNavigation.afterDismiss(.keys) == PageExit(page: .main, focusTile: .more, focusRow: nil))
        #expect(StreamMenuNavigation.afterDismiss(.brightness) == PageExit(page: .main, focusTile: .brightness, focusRow: nil))
    }

    @Test func aTileWithoutAPageDoesNothingWhileAPopoverIsOpen() {
        #expect(StreamMenuNavigation.tileWorks(opensPage: false, popoverOpen: false))
        #expect(StreamMenuNavigation.tileWorks(opensPage: true, popoverOpen: true))
        #expect(!StreamMenuNavigation.tileWorks(opensPage: false, popoverOpen: true))
    }

    @Test func theDockWrapsAtBothEnds() {
        #expect(StreamMenuNavigation.wrapped(6, count: 7, step: 1) == 0)
        #expect(StreamMenuNavigation.wrapped(0, count: 7, step: -1) == 6)
        #expect(StreamMenuNavigation.wrapped(3, count: 7, step: 1) == 4)
        #expect(StreamMenuNavigation.wrapped(0, count: 0, step: 1) == 0)
    }

    @Test func thePopoverSitsOverItsTileWithinTheMargins() {
        let width = L.popoverWidth(.more)
        #expect(width == 920 && L.popoverWidth(.brightness) == 780 && L.popoverWidth(.keys) == 920)
        // Centered where it fits
        #expect(L.popoverLeft(anchorX: 960, width: 780, stageWidth: 1920) == 570)
        // Pushed against the right margin: 1920 - 120 - 920
        #expect(L.popoverLeft(anchorX: 1800, width: 920, stageWidth: 1920) == 880)
        #expect(L.popoverLeft(anchorX: 100, width: 920, stageWidth: 1920) == 120)
        // The caret keeps 72 from the corners and still points at the tile
        #expect(L.caretCenter(anchorX: 1800, left: 880, width: 920) == 848)
        #expect(L.caretCenter(anchorX: 100, left: 120, width: 920) == 72)
        #expect(L.caretCenter(anchorX: 500, left: 120, width: 920) == 380)
        // A stage narrower than the card gives it what is left between the margins
        #expect(L.popoverWidth(.more, stageWidth: 900) == 660)
    }

    @Test func theCardsHeightFollowsItsRowsAndTheHelp() {
        #expect(L.helpLines(textScale: 1) == 2 && L.helpLines(textScale: 1.15) == 2 && L.helpLines(textScale: 1.3) == 3)
        #expect(L.rowsHeight(0) == 0 && L.rowsHeight(1) == 72 && L.rowsHeight(3) == 3 * 72 + 2 * 8)
        // The Brightness card: 30 + 64 + 12 + 72 + 18 + 2 lines of help (22 x 1.4) + 24
        #expect(abs(L.naturalHeight(rows: 1, textScale: 1) - (30 + 64 + 12 + 72 + 18 + 61.6 + 24)) < 0.001)
        #expect(abs(L.captionHeight(textScale: 1) - 117.6) < 0.001)
        // From the card's bottom (734) up to the 120 margin: 614, as Android's popoverMaxHeight
        #expect(L.maxHeight(stageHeight: 1080) == 614)
        #expect(L.maxHeight(stageHeight: 1440) == 974)
    }

    @Test func aRowOfTilesThatFitsIsCenteredAndOneThatDoesNotScrolls() {
        let roomy = DockGeometry(count: 7, width: 1920)
        #expect(!roomy.scrolls && roomy.tilesLeft == 315 && roomy.rowWidth == 1290)
        #expect(roomy.tileCenter(0) == 390)
        let narrow = DockGeometry(count: 7, width: 1200)
        #expect(narrow.scrolls && narrow.tilesLeft == 80 && narrow.contentWidth == 1450)
        #expect(narrow.tileCenter(1) == 80 + 190 + 75)
    }
}
