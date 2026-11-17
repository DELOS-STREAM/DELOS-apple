#if os(macOS)
@testable import DelosData
import DelosHost
import Foundation
import SwiftUI
@testable import DelosUI

/// A key store that has a key (SteamGridDB on) or none.
struct FixtureKey: SecretStorage {
    var key: String?
    func read(account: String) throws -> Data? { key.map { Data($0.utf8) } }
    func write(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
}

/// A metadata service that is configured and knows nothing: the library offers its filter, the stored records are the ones
/// the test seeds.
struct FixtureProviders: MetadataProviders {
    var available = true
    func search(_ title: String) async throws -> [MetadataCandidate] { [] }
    func game(_ id: Int64) async throws -> MetadataCandidate? { nil }
    func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence { HDREvidence() }
    func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? { nil }
    func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] { [] }
}

/// A SteamGridDB with one game and three covers.
func fixtureSteamGridDB() -> SteamGridDB.Transport {
    { request in
        let url = request.url!
        func reply(_ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.host() == "cdn.example" { return reply("png") }
        if url.path().contains("search/autocomplete") { return reply(#"{"data":[{"id":7,"name":"Hades"}]}"#) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let empty = items.contains { $0.name == "styles" } || items.contains { $0.name == "types" && $0.value == "animated" }
        let entries = empty ? "" : (1...6).map { #"{"id":\#($0),"url":"https://cdn.example/\#($0).png","width":600,"height":900}"# }.joined(separator: ",")
        return reply(#"{"success":true,"data":[\#(entries)]}"#)
    }
}

/// Everything a screen of the shell needs, isolated from the real app's data: its own defaults, no key chain, no network
/// (a PC without an address is never asked), a metadata service that answers from what the test seeds.
@MainActor
final class ShellFixture {
    let profiles: ProfileStore
    let hosts: HostStore
    let toasts = Toasts()
    let layers = Layers()
    let navigator: Navigator
    let artwork: ArtworkStore
    let homeArt: HomeArt
    let metadata: GameMetadataModel
    let actions: ShellActions
    let suite = "delos.nav.\(UUID().uuidString)"

    static let hostID = "PC-A"

    init(pcs: [(id: String, name: String, online: Bool)] = [(ShellFixture.hostID, "Meiton-PC", true)], apps: [HostApp] = ShellFixture.library,
         key: String? = "key", metadataOn: Bool = true, profile: Bool = true) {
        let defaults = UserDefaults(suiteName: suite)!
        profiles = ProfileStore(suiteName: suite)
        if profile { profiles.create(name: "Player", avatar: 3) }
        hosts = HostStore(defaults: defaults)
        for pc in pcs {
            let xml = """
            <root status_code="200"><hostname>\(pc.name)</hostname><uniqueid>\(pc.id)</uniqueid><HttpsPort>47984</HttpsPort>\
            <appversion>7.1.431.-1</appversion><PairStatus>0</PairStatus><state>SUNSHINE_SERVER_FREE</state></root>
            """
            let reply = ServerInfoReply(
                info: try! ServerInfo.parse(Data(xml.utf8)), address: HostAddress(host: "127.0.0.1", port: 1), source: .plainHTTP)
            var record = HostRecord(firstReply: reply).paired(with: HostPin(certificate: Data([1]), httpsPort: 47984))
            // Nothing is asked: a PC without an address is never reached
            record.activeAddress = nil
            record.localAddress = nil
            hosts.store(pc.online ? record : record.markedOffline())
            hosts.apps[pc.id] = apps
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "delos-nav-\(UUID().uuidString)", directoryHint: .isDirectory)
        artwork = ArtworkStore(
            secrets: FixtureKey(key: key), defaults: defaults, matches: directory,
            cache: DiskCache(directory: directory.appending(path: "cache"), budget: 1 << 20, maxEntryBytes: 1 << 16), transport: fixtureSteamGridDB())
        homeArt = HomeArt(artwork: artwork)
        let store = MetadataStore(
            providers: FixtureProviders(available: metadataOn),
            cache: DiskCache(directory: directory.appending(path: "metadata"), budget: 1 << 20, maxEntryBytes: 1 << 16))
        metadata = GameMetadataModel(store: store)
        navigator = Navigator(root: .start)
        actions = ShellActions(navigator: navigator, hosts: hosts, profiles: profiles, toasts: toasts, layers: layers, artwork: artwork, metadata: metadata)
        actions.libraryFilters.set(MetadataFilters(), hostID: Self.hostID)
        layers.feedback = nil
    }

    /// A library of enough games to scroll the row: DELOS's own Desktop first, then games.
    static let library: [HostApp] = [HostApp(id: 1, title: "Desktop")]
        + ["Hades", "Doom Eternal", "Celeste", "Portal 2", "Hollow Knight", "Stardew Valley", "Disco Elysium", "Control", "Outer Wilds", "Tunic"]
            .enumerated().map { HostApp(id: $0.offset + 10, title: $0.element) }

    /// Seeds the stored information of the library's games, so the filter has chips: the genres and themes of [Self.genres].
    func seedMetadata() {
        for (index, app) in Self.library.enumerated() where index > 0 {
            let genre = Self.genres[index % Self.genres.count]
            let candidate = MetadataCandidate(
                id: Int64(index), name: app.title, genres: [genre], themes: [GameGenre(id: 100 + index % 3, name: "Theme \(index % 3)")])
            metadata.seed(app.title, GameMetadataState(
                data: GameMetadata(candidate: candidate, hdr: HDREvidence(support: index % 2 == 0 ? .hdr : .sdr),
                                   completion: CompletionTime(id: 1, name: app.title, seconds: Int64(index) * 7200, url: "")),
                resolved: true))
        }
    }

    static let genres = [GameGenre(id: 5, name: "Shooter"), GameGenre(id: 31, name: "Adventure"), GameGenre(id: 12, name: "RPG"),
                         GameGenre(id: 9, name: "Puzzle")]

    /// The root's environment: what every screen reads.
    func environment<Content: View>(_ content: Content) -> some View {
        content
            .environment(hosts)
            .environment(homeArt)
            .environment(metadata)
            .environment(navigator)
            .environment(layers)
            .environment(toasts)
            .environment(\.reducedMotion, true)
            .environment(\.delosColors, DelosColors(palette: .delos, dark: true))
    }

    /// The top navigation the root shows above the screens that have it.
    func topBar(for screen: Screen, focus: FocusModel, back: Bool = true) -> some View {
        let buttons = TopNav.buttons(current: screen, onSettings: {}, onProfile: {}, onDevices: {})
        return TopBar(
            brand: screen != .start,
            navigation: screen.showsNavigation ? TopBar.Navigation(buttons: buttons, focus: focus) : nil,
            pc: screen.showsNavigation ? (name: "Meiton-PC", online: true) : nil, onBack: back ? {} : nil)
    }
}

/// A fixture with a router, for tests that need no window.
@MainActor
struct ShellFixtureLite {
    let fixture = ShellFixture()
    let router: ShellRouter
    var navigator: Navigator { fixture.navigator }
    var layers: Layers { fixture.layers }

    init() {
        router = ShellRouter(navigator: fixture.navigator, layers: fixture.layers, toasts: fixture.toasts, actions: fixture.actions)
        router.animate = { _, change in change() }
    }
}
#endif
