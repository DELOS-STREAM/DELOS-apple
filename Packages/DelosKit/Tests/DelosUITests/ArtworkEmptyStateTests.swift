import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

/// A key store that always has the key.
private struct FakeKey: SecretStorage {
    func read(account: String) throws -> Data? { Data("key".utf8) }
    func write(_ data: Data, account: String) throws {}
    func delete(account: String) throws {}
}

/// A SteamGridDB with one game and three covers; a request with a style asks for the material style, which has none.
private func fakeTransport() -> SteamGridDB.Transport {
    { request in
        let url = request.url!
        func reply(_ body: String) -> (Data, HTTPURLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        if url.host() == "cdn.example" { return reply("png") }
        if url.path().contains("search/autocomplete") { return reply(#"{"data":[{"id":7,"name":"Hades"}]}"#) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let empty = items.contains { $0.name == "styles" } || items.contains { $0.name == "types" && $0.value == "animated" }
        let entries = empty ? "" : (1...3).map { #"{"id":\#($0),"url":"https://cdn.example/\#($0).png","width":600,"height":900}"# }.joined(separator: ",")
        return reply(#"{"success":true,"data":[\#(entries)]}"#)
    }
}

@MainActor
@Suite struct ArtworkEmptyStateTests {
    private func model() async -> ArtworkModel {
        let directory = FileManager.default.temporaryDirectory.appending(path: "delos-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: "delos-tests-\(UUID().uuidString)")!
        let store = ArtworkStore(
            secrets: FakeKey(), defaults: defaults, matches: directory,
            cache: DiskCache(directory: directory.appending(path: "cache"), budget: 1 << 20, maxEntryBytes: 1 << 16), transport: fakeTransport())
        let model = ArtworkModel(hostID: "pc", app: HostApp(id: 1, title: "Hades"), artwork: store)
        await model.lookup { _ in }
        return model
    }

    @Test func noImageAndNoFilterIsBareAndKeepsTheFirstChoice() {
        #expect(ArtworkEmpty(images: 3, filters: ArtFilters()) == nil)
        #expect(ArtworkEmpty(images: 0, filters: ArtFilters()) == .bare)
        #expect(ArtworkEmpty.bare.showsFirstChoice)
        #expect(ArtworkEmpty.bare.firstFocus == ArtworkScreen.firstFocus)
    }

    @Test func filtersThatLeaveNothingShowNoTileAndStartOnReset() {
        let filters = ArtFilters(style: "material")
        #expect(ArtworkEmpty(images: 0, filters: filters) == .filtered)
        #expect(ArtworkEmpty(images: 2, filters: filters) == nil)
        #expect(!ArtworkEmpty.filtered.showsFirstChoice)
        #expect(ArtworkEmpty.filtered.firstFocus == ArtworkEmpty.resetID)
        // The two buttons are not ids of anything else on the screen
        #expect(ArtworkEmpty.resetID != ArtworkEmpty.changeID && ArtworkEmpty.resetID != ArtworkScreen.noneID)
    }

    @Test func theModelSaysFilteredOnlyOnceTheListOfThoseFiltersIsThere() async {
        let model = await model()
        await model.load()
        #expect(model.images?.count == 3 && model.empty == nil)
        // Material: nothing matches. Until its list is loaded the grid is not "empty", it is loading
        model.filtersByTab[.cover] = ArtFilters(style: "material")
        #expect(model.empty == nil)
        await model.load()
        #expect(model.images?.isEmpty == true && model.empty == .filtered)
        #expect(model.initialTile() == ArtworkEmpty.resetID)
        // Reset: the old (empty) list must not read as "SteamGridDB has none" while the unfiltered one is picked up again
        model.filtersByTab[.cover] = ArtFilters()
        #expect(model.empty == nil)
        await model.load()
        #expect(model.images?.count == 3 && model.empty == nil)
        // The focus starts on the image in use (the automatic download took the first one), not on Reset
        #expect(model.initialTile() == ArtworkScreen.tileID(1))
    }
}
