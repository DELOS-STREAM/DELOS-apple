#if os(macOS)
import DelosData
import DelosHost
import DelosInput
import SwiftUI
import Testing
@testable import DelosUI

/// The controller's way through the real shell: the real screens, the real router, the real focus engine, a window that is
/// never shown. B leaves to the right parent, an open layer traps the commands and gives the focus back, nothing loses its
/// focus.
@MainActor
@Suite struct ShellFlowTests {
    private let hostID = ShellFixture.hostID
    private var pc: String { StartScreen.pcID(hostID) }

    /// The library of the PC, open above the start screen, focused on the first cover.
    private func library(_ device: TestDevice = TestDevice.all[0], metadata: Bool = true, seeded: Bool = false) async -> ShellHarness {
        let shell = ShellHarness(device: device, metadataOn: metadata)
        if seeded { shell.fx.seedMetadata() }
        await shell.waitFor(pc)
        shell.navigator.openHome(hostID: hostID)
        await shell.waitFor("app-1")
        return shell
    }

    // MARK: Back

    @Test func backFromTheLibraryReturnsToTheStartScreenOnItsPC() async {
        let shell = await library()
        #expect(shell.focused == "app-1")
        shell.press(.back)
        #expect(shell.navigator.current == .start)
        _ = await shell.waitFor(pc)
        #expect(shell.focused == pc)
        // The first screen has nowhere to go back to: B does nothing
        shell.press(.back)
        #expect(shell.navigator.current == .start && shell.navigator.stack.count == 1)
    }

    @Test func theTopNavigationOpensSettingsProfileAndDevicesAndBGoesBackToTheLibrary() async {
        let shell = await library()
        let wanted: [(id: String, screen: Screen)] = [("nav-settings", .settings), ("nav-profile", .profile), ("nav-devices", .devices)]
        for (id, screen) in wanted {
            shell.press(.up)
            #expect(shell.focused?.hasPrefix("nav-") == true, "Up from a cover reaches the navigation")
            // The cycle: Settings, Profile, Devices
            for _ in 0..<3 where shell.focused != id { shell.press(.right) }
            shell.letGatesPass()
            shell.press(.accept)
            #expect(shell.navigator.current == screen)
            // The screens of the navigation take each other's place: below them is the library
            #expect(shell.navigator.stack.map(\.screen) == [.start, .home(hostID: hostID), screen])
            shell.press(.back)
            #expect(shell.navigator.current == .home(hostID: hostID))
            await shell.waitFor("app-1")
            // The focus is where it was when the library was left: on the navigation button that was pressed
            #expect(shell.focused == id)
            shell.focusFirstCover()
        }
    }

    @Test func downFromTheTopNavigationReturnsToTheCoverTheFocusCameFrom() async {
        let shell = await library()
        shell.pressAll(.right, .right)
        let cover = try! #require(shell.focused)
        #expect(cover != "app-1")
        shell.press(.up)
        #expect(shell.focused?.hasPrefix("nav-") == true)
        // Along the navigation and back down: the cover the focus went up from, not the one under the button
        for _ in 0..<3 {
            shell.press(.right)
            shell.press(.down)
            #expect(shell.focused == cover)
            shell.press(.up)
        }
        // Within the row the covers still follow each other
        shell.press(.down)
        shell.press(.left)
        #expect(shell.focused != cover && shell.focused?.hasPrefix("app-") == true)
    }

    @Test func settingsProfileAndDevicesTakeEachOthersPlace() async {
        let shell = await library()
        shell.goToNavigation("nav-settings")
        shell.letGatesPass()
        shell.press(.accept)
        #expect(shell.navigator.current == .settings)
        await shell.waitFor(SettingsScreen.initialFocus)
        // From the first row Up reaches the navigation; Right goes on to Profile
        shell.press(.up)
        #expect(shell.focused == "nav-settings")
        shell.press(.right)
        shell.letGatesPass()
        shell.press(.accept)
        #expect(shell.navigator.stack.map(\.screen) == [.start, .home(hostID: hostID), .profile])
        await shell.waitFor("change-avatar")
        shell.press(.back)
        #expect(shell.navigator.current == .home(hostID: hostID))
    }

    @Test func pairingAndProfileEditingGoBackToWhereTheyWereOpenedFrom() async {
        let shell = ShellHarness()
        await shell.waitFor("pair")
        shell.focusItem("pair")
        shell.letGatesPass()
        shell.press(.accept)
        #expect(shell.navigator.current == .pair)
        await shell.waitFor("address")
        shell.press(.back)
        #expect(shell.navigator.current == .start)
        await shell.waitFor("pair")
        #expect(shell.focused == "pair")
    }

    // MARK: The context menu

    @Test func aGameMenuHoldsTheCommandsAndGivesTheFocusBack() async {
        let shell = await library()
        shell.press(.options)
        #expect(shell.layers.isOpen)
        #expect(shell.layers.focus.focused == Layers.rowID(0))
        await shell.waitForLayer(Layers.rowID(2))
        // Nothing reaches the library behind the menu
        shell.press(.down)
        #expect(shell.layers.focus.focused == Layers.rowID(1))
        shell.press(.left)
        shell.press(.right)
        shell.press(.up)
        #expect(shell.layers.focus.focused == Layers.rowID(0))
        #expect(shell.focused == "app-1")
        // The side menu and the tabs are not for a menu
        shell.press(.menu)
        #expect(shell.router.sideMenu == nil)
        shell.press(.back)
        #expect(!shell.layers.isOpen)
        #expect(shell.focused == "app-1")
        #expect(shell.navigator.current == .home(hostID: hostID))
    }

    @Test func theButtonThatOpenedTheMenuClosesItToo() async {
        let shell = await library()
        shell.press(.options)
        #expect(shell.layers.isOpen)
        shell.press(.options)
        #expect(!shell.layers.isOpen)
        #expect(shell.focused == "app-1")
    }

    // MARK: The side menu

    @Test func theSideMenuTakesEveryCommandAndLeavesTheScreenAlone() async {
        let shell = await library()
        shell.press(.menu)
        let menu = try! #require(shell.router.sideMenu)
        #expect(menu.focused == AnyHashable(QuickSettings.ids[0]))
        #expect(shell.router.modalFocus === menu)
        for command in [MenuCommand.down, .down, .up, .left, .right, .options, .toastAction, .previousTab, .nextTab] {
            shell.press(command)
            #expect(shell.focused == "app-1", "\(command) must not reach the library behind the menu")
            #expect(shell.navigator.current == .home(hostID: hostID))
            #expect(shell.router.sideMenu === menu)
        }
        // B closes it and does not leave the library
        shell.press(.back)
        #expect(shell.router.sideMenu == nil)
        #expect(shell.navigator.current == .home(hostID: hostID))
        #expect(shell.focused == "app-1")
        // The menu button opens it and closes it, always on the first row
        shell.press(.menu)
        #expect(shell.router.sideMenu?.focused == AnyHashable(QuickSettings.ids[0]))
        shell.press(.menu)
        #expect(shell.router.sideMenu == nil)
    }

    @Test func theSideMenuIsOnlyOnTheScreensAndroidGivesIt() async {
        let shell = ShellHarness()
        await shell.waitFor(pc)
        shell.press(.menu)
        #expect(shell.router.sideMenu != nil, "the start screen has it")
        shell.press(.back)
        shell.navigator.push(.pair, focus: "address")
        await shell.waitFor("address")
        shell.press(.menu)
        #expect(shell.router.sideMenu == nil, "pairing has none")
        shell.navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0))
        await shell.waitFor(CreateProfileScreen.avatarID(0))
        shell.press(.menu)
        #expect(shell.router.sideMenu == nil, "creating a profile has none")
    }

    // MARK: The filter sheet

    @Test func theFilterSheetTrapsTheCommandsAndReturnsTheFocusToTheCover() async {
        let shell = await library(seeded: true)
        shell.press(.right)
        let cover = shell.focused
        #expect(cover == "app-10")
        shell.press(.toastAction)
        await shell.host.until { shell.navigator.screenModal != nil }
        let sheet = try! #require(shell.navigator.screenModal)
        #expect(shell.router.modalFocus === sheet)
        #expect(sheet.focused == AnyHashable(LibraryFilterIDs.genre(nil)))
        for command in [MenuCommand.down, .down, .up, .left, .right, .menu, .previousTab, .nextTab] {
            shell.press(command)
            #expect(shell.focused == cover, "\(command) must not reach the library behind the sheet")
            #expect(shell.router.sideMenu == nil)
            #expect(shell.navigator.screenModal === sheet)
            #expect(sheet.focused != nil)
        }
        shell.press(.back)
        await shell.host.until { shell.navigator.screenModal == nil }
        #expect(shell.navigator.screenModal == nil)
        #expect(shell.focused == cover)
        #expect(shell.navigator.current == .home(hostID: hostID))
    }

    @Test func aToastWithAnActionKeepsYFromTheFilter() async {
        let shell = await library(seeded: true)
        var undone = 0
        shell.fx.toasts.show("Deleted", icon: Symbols.delete, action: ToastAction(label: "Undo") { undone += 1 })
        shell.press(.toastAction)
        #expect(undone == 1)
        #expect(shell.navigator.screenModal == nil)
    }

    @Test(arguments: [MenuCommand.back, .toastAction, .accept])
    func closingTheFilterSheetGivesTheDPadBackToTheLibrary(_ close: MenuCommand) async {
        let shell = await library(seeded: true)
        shell.press(.toastAction)
        await shell.host.until { shell.navigator.screenModal != nil }
        let sheet = try! #require(shell.navigator.screenModal)
        await shell.host.until { sheet.registeredFrames[LibraryFilterIDs.show] != nil }
        // B and Y close it anywhere, A on the "Show N apps" pill
        if close == .accept { sheet.focus(LibraryFilterIDs.show) }
        shell.letGatesPass()
        shell.press(close)
        await shell.host.until { shell.navigator.screenModal == nil }
        #expect(shell.navigator.screenModal == nil)
        #expect(shell.focused == "app-1")
        await shell.expectTheDPadMovesTheLibrary(from: "app-1")
    }

    @Test(arguments: [MenuCommand.back, .toastAction])
    func theSheetsChoicesFilterTheLibraryOnlyOnceConfirmed(_ close: MenuCommand) async {
        let shell = await library(seeded: true)
        let filters = shell.fx.actions.libraryFilters
        shell.press(.toastAction)
        await shell.host.until { shell.navigator.screenModal != nil }
        let sheet = try! #require(shell.navigator.screenModal)
        await shell.host.until { sheet.registeredFrames[LibraryFilterIDs.genre(31)] != nil }
        shell.letGatesPass()
        // Two genres and HDR: the chips toggle, the library stays as it is
        for chip in [LibraryFilterIDs.genre(5), LibraryFilterIDs.genre(31), LibraryFilterIDs.hdr(.hdr)] {
            sheet.focus(chip)
            shell.press(.accept)
        }
        #expect(filters.filters(hostID: hostID) == MetadataFilters())
        // B drops the choices, Y applies them
        shell.press(close)
        await shell.host.until { shell.navigator.screenModal == nil }
        #expect(filters.filters(hostID: hostID) == (close == .toastAction ? MetadataFilters(genres: [5, 31], hdr: [.hdr]) : MetadataFilters()))
    }

    // MARK: The portal

    @Test func thePortalOpensTheLibraryWithTheDPadWorkingAtOnce() async {
        let shell = ShellHarness()
        shell.fx.actions.connection.reducedMotion = true
        await shell.waitFor(pc)
        #expect(shell.focused == pc)
        shell.letGatesPass()
        shell.press(.accept)
        await shell.host.until { shell.fx.actions.connection.isActive }
        #expect(shell.fx.actions.connection.isActive)
        // The portal holds every command but B
        shell.press(.right)
        #expect(shell.navigator.current == .start)
        #expect(shell.focused == pc)
        for _ in 0..<3 where shell.navigator.current == .start { await shell.host.until { shell.navigator.current != .start } }
        #expect(shell.navigator.stack.map(\.screen) == [.start, .home(hostID: hostID)])
        await shell.host.until { !shell.fx.actions.connection.isActive && shell.focused == "app-1" }
        #expect(!shell.fx.actions.connection.isActive)
        #expect(shell.focused == "app-1")
        await shell.expectTheDPadMovesTheLibrary(from: "app-1")
    }
}

extension ShellHarness {
    /// Up until the top navigation has the focus, then round it to [id].
    func goToNavigation(_ id: String) {
        for _ in 0..<3 where focused?.hasPrefix("nav-") != true { press(.up) }
        for _ in 0..<3 where focused != id { press(.right) }
    }

    func focusItem(_ id: String) { navigator.focus.focus(id) }
    func focusFirstCover() { navigator.focus.focus("app-1") }

    /// Right moves to the next cover, Left back to [cover], Up to the top navigation: the library's D-pad works.
    func expectTheDPadMovesTheLibrary(from cover: String) async {
        await waitFor("app-10")
        press(.right)
        #expect(focused?.hasPrefix("app-") == true && focused != cover, "Right moves to the next cover")
        press(.left)
        #expect(focused == cover, "Left moves back")
        press(.up)
        #expect(focused?.hasPrefix("nav-") == true, "Up reaches the navigation")
    }
}
#endif
