import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

/// No service is called: the store gets fake providers and a temporary directory.
private struct QuietProviders: MetadataProviders {
    let available: Bool
    func search(_ title: String) async throws -> [MetadataCandidate] { [] }
    func game(_ id: Int64) async throws -> MetadataCandidate? { nil }
    func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence { HDREvidence() }
    func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? { nil }
    func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] { [] }
}

@MainActor @Suite struct MetadataUITests {
    private func model(available: Bool) -> GameMetadataModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("metadata-ui-\(UUID().uuidString)")
        return GameMetadataModel(store: MetadataStore(
            providers: QuietProviders(available: available), cache: DiskCache(directory: directory, budget: 1 << 20, maxEntryBytes: 1 << 16)))
    }

    @Test func withoutAServiceNothingIsOfferedOrLookedUp() {
        let off = model(available: false)
        let game = HostApp(id: 5, title: "Hades")
        #expect(!off.enabled)
        #expect(!off.offers(game))
        off.ensure(game)
        #expect(off.states.isEmpty)
        #expect(off.data(for: game) == nil)
        #expect(GameDataSetting.rows(.about, enabled: false).isEmpty)
    }

    @Test func builtInEntriesHaveNoMetadata() {
        let on = model(available: true)
        #expect(on.offers(HostApp(id: 5, title: "Hades")))
        #expect(!on.offers(HostApp(id: 1, title: "Desktop")))
        #expect(!on.offers(HostApp(id: 2, title: " Steam BigPicture ")))
        #expect(!on.offers(HostApp(id: 3, title: "Anything", uuid: "9A1C5A25-58FE-40E0-B9AA-7D3F00000006")))
        #expect(!on.offers(HostApp(id: 4, title: "Anything", uuid: "9a1c5a25-58fe-40e0-b9aa-7d3f00000005")))
    }

    @Test func aSeededStateIsFoundByTheLiteralTitle() {
        let on = model(available: true)
        on.seed("The Witcher 3", GameMetadataState(data: GameMetadata(steamTags: ["RPG"]), resolved: true))
        #expect(on.data(for: HostApp(id: 1, title: "the witcher 3"))?.steamTags == ["RPG"])
        #expect(on.data(for: HostApp(id: 2, title: "Other")) == nil)
    }

    @Test func theGameDataRowsOpenTheProviderWebsites() {
        let rows = GameDataSetting.rows(.about, enabled: true)
        #expect(rows.map(\.id) == ["about_igdb", "about_pcgw", "about_steam", "about_hltb"])
        #expect(rows.allSatisfy { $0.tab == .about && $0.value == .action(label: nil) && !$0.label.isEmpty && !$0.help.isEmpty })
        #expect(GameDataSetting.website("about_hltb")?.host == "howlongtobeat.com")
        #expect(GameDataSetting.website("list_languages") == nil)
        #expect(GameDataSetting.rows(.stream, enabled: true).isEmpty)
    }

    @Test func genresAndThemesReadTranslatedNamesOrIGDBsOwn() {
        #expect(TagLook.genreName(GameGenre(id: 5, name: "Shooter")) == "Shooter")
        #expect(TagLook.genreName(GameGenre(id: 999, name: "Brand new")) == "Brand new")
        #expect(TagLook.themeName(GameGenre(id: 18, name: "Science fiction")) == "Science fiction")
        #expect(TagLook.genreIcon(5) == Symbols.genreShooter)
        #expect(TagLook.genreIcon(999) == Symbols.genreUnknown)
        #expect(TagLook.themeIcon(41) == Symbols.theme4x)
    }

    @Test func theCompletionChipReadsLikeAndroid() {
        #expect(TagLook.completionText(.minutes(1)) == "1 Min")
        #expect(TagLook.completionText(.minutes(45)) == "45 Mins")
        #expect(TagLook.completionText(CompletionLength(seconds: 3600)) == "1 Hour")
        #expect(TagLook.completionText(CompletionLength(seconds: 3 * 3600 + 1000)) == "3\u{00BD} Hours")
        #expect(TagLook.completionText(CompletionLength(seconds: 12 * 3600)) == "12 Hours")
    }

    @Test func pillTintsFollowAndroidsRecipes() {
        let genre = TagTint.genre(hue: 200, saturation: 100, dark: true)
        #expect(genre.fill == hsl(200, 95, 34, 0.35))
        #expect(genre.content == hsl(200, 95, 85))
        let light = TagTint.theme(hue: 10, saturation: 5, dark: false)
        #expect(light.border == hsl(10, 20, 40, 0.45))
    }
}
