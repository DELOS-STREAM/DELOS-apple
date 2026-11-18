import DelosHost
import Foundation
import SwiftUI
import Testing
@testable import DelosUI

/// Links and `.art` files from outside the app (`ShellLink.kt`, the link effect of `Shell.kt`, ShortcutTrampoline and
/// `ArtFile` of DELOS for Android).
@MainActor @Suite struct ShellLinkTests {
    private let pcUUID = "6A8F2C1E-3B4D-4E5F-8A9B-0C1D2E3F4A5B"

    @Test func aPairingLinkKeepsTheAddressAsWrittenAndItsOneTimeCode() {
        #expect(ShellLink(URL(string: "art://192.168.1.20:47989?pin=1234&passphrase=abcd&name=Desk")!)
            == .pair(address: "192.168.1.20:47989", name: "Desk", code: OneTimeCode(pin: "1234", passphrase: "abcd")))
        #expect(ShellLink(URL(string: "art://[fe80::1]:47989")!) == .pair(address: "[fe80::1]:47989", name: nil, code: nil))
        // A PIN without its passphrase is no code: plain pairing
        #expect(ShellLink(URL(string: "art://desk.local?pin=1234")!) == .pair(address: "desk.local", name: nil, code: nil))
    }

    @Test func aLaunchLinkCarriesItsValuesUnchecked() {
        let link = ShellLink(URL(string: "art://launch?host_uuid=x&host_name=Desk&app_id=7&app_name=Hades")!)
        #expect(link == .launch(LaunchLink(hostUUID: "x", hostName: "Desk", appUUID: nil, appID: "7", appName: "Hades")))
        // With a port it is a PC called "launch", as on Android
        #expect(ShellLink(URL(string: "art://launch:47989")!) == .pair(address: "launch:47989", name: nil, code: nil))
    }

    @Test func otherLinksAreNotDelosLinks() {
        #expect(ShellLink(URL(string: "https://example.com/launch")!) == nil)
        #expect(ShellLink(URL(string: "art:")!) == nil)
    }

    @Test func theStartPromptNamesWhatTheLinkNames() {
        let both = LaunchLink(hostName: "Desk", appName: "Hades").prompt
        #expect(both.title == L("shell_link_start_title", "Hades"))
        #expect(both.message == L("shell_link_start_message", "Hades", "Desk"))
        #expect(LaunchLink(appName: "Hades").prompt.message == L("shell_link_start_message_game", "Hades"))
        let host = LaunchLink(hostName: "Desk", appName: "").prompt
        #expect(host.title == L("shell_link_start_title_unnamed"))
        #expect(host.message == L("shell_link_start_message_host", "Desk"))
        #expect(LaunchLink().prompt.message == L("shell_link_start_message_unnamed"))
    }

    @Test func theTargetIsValidatedLikeTheShortcutTrampoline() {
        #expect(LaunchLink().target == .invalid("scut_invalid_uuid"))
        #expect(LaunchLink(hostUUID: "not-a-uuid", hostName: "Desk").target == .invalid("scut_invalid_uuid"))
        #expect(LaunchLink(hostUUID: "", hostName: "").target == .invalid("scut_invalid_uuid"))
        #expect(LaunchLink(hostUUID: pcUUID).target == .host(id: pcUUID, name: nil, app: nil))
        #expect(LaunchLink(hostName: "Desk", appID: "x").target == .invalid("scut_invalid_app_id"))
        #expect(LaunchLink(hostName: "Desk", appUUID: "nope").target == .invalid("scut_invalid_app_id"))
        // The game's UUID wins over its id, its id over its name
        #expect(LaunchLink(hostName: "Desk", appUUID: pcUUID, appID: "7").target == .host(id: nil, name: "Desk", app: .uuid(pcUUID)))
        #expect(LaunchLink(hostName: "Desk", appID: "7", appName: "Hades").target == .host(id: nil, name: "Desk", app: .id(7)))
        #expect(LaunchLink(hostName: "Desk", appName: "Hades").target == .host(id: nil, name: "Desk", app: .name("Hades")))
    }

    @Test func theGameIsFoundByUUIDIdOrNameInAnyCase() {
        let apps = [HostApp(id: 7, title: "Hades", uuid: pcUUID.lowercased()), HostApp(id: 8, title: "Celeste")]
        #expect(ShellActions.resolve(.uuid(pcUUID), in: apps)?.id == 7)
        #expect(ShellActions.resolve(.id(8), in: apps)?.title == "Celeste")
        #expect(ShellActions.resolve(.name("hades"), in: apps)?.id == 7)
        #expect(ShellActions.resolve(.name("Doom"), in: apps) == nil)
    }

    @Test func anArtFileIsReadWholeOrNotAtAll() {
        let file = "# DELOS shortcut\n[host_uuid] \(pcUUID)\r\n\n  [app_name]   Hades  \n[app_id]\n"
        #expect(ArtFile.parse(Data(file.utf8)) == ["host_uuid": pcUUID, "app_name": "Hades"])
        #expect(ArtFile.parse(Data("host_uuid x\n".utf8)) == nil)
        #expect(ArtFile.parse(Data("[host_uuid x\n".utf8)) == nil)
        #expect(ArtFile.parse(Data(repeating: 0x23, count: ArtFile.maxBytes + 1)) == nil)
    }

    @Test func anArtFileAsksLikeALaunchLinkUnlessItNamesNoValidPC() {
        let file = Data("[host_name] Desk\n[app_name] Hades\n".utf8)
        #expect(ShellLink(artFile: file) == .launch(LaunchLink(hostName: "Desk", appName: "Hades")))
        #expect(ShellLink(artFile: Data("[app_name] Hades\n".utf8)) == .rejected("scut_invalid_uuid"))
        #expect(ShellLink(artFile: Data("garbage".utf8)) == .rejected("scut_art_unreadable"))
        #expect(ShellLink(artFile: nil) == .rejected("scut_art_unreadable"))
    }

    @Test func theInboxTakesArtLinksAndArtFilesOnly() throws {
        let inbox = ShellLinkInbox()
        inbox.receive(URL(string: "https://example.com")!)
        #expect(inbox.pending == nil)
        let file = FileManager.default.temporaryDirectory.appending(path: "delos-\(UUID().uuidString).art")
        try Data("[host_name] Desk\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        inbox.receive(file)
        #expect(inbox.take() == .launch(LaunchLink(hostName: "Desk")))
        #expect(inbox.pending == nil)
        inbox.receive(FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).art"))
        #expect(inbox.take() == .rejected("scut_art_unreadable"))
        inbox.receive(FileManager.default.temporaryDirectory.appending(path: "notes.txt"))
        #expect(inbox.pending == nil)
    }

    @Test func theInfoRowBounceTakesItsOverflowAtTheMarqueeSpeed() {
        #expect(BadgeStrip<EmptyView, EmptyView>.bounceLeg(overflow: 112, pxPerSecond: 56) == 2)
        #expect(BadgeStrip<EmptyView, EmptyView>.bounceLeg(overflow: 0, pxPerSecond: 56) > 0)
        #expect(SettingsReadingMotion.startDelay == 0.7 && SettingsReadingMotion.loopDelay == 0.9 && SettingsReadingMotion.speed == 56)
    }
}

#if os(macOS)
/// What the shell does with a link (needs the shell fixture, which is built on the Mac).
@MainActor @Suite struct ShellLinkActionTests {
    private func confirmDialog(_ fx: ShellFixture) -> DialogSpec? {
        if case .dialog(let spec)? = fx.layers.layer { spec } else { nil }
    }

    @Test func aLaunchLinkAsksFirstAndAnUnknownPCIsSaidInAToast() throws {
        let fx = ShellFixture()
        fx.actions.openLink(.launch(LaunchLink(hostName: "Other-PC", appName: "Hades")))
        let spec = try #require(confirmDialog(fx))
        #expect(spec.title == L("shell_link_start_title", "Hades"))
        #expect(spec.confirm == L("shell_link_start_action"))
        #expect(spec.fields.isEmpty)
        #expect(fx.toasts.current == nil)
        #expect(spec.onConfirm([]))
        #expect(fx.toasts.current?.text == L("scut_pc_not_found"))
        #expect(fx.toasts.current?.kind == .error)
    }

    @Test func aPairingLinkAsksWithTheNameAndAddress() throws {
        let fx = ShellFixture()
        fx.actions.openLink(.pair(address: "192.168.1.20", name: "Desk", code: nil))
        let spec = try #require(confirmDialog(fx))
        #expect(spec.title == L("shell_link_pair_title", "Desk (192.168.1.20)"))
        #expect(spec.note == L("shell_link_pair_message"))
        #expect(spec.confirm == L("shell_link_pair_action"))
    }

    @Test func aRefusedFileOnlySaysSo() {
        let fx = ShellFixture()
        fx.actions.openLink(.rejected("scut_art_unreadable"))
        #expect(fx.toasts.current?.text == L("scut_art_unreadable"))
        #expect(!fx.layers.isOpen)
    }

    @Test func theMetadataEntryShowsForEveryGameEvenWithoutAService() throws {
        let fx = ShellFixture(metadataOn: false)
        let game = try #require(fx.actions.gameMenu(hostID: ShellFixture.hostID, app: ShellFixture.library[1]))
        #expect(game.items.contains { $0.label == L("home_menu_metadata") })
        let desktop = try #require(fx.actions.gameMenu(hostID: ShellFixture.hostID, app: ShellFixture.library[0]))
        #expect(!desktop.items.contains { $0.label == L("home_menu_metadata") })
    }
}
#endif
