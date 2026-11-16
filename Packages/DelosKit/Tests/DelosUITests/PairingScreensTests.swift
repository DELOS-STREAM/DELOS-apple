import DelosHost
import Foundation
import Testing
@testable import DelosUI

@Suite struct PairingScreensTests {
    private func host(_ id: String, _ name: String, online: Bool = true, paired: Bool = false, mac: String? = nil, running: Int = 0) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>\(name)</hostname><uniqueid>\(id)</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><currentgame>\(running)</currentgame>\
        \(mac.map { "<mac>\($0)</mac>" } ?? "")<state>SUNSHINE_SERVER_FREE</state></root>
        """
        let reply = ServerInfoReply(
            info: try ServerInfo.parse(Data(xml.utf8)), address: HostAddress(host: "192.168.1.5", port: 47989), source: .plainHTTP)
        var record = HostRecord(firstReply: reply)
        if paired { record = record.paired(with: HostPin(certificate: Data([1]), httpsPort: 47984)) }
        return online ? record : record.markedOffline()
    }

    @Test func foundPCsComeFirstOnlineBeforeOfflineThenPairedOnes() throws {
        let hosts = [
            try host("A", "zeta", paired: true), try host("B", "Beta", online: false), try host("C", "alpha", paired: true),
            try host("D", "Gamma"), try host("E", "delta"),
        ]
        #expect(PairList.shown(hosts).map(\.id) == ["E", "D", "B", "C", "A"])
    }

    @Test func pairingStatusLines() throws {
        #expect(PairList.status(try host("A", "a")) == "pairing_pc_ready")
        #expect(PairList.status(try host("A", "a", online: false)) == "pairing_pc_offline")
        #expect(PairList.status(try host("A", "a", paired: true)) == "pairing_pc_paired_online")
        #expect(PairList.status(try host("A", "a", online: false, paired: true)) == "pairing_pc_paired_offline")
    }

    @Test func startScreenStatusLines() throws {
        #expect(StartScreen.status(try host("A", "a", paired: true), isDefault: false) == L("devices_status_online"))
        #expect(StartScreen.status(try host("A", "a", online: false, paired: true, mac: "AA:BB:CC:DD:EE:FF"), isDefault: false)
            == L("devices_status_asleep_wakes"))
        #expect(StartScreen.status(try host("A", "a", online: false, paired: true), isDefault: false) == L("devices_status_offline"))
        // The default PC says so after its state
        #expect(StartScreen.status(try host("A", "a", paired: true), isDefault: true)
            == L("devices_status_with_default", L("devices_status_online"), L("devices_status_default")))
    }

    @Test func addressEntry() {
        #expect(AddressEntry("  ") == .empty)
        #expect(AddressEntry("desk pc") == .invalid)
        #expect(AddressEntry("192.168.1.20:5000") == .address(HostAddress(host: "192.168.1.20", port: 5000)))
        #expect(AddressEntry(" desk.local ") == .address(HostAddress(host: "desk.local", port: HostAddress.defaultHTTPPort)))
    }

    @Test func pairingOutcomesBecomeAndroidsMessages() {
        #expect(PairFailure(.paired(HostPin(certificate: Data([1]), httpsPort: 1)), runningAppID: 0) == nil)
        #expect(PairFailure(.pinWrong, runningAppID: 0) == .pinWrong)
        #expect(PairFailure(.alreadyInProgress, runningAppID: 0) == .busy)
        #expect(PairFailure(.failed, runningAppID: 0) == .failed)
        #expect(PairFailure(.failed, runningAppID: 7) == .gameRunning)
        #expect(PairFailure(HostError.unreachable("x")) == .offline)
        #expect(PairFailure(HostError.timedOut) == .offline)
        #expect(PairFailure(HostError.httpStatus(404)) == .unsupported)
        #expect(PairFailure(HostError.certificateMismatch) == .failed)
        #expect(PairFailure.busy.key == "pairing_failed_busy")
    }

    @Test func aRefusedProofOfAOneTimeCodeSaysTheCodeWasWrong() {
        #expect(PairFailure(.pinWrong, runningAppID: 0, oneTime: true) == .codeWrong)
        #expect(PairFailure(.pinWrong, runningAppID: 0, oneTime: false) == .pinWrong)
        #expect(PairFailure(.failed, runningAppID: 0, oneTime: true) == .failed)
        #expect(PairFailure(.alreadyInProgress, runningAppID: 0, oneTime: true) == .busy)
        #expect(PairFailure.codeWrong.key == "pairing_failed_code_wrong")
        #expect(PairFailure.codeWrong.text(pcName: "PC") == L("pairing_failed_code_wrong"))
    }

    @Test func oneTimeCodeEntry() {
        #expect(OneTimeCode.Entry(pin: "4821", passphrase: "abcd") == .code(OneTimeCode(pin: "4821", passphrase: "abcd")))
        #expect(OneTimeCode.Entry(pin: "482", passphrase: "abcd") == .pinInvalid)
        #expect(OneTimeCode.Entry(pin: "48211", passphrase: "abcd") == .pinInvalid)
        #expect(OneTimeCode.Entry(pin: "", passphrase: "") == .pinInvalid)
        #expect(OneTimeCode.Entry(pin: "4821", passphrase: "abc") == .passphraseTooShort)
        #expect(OneTimeCode.Entry(pin: "4821", passphrase: "abc").errorKey == "pairing_otp_passphrase_error")
        #expect(OneTimeCode.Entry(pin: "12", passphrase: "x").errorKey == "pairing_otp_pin_error")
        #expect(OneTimeCode.Entry(pin: "4821", passphrase: "abcd").errorKey == nil)
    }

    @MainActor @Test func theMenuOfAPCNotPairedYetOffersPinAndCodeAndAPairedOneHasNone() throws {
        var chosen: [String] = []
        let found = try host("A", "Desk")
        let menu = try #require(PairPCScreen.menu(found, onPin: { chosen.append("pin-" + $0.id) }, onCode: { chosen.append("code-" + $0.id) }))
        #expect(menu.items.map(\.label) == [L("pairing_pc_with_pin"), L("pairing_pc_with_code")])
        #expect(menu.below)
        menu.items.forEach { $0.action() }
        #expect(chosen == ["pin-A", "code-A"])
        #expect(PairPCScreen.menu(try host("B", "b", paired: true), onPin: { _ in }, onCode: { _ in }) == nil)
    }

    @MainActor @Test func pairingWithACodeLeavesLikeAPinAndKeepsTheCode() {
        let navigator = Navigator(root: .start, focus: "pair")
        navigator.push(.pair)
        let code = OneTimeCode(pin: "4821", passphrase: "abcd")
        navigator.push(.pairCode(hostID: "A", code: code), focus: "cancel")
        #expect(navigator.current == .pairCode(hostID: "A", code: code))
        #expect(navigator.back())
        #expect(navigator.current == .pair)
        navigator.push(.pairCode(hostID: "A", code: code))
        navigator.openHome(hostID: "A")
        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "A")])
    }

    @Test func homeContent() {
        let app = HostApp(id: 1, title: "Desktop")
        #expect(HomeContent(apps: nil, loadFailed: false) == .loading)
        #expect(HomeContent(apps: nil, loadFailed: true) == .offline)
        #expect(HomeContent(apps: [app], loadFailed: true) == .offline)
        #expect(HomeContent(apps: [], loadFailed: false) == .empty)
        #expect(HomeContent(apps: [app], loadFailed: false) == .apps([app]))
    }

    @MainActor @Test func openingAPCsLibraryReturnsToTheStartScreen() {
        let navigator = Navigator(root: .start, focus: "pair")
        navigator.push(.pair)
        navigator.push(.pin(hostID: "A"))

        navigator.openHome(hostID: "A")

        #expect(navigator.stack.map(\.screen) == [.start, .home(hostID: "A")])
        #expect(navigator.stack[0].focus.focused == AnyHashable(StartScreen.pcID("A")))
        navigator.openStream(hostID: "A", appID: 3)
        #expect(navigator.current == .stream(hostID: "A", appID: 3))
    }
}
