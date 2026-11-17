#if os(macOS)
import DelosInput
import SwiftUI
import Testing
@testable import DelosUI

/// Who owns the commands, the hints and the focus when screens and layers come and go.
@MainActor
@Suite struct ShellOwnershipTests {
    @Test func aScreenThatIsLeavingDoesNotTakeTheNextScreensCommandsAway() {
        let navigator = Navigator(root: .start)
        let home = FocusModel(), settings = FocusModel()
        var handled: [String] = []
        navigator.capture(for: home) { _ in handled.append("home"); return true }
        // The next screen has appeared and takes the commands; the old one is removed after it (its onDisappear runs now)
        navigator.capture(for: settings) { _ in handled.append("settings"); return true }
        navigator.releaseCapture(of: home)
        _ = navigator.commandCapture?(.accept)
        #expect(handled == ["settings"])
        navigator.releaseCapture(of: settings)
        #expect(navigator.commandCapture == nil)
    }

    @Test func aScreenThatIsLeavingDoesNotWipeTheNextScreensHints() {
        let navigator = Navigator(root: .start)
        let home = FocusModel(), settings = FocusModel()
        navigator.setHints(ScreenHints(filterLabel: "Filter"), from: home)
        navigator.setHints(ScreenHints(adjustable: true), from: settings)
        navigator.clearHints(of: home)
        #expect(navigator.screenHints == ScreenHints(adjustable: true))
        navigator.clearHints(of: settings)
        #expect(navigator.screenHints == ScreenHints())
    }

    @Test func theModalFocusIsThePortalThenTheSideMenuThenALayerThenTheScreensSheet() {
        let fx = ShellFixtureLite()
        let router = fx.router
        #expect(router.modalFocus == nil)
        let sheet = FocusModel()
        fx.navigator.screenModal = sheet
        #expect(router.modalFocus === sheet)
        fx.layers.openDialog(DialogSpec(title: "t", note: "n", fields: [], confirm: "ok") { _ in true })
        #expect(router.modalFocus === fx.layers.focus)
        router.openSideMenu()
        #expect(router.modalFocus === router.sideMenu)
        router.closeSideMenu(sound: nil)
        fx.layers.close()
        #expect(router.modalFocus === sheet)
    }

    @Test func leavingAScreenClosesItsSheet() {
        let navigator = Navigator(root: .start)
        navigator.screenModal = FocusModel()
        navigator.push(.pair)
        #expect(navigator.screenModal == nil)
        navigator.screenModal = FocusModel()
        navigator.back()
        #expect(navigator.screenModal == nil)
    }

    @Test func theTopNavigationAndTheLibraryWrapAndNothingElseDoes() {
        let ids = ["a", "b", "c"]
        #expect(TopNav.wrap(0, of: ids)[.left] == AnyHashable("c"))
        #expect(TopNav.wrap(2, of: ids)[.right] == AnyHashable("a"))
        #expect(TopNav.wrap(1, of: ids).isEmpty)
        #expect(TopNav.wrap(0, of: ["a"]).isEmpty)
        let covers: [AnyHashable] = ["a", "b", "c"]
        #expect(LibraryWrap.moves(index: 0, ids: covers)[.left] == AnyHashable("c"))
        #expect(LibraryWrap.moves(index: 2, ids: covers)[.right] == AnyHashable("a"))
        #expect(LibraryWrap.moves(index: 1, ids: covers).isEmpty)
        // A filter button above the covers is where Up leads, for every cover
        for index in 0..<3 { #expect(LibraryWrap.moves(index: index, ids: covers, up: "library-filter")[.up] == AnyHashable("library-filter")) }
    }
}
#endif
