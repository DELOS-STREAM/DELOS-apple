import DelosData
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

@Suite struct HomeLeftoversTests {
    /// A paired, online record of a PC that answered with [xml]'s extra fields.
    private func host(virtualDisplay: String = "", address: Bool = true) throws -> HostRecord {
        let xml = """
        <root status_code="200"><hostname>Meiton-PC</hostname><uniqueid>pc-1</uniqueid><HttpsPort>47984</HttpsPort>\
        <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state>\(virtualDisplay)</root>
        """
        let info = try ServerInfo.parse(Data(xml.utf8))
        var record = HostRecord(firstReply: ServerInfoReply(info: info, address: HostAddress(host: "10.0.0.2", port: 47989), source: .plainHTTP))
            .paired(with: HostPin(certificate: Data([1]), httpsPort: 47984))
        if !address {
            record.activeAddress = nil
            record.localAddress = nil
        }
        return record
    }

    @Test func aPCThatIsNotPairedHasNoLibrary() {
        #expect(HomeContent(paired: false, apps: [HostApp(id: 1, title: "Hades")], loadFailed: false) == .noPC)
        #expect(HomeContent(paired: false, apps: nil, loadFailed: true) == .noPC)
        #expect(HomeContent(paired: true, apps: nil, loadFailed: true) == .offline)
    }

    @Test func theVirtualDisplayChipIsDesktopsOnAPCThatCanMakeOne() throws {
        let capable = try host(virtualDisplay: "<VirtualDisplayCapable>true</VirtualDisplayCapable>").virtualDisplay
        let plain = try host().virtualDisplay
        #expect(capable == VirtualDisplaySupport(capable: true, driverReady: false))
        #expect(plain == VirtualDisplaySupport(capable: false, driverReady: false))
        #expect(VirtualDisplayChip.shows(app: HostApp(id: 1, title: "Desktop"), support: capable))
        #expect(!VirtualDisplayChip.shows(app: HostApp(id: 1, title: "Desktop"), support: plain))
        #expect(!VirtualDisplayChip.shows(app: HostApp(id: 1, title: "Desktop"), support: nil))
        #expect(!VirtualDisplayChip.shows(app: HostApp(id: 2, title: "Hades"), support: capable))
    }

    @Test func aStartNeedsAPairedPCWithAnAddress() throws {
        #expect(GameStart.canReach(try host()))
        #expect(!GameStart.canReach(try host(address: false)))
        #expect(!GameStart.canReach(try host().unpaired()))
        #expect(!GameStart.canReach(nil))
    }

    @Test func aWantedVirtualDisplayThePCCannotMakeIsMissing() {
        #expect(!GameStart.virtualDisplayMissing(wants: false, support: nil))
        #expect(GameStart.virtualDisplayMissing(wants: true, support: nil))
        #expect(GameStart.virtualDisplayMissing(wants: true, support: VirtualDisplaySupport(capable: true, driverReady: false)))
        #expect(!GameStart.virtualDisplayMissing(wants: true, support: VirtualDisplaySupport(capable: true, driverReady: true)))
    }

    @Test func tryAgainChecksThePCAndTheGameFirst() throws {
        let online = try host()
        let apps = [HostApp(id: 7, title: "Hades"), HostApp(id: 9, title: "Celeste")]
        #expect(StreamRetry.decide(host: online, apps: apps, appID: 7, appName: "Hades", pcName: "Meiton-PC") == .retry)
        // The PC's list changed: the game is started under its new id
        #expect(StreamRetry.decide(host: online, apps: apps, appID: 3, appName: "Celeste", pcName: "Meiton-PC") == .start(appID: 9))
        let missing = StreamRetry.decide(host: online, apps: apps, appID: 3, appName: "Doom", pcName: "Meiton-PC")
        #expect(missing.toast == "Doom is not available on Meiton-PC")
        let unnamed = StreamRetry.decide(host: online, apps: nil, appID: 3, appName: "", pcName: "Meiton-PC")
        #expect(unnamed == .gameMissing(appName: "", pcName: "Meiton-PC"))
        let offline = StreamRetry.decide(host: online.markedOffline(), apps: apps, appID: 7, appName: "Hades", pcName: "Meiton-PC")
        #expect(offline.toast == "Meiton-PC cannot be reached")
        #expect(StreamRetry.decide(host: nil, apps: nil, appID: 7, appName: "Hades", pcName: "Meiton-PC") == .unreachable(pcName: "Meiton-PC"))
    }

    @MainActor @Test func theResultOfAFailedStreamHasSelectAndBackToLibrary() {
        var context = ShellHints.Context(screen: .stream(hostID: "h", appID: 1))
        #expect(ShellHints.hints(context, kind: .controller).isEmpty)
        context.screenHints.streamResult = true
        let hints = ShellHints.hints(context, kind: .controller)
        #expect(hints.map(\.button) == [.pad(.south), .pad(.east)])
        #expect(hints.map(\.label) == ["Select", "Back to library"])
        #expect(hints[1].shortLabel == "Back")
    }
    @Test func theProgressPillShowsArtworkBeforeMetadata() {
        #expect(ShellProgress.shown(artwork: nil, metadata: nil)?.progress == nil)
        let metadata = ShellProgress.shown(artwork: nil, metadata: ShellProgress(done: 1, total: 4))
        #expect(metadata?.label.isEmpty == false)
        #expect(metadata?.progress.fraction == 0.25)
        let artwork = ShellProgress.shown(artwork: ShellProgress(done: 0, total: 2), metadata: ShellProgress(done: 1, total: 4))
        #expect(artwork?.progress == ShellProgress(done: 0, total: 2))
        #expect(artwork?.label != metadata?.label)
        #expect(ShellProgress(done: 0, total: 0).fraction == 0)
    }
}
