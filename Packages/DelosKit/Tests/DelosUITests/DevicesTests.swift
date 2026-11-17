import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

@MainActor
@Suite struct DevicesTests {
    private func host(_ id: String, _ name: String, online: Bool = true, paired: Bool = true, mac: String? = nil) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus>\
        \(mac.map { "<mac>\($0)</mac>" } ?? "")<state>SUNSHINE_SERVER_FREE</state></root>
        """
        let reply = ServerInfoReply(
            info: try ServerInfo.parse(Data(xml.utf8)), address: HostAddress(host: "192.168.1.5", port: 47989), source: .plainHTTP)
        var record = HostRecord(firstReply: reply)
        if paired { record = record.paired(with: HostPin(certificate: Data([1]), httpsPort: 47984)) }
        return online ? record : record.markedOffline()
    }

    @Test func onlyPairedPCsAreListedByName() throws {
        let hosts = [try host("A", "zeta"), try host("B", "Beta", paired: false), try host("C", "alpha")]
        #expect(DevicesLogic.paired(hosts).map(\.id) == ["C", "A"])
    }

    @Test func statusLines() throws {
        #expect(DevicesLogic.status(try host("A", "a"), active: false) == L("devices_status_online"))
        #expect(DevicesLogic.status(try host("A", "a"), active: true) == L("devices_status_connected"))
        #expect(DevicesLogic.status(try host("A", "a", online: false, mac: "AA:BB:CC:DD:EE:FF"), active: false)
            == L("devices_status_asleep"))
        #expect(DevicesLogic.status(try host("A", "a", online: false), active: false) == L("devices_status_offline"))
    }

    @Test func menuRowsFollowTheState() throws {
        let online = try host("A", "a")
        #expect(DevicesLogic.actions(online, active: false) == [.connect(openApps: false), .rename, .unpair, .remove])
        #expect(DevicesLogic.actions(online, active: true) == [.connect(openApps: true), .rename, .unpair, .remove])
        let asleep = try host("B", "b", online: false, mac: "AA:BB:CC:DD:EE:FF")
        #expect(DevicesLogic.actions(asleep, active: false) == [.connect(openApps: false), .rename, .wake, .remove])
        let offline = try host("C", "c", online: false)
        #expect(DevicesLogic.actions(offline, active: false) == [.connect(openApps: false), .rename, .remove])
    }

    @Test func firstFocusIsTheFirstPCOrPairing() throws {
        #expect(DevicesLogic.firstFocus([]) == "pair")
        #expect(DevicesLogic.firstFocus([try host("A", "a")]) == StartScreen.pcID("A"))
    }

    @Test func everyUnpairResultHasItsSentence() {
        let results: [HostStore.UnpairResult] = [.unpaired, .offline, .notPaired, .failed, .unreachable]
        let texts = results.map { DevicesLogic.unpairText($0, name: "Desk") }
        #expect(Set(texts).count == 5)
        #expect(texts.allSatisfy { $0.contains("Desk") || $0 == L("devices_starting") })
    }

    @Test func devicesIsAScreenOfTheTopNavigationThatTakesTheOthersPlace() {
        #expect(Screen.devices.showsNavigation && Screen.devices.hasSideMenu)
        let navigator = Navigator(root: .start)
        navigator.push(.home(hostID: "A"))
        navigator.openFromNavigation(.settings)
        navigator.openFromNavigation(.devices)
        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "A"), .devices])
        navigator.openFromNavigation(.profile)
        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "A"), .profile])
    }

    @Test func aRemovedPCLeavesNoLibraryBelowTheShownScreen() {
        let navigator = Navigator(root: .start)
        navigator.push(.home(hostID: "A"))
        navigator.push(.devices)
        navigator.dropLibrary(of: "B")
        #expect(navigator.stack.count == 3)
        navigator.dropLibrary(of: "A")
        #expect(navigator.stack.map(\.screen) == [.start, .devices])
    }

    @Test func theNavigationButtonsAreSettingsProfileDevices() {
        let buttons = TopNav.buttons(current: .devices, onSettings: {}, onProfile: {}, onDevices: {})
        #expect(buttons.map(\.id) == ["nav-settings", "nav-profile", "nav-devices"])
        #expect(buttons.filter(\.current).map(\.id) == ["nav-devices"])
    }
}
