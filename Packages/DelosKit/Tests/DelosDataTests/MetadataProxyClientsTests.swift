import Foundation
import Testing
@testable import DelosData

// Fixtures adapted from Android:
// app/src/test/java/com/limelight/shell/data/IgdbMetadataClientTest.kt
// app/src/test/java/com/limelight/shell/data/PcGamingWikiClientTest.kt
// app/src/test/java/com/limelight/shell/data/SteamTagsClientTest.kt

private func bytes(_ string: String) -> Data {
    Data(string.utf8)
}

private enum FixtureFailure: Error {
    case offline
    case unexpectedRequest
}

private actor ProxyFixtureTransport: MetadataTransport {
    private var replies: [MetadataHTTPResponse]
    private var requests: [URLRequest] = []
    private let offline: Bool

    init(_ bodies: [String], status: Int = 200, offline: Bool = false) {
        replies = bodies.map {
            MetadataHTTPResponse(
                data: bytes($0),
                status: status,
                headers: status == 307 ? ["Location": "https://other.invalid/"] : [:]
            )
        }
        self.offline = offline
    }

    func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
        requests.append(request)
        if offline { throw FixtureFailure.offline }
        guard !replies.isEmpty else { throw FixtureFailure.unexpectedRequest }
        return replies.removeFirst()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private func expectMetadataError(
    _ operation: () async throws -> Void,
    matching predicate: (MetadataError) -> Bool
) async {
    do {
        try await operation()
        Issue.record("Expected a metadata failure")
    } catch let error as MetadataError {
        #expect(predicate(error))
    } catch {
        Issue.record("Unexpected error type")
    }
}

private func expectMalformed(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected malformedResponse")
    } catch MetadataError.malformedResponse {
        // Expected.
    } catch {
        Issue.record("Unexpected error type")
    }
}

struct MetadataProxyClientsTests {
    @Test func igdbPreservesEditionsSteamAliasesAndAllMetadata() throws {
        let games = try IGDBMetadataClient.parseGames(bytes("""
        [
          {
            "id":1942,
            "name":"The Witcher 3: Wild Hunt",
            "first_release_date":1431993600,
            "genres":[{"id":12,"name":"Role-playing (RPG)"}],
            "themes":[{"id":17,"name":"Fantasy"},{"id":1,"name":"Action"}],
            "summary":"A PC game",
            "platforms":[6,14,6],
            "rating_count":154,
            "total_rating_count":155,
            "external_games":[
              {"external_game_source":5,"uid":"999"},
              {"external_game_source":1,"uid":"292030"},
              {"external_game_source":1,"uid":"10"},
              {"external_game_source":1,"uid":"292030"},
              {"external_game_source":1,"uid":"0"},
              {"external_game_source":1,"uid":"not-an-id"}
            ]
          },
          {
            "id":4000,
            "name":"The Witcher 3: Wild Hunt - Complete Edition",
            "external_games":[{"category":1,"uid":"1000"}]
          }
        ]
        """))
        #expect(games.count == 2)
        let game = try #require(games.first)
        #expect(game.id == 1942)
        #expect(game.year == 2015)
        #expect(game.steamAppIDs == [292030, 10])
        #expect(game.genres == [GameGenre(id: 12, name: "Role-playing (RPG)")])
        #expect(game.themes == [
            GameGenre(id: 17, name: "Fantasy"),
            GameGenre(id: 1, name: "Action")
        ])
        #expect(game.platformIDs == [6, 14])
        #expect(game.ratingCount == 155)
        #expect(game.summary == "A PC game")
        #expect(games[1].id == 4000)
        #expect(games[1].name == "The Witcher 3: Wild Hunt - Complete Edition")
        #expect(games[1].year == nil)
        #expect(games[1].steamAppIDs.isEmpty)
        #expect(games[1].platformIDs.isEmpty)
        #expect(games[1].themes.isEmpty)
        #expect(games[1].ratingCount == 0)
    }

    @Test func igdbRatingFallbackAndStablePCOrdering() throws {
        let games = try IGDBMetadataClient.parseGames(bytes("""
        [
          {"id":1,"name":"Unknown","rating_count":7},
          {"id":2,"name":"Console","platforms":[48]},
          {"id":3,"name":"PC","platforms":[6]},
          {"id":4,"name":"Steam","platforms":[14],
           "external_games":[{"external_game_source":1,"uid":"7"}]},
          {"id":5,"name":"Console 2","platforms":[130]}
        ]
        """))
        #expect(games[0].ratingCount == 7)
        #expect(IGDBMetadataClient.preferPC(games).map(\.id) == [3, 4, 1, 2, 5])
    }

    @Test func igdbRejectsMalformedPayloads() {
        for fixture in [
            "", "not json", #"{"id":1}"#,
            #"[{"name":"no id"}]"#,
            #"[{"id":1}]"#,
            #"[{"id":1,"name":"A","genres":"wrong"}]"#,
            #"[{"id":1,"name":"A","external_games":[null]}]"#,
            #"[{"id":1,"name":"A","themes":[{"id":1}]}]"#
        ] {
            expectMalformed { _ = try IGDBMetadataClient.parseGames(bytes(fixture)) }
        }
    }

    @Test func igdbSearchRequestContainsOnlySanitizedTitle() async throws {
        let transport = ProxyFixtureTransport(["[]"])
        let client = IGDBMetadataClient(
            baseURL: "https://meta.test/delos/",
            http: MetadataHTTP(transport: transport)
        )
        let result = try await client.search("LEGO® Batman™: Legacy of the Dark Knight")
        #expect(result.isEmpty)
        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        let url = try #require(request.url)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.path == "/delos/v1/igdb/games")
        #expect(parts.queryItems == [
            URLQueryItem(name: "search", value: "LEGO Batman: Legacy of the Dark Knight")
        ])
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Client-ID") == nil)
        #expect(request.httpBody == nil)
    }

    @Test func igdbBlankSearchSendsNothing() async throws {
        let transport = ProxyFixtureTransport([])
        let client = IGDBMetadataClient(
            baseURL: "",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.search("®™ ").isEmpty)
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func igdbGameLookupAndEmptyResult() async throws {
        let transport = ProxyFixtureTransport([#"[{"id":1942,"name":"The Witcher 3"}]"#])
        let client = IGDBMetadataClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.game(1942)?.id == 1942)
        let request = try #require(await transport.recordedRequests().first)
        let url = try #require(request.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "id", value: "1942")
        ])
        await expectMetadataError({ _ = try await client.game(0) }) {
            if case .invalidRequest = $0 { return true }
            return false
        }
        #expect(await transport.recordedRequests().count == 1)

        let empty = IGDBMetadataClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: ProxyFixtureTransport(["[]"]))
        )
        #expect(try await empty.game(1) == nil)
    }

    @Test func steamTagsTrimDeduplicateAndBoundResults() throws {
        let names = (1...30).map { "\"T\($0)\"" }.joined(separator: ",")
        let tags = try SteamTagsClient.parseTags(
            bytes(#"{"app":7,"tags":["  Spaced ","","Spaced","# + names + "]}"),
            appID: 7
        )
        #expect(tags.count == 20)
        #expect(Array(tags.prefix(3)) == ["Spaced", "T1", "T2"])
        #expect(tags.last == "T19")
        #expect(try SteamTagsClient.parseTags(bytes(#"{"app":7,"tags":[]}"#), appID: 7).isEmpty)
    }

    @Test func steamTagsRejectMismatchedAndMalformedPayloads() {
        for fixture in [
            "", "not json", "[]", #"{"app":2101960}"#,
            #"{"app":2101960,"tags":"x"}"#,
            #"{"app":2101960,"tags":[null]}"#,
            #"{"app":5,"tags":["Other game"]}"#,
            #"{"app":"x","tags":[]}"#,
            #"{"app":true,"tags":[]}"#
        ] {
            expectMalformed {
                _ = try SteamTagsClient.parseTags(bytes(fixture), appID: 2101960)
            }
        }
        let valid = Array(repeating: "\"Tag\"", count: 20).joined(separator: ",")
        expectMalformed {
            _ = try SteamTagsClient.parseTags(
                bytes(#"{"app":7,"tags":["# + valid + ",null]}"),
                appID: 7
            )
        }
    }

    @Test func steamRequestAndValidation() async throws {
        let transport = ProxyFixtureTransport([
            #"{"app":2101960,"tags":["Survival Horror","Horror"]}"#
        ])
        let client = SteamTagsClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.tags(2101960) == ["Survival Horror", "Horror"])
        let request = try #require(await transport.recordedRequests().first)
        #expect(request.url?.absoluteString == "https://meta.test/v1/steam/tags?app=2101960")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        for id: Int64 in [0, -1, SteamTagsClient.maxAppID + 1] {
            await expectMetadataError({ _ = try await client.tags(id) }) {
                if case .invalidRequest = $0 { return true }
                return false
            }
        }
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func wikiNativeValuesAndDefiniteSDR() {
        for value in ["true", "always on", "alwayson", "limited"] {
            #expect(PCGamingWikiClient.parseVideo(
                "{{Video|hdr=\(value)}}", page: "Game"
            ) == HDREvidence(support: .hdr, page: "Game"))
        }
        for value in ["false", "hackable"] {
            for notes in [
                "", "Supports native HDR output via Engine.ini.",
                "Only available using Special K."
            ] {
                #expect(PCGamingWikiClient.parseVideo(
                    "{{Video|hdr=\(value)|hdr notes=\(notes)}}", page: "Game"
                ).support == .sdr)
            }
        }
        for source in [
            "{{Video|hdr=unknown}}", "{{Video|hdr=}}", "{{Video|hdr=true",
            "{{Other|hdr=true}}", "<!-- {{Video|hdr=true}} -->"
        ] {
            #expect(PCGamingWikiClient.parseVideo(source, page: "Game").support == .unknown)
        }
    }

    @Test func wikiRetrofitsRestrictionsAndBrokenOutputRemainUnknown() {
        for notes in [
            "Requires Special K.", "Use ReShade.", "Enable Auto HDR.",
            "Requires RTX HDR.", "Only works using a mod.",
            "Possible through [[Special K]].",
            "Use [[Special K|this tool]].",
            "Enable HDR with {{file|ReShade.dll}}.",
            "Set it up through [[Glossary:Auto HDR|the Windows feature]].",
            "Supported on consoles only.", "Only available on Xbox Series X.",
            "Requires the enhanced edition.", "Supported in specific versions.",
            "Not supported natively.", "No native HDR.", "HDR output is broken.",
            "Simulated HDR only.", "HDR disabled in recent patch due to technical issues reported.",
            "Added in Patch v.37.2 but currently disabled.",
            "HDR does not work on Nvidia GPUs. A black screen will occur.",
            "Only confirmed in the Mac App Store version.", "Broken as of 1.1 game update"
        ] {
            for value in ["true", "limited"] {
                #expect(PCGamingWikiClient.parseVideo(
                    "{{Video|hdr=\(value)|hdr notes=\(notes)}}", page: "Game"
                ).support == .unknown, Comment(rawValue: notes))
            }
        }
    }

    @Test func wikiCaveatsAndMarkupDoNotWithdrawNativeHDR() {
        for notes in [
            "Raised blacks. See [[Cronos:_The_New_Dawn#Modifications|Modifications]].",
            "Change the value bUseHDRDisplayOutput from false to true in GameUserSettings.ini",
            "RenoDX mod for fix broken black level and white point",
            "Can be greatly improved with Black Floor Fix mod.",
            "The free 4K HDR Video DLC adapts the video files to this option.",
            "Use the -forcenohdr [[Glossary:Command line arguments|command line argument]] to force HDR off.",
            "The HDR image is very limited in brightness range with the default settings.",
            "SDR based stretching. Luma or RenoDX can be used to improve the native HDR implementation.",
            "Windows HDR, DX12 and fullscreen mode are required.",
            "Brightness slider and preview do not work properly in HDR.",
            "Enable HDR in the video settings.<ref>{{Refurl|url=https://example.test/hdr-settings.txt|title=Download the HDR file|date=2024}}</ref>",
            "Toggle HDR.<ref name=a>[https://example.test/page.xml Version 2 download]</ref>",
            "HDR is only supported on HDR10 displays.",
            "Version 1.2 added HDR support.",
            "Use the HDR switch in the display options.",
            "See [https://example.test/readme.txt the manual].",
            "Works with [[HDR10]] displays.<ref name=\"x\" />",
            "Enable HDR.<ref>Reference | with a pipe, only for the file</ref> Use the in-game toggle."
        ] {
            #expect(PCGamingWikiClient.parseVideo(
                "{{Video|hdr=true|hdr notes=\(notes)|vsync=true}}", page: "Game"
            ).support == .hdr, Comment(rawValue: notes))
        }
    }

    @Test func wikiNestedReferencesPreserveOriginalNotes() {
        let notes = "Enable Windows HDR.<ref>{{Refurl|url=https://example.test/?a=b|title=Test}}</ref> Use [[Settings|the in-game toggle]]."
        #expect(PCGamingWikiClient.parseVideo(
            "{{Video|hdr=always on|hdr notes=\(notes)|vsync=true}}", page: "Game"
        ) == HDREvidence(support: .hdr, page: "Game", notes: notes))

        let source = """
        {{Video
        |ultrawidescreen=hackable
        |ultrawidescreen notes=See [[#Modifications|Modifications]].
        |hdr=true
        |hdr notes=
        |ray tracing=true
        }}
        ==Modifications==
        Use ReShade or a mod to change other video features.
        """
        #expect(PCGamingWikiClient.parseVideo(source, page: "Elden Ring") ==
            HDREvidence(support: .hdr, page: "Elden Ring"))
    }

    @Test func wikiPureResponseParsers() throws {
        let cargo = bytes("""
        {"cargoquery":[
          {"title":{"Page":"Game","Steam":""}},
          {"title":{"Page":"Game","Steam":""}},
          {"title":{"Page":"Other","Steam":"3830"}}
        ]}
        """)
        #expect(try PCGamingWikiClient.parseCargoPages(cargo) == ["Game", "Other"])
        #expect(try PCGamingWikiClient.parseCargoPages(cargo, withoutSteamID: true) == ["Game"])
        #expect(try PCGamingWikiClient.parseRedirectTarget(bytes(
            #"{"query":{"redirects":[{"to":"Intermediate"},{"to":"Final"}]}}"#
        )) == "Final")
        #expect(try PCGamingWikiClient.parseRedirectTarget(bytes(
            #"{"query":{"pages":{}}}"#
        )) == nil)
        #expect(try PCGamingWikiClient.parseSearchTitles(bytes(
            #"{"query":{"search":[{"title":"A"},{"title":"B"}]}}"#
        )) == ["A", "B"])
        #expect(try PCGamingWikiClient.parsePage(bytes(
            #"{"parse":{"wikitext":{"*":"{{Video|hdr=true}}"}}}"#
        )) == "{{Video|hdr=true}}")
    }

    @Test func wikiRejectsMalformedAndAPIErrorPayloads() {
        for fixture in [
            "", "not json", "[]", #"{"cargoquery":"x"}"#,
            #"{"cargoquery":[{"title":{}}]}"#,
            #"{"error":{"info":"private provider echo"}}"#,
            #"{"errors":[]}"#
        ] {
            expectMalformed { _ = try PCGamingWikiClient.parseCargoPages(bytes(fixture)) }
        }
        expectMalformed {
            _ = try PCGamingWikiClient.parsePage(bytes(#"{"parse":{"wikitext":{}}}"#))
        }
        expectMalformed {
            _ = try PCGamingWikiClient.parseRedirectTarget(bytes(#"{"query":{"redirects":"x"}}"#))
        }
        expectMalformed {
            _ = try PCGamingWikiClient.parseSearchTitles(bytes(#"{"query":{"search":[{}]}}"#))
        }
    }

    @Test func wikiExactTitleFallbackAndSteamIdentityProtection() async throws {
        let transport = ProxyFixtureTransport([
            #"{"cargoquery":[]}"#,
            #"{"cargoquery":[{"title":{"Page":"Euro Truck Simulator 2","Steam":""}}]}"#,
            #"{"parse":{"wikitext":{"*":"{{Video|hdr=true|hdr notes=Added in 1.57}}"}}}"#
        ])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.lookup(steamAppIDs: [227300], name: "Euro Truck Simulator 2") ==
            HDREvidence(support: .hdr, page: "Euro Truck Simulator 2", notes: "Added in 1.57"))
        let requests = await transport.recordedRequests()
        #expect(requests.count == 3)
        #expect(requests[0].url?.query == "steam=227300")
        #expect(requests[1].url?.path == "/v1/pcgw/cargo")
        #expect(requests[2].url?.path == "/v1/pcgw/page")

        let other = ProxyFixtureTransport([
            #"{"cargoquery":[]}"#,
            #"{"cargoquery":[{"title":{"Page":"Prey","Steam":"3830"}}]}"#,
            #"{"query":{"pages":{}}}"#,
            #"{"query":{"search":[]}}"#
        ])
        let protected = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: other)
        )
        #expect(try await protected.lookup(steamAppIDs: [480490], name: "Prey") == HDREvidence())
        #expect(await other.recordedRequests().allSatisfy { $0.url?.path != "/v1/pcgw/page" })
    }

    @Test func wikiRedirectAndPunctuationOnlySearchFallback() async throws {
        let transport = ProxyFixtureTransport([
            #"{"cargoquery":[]}"#,
            #"{"query":{"pages":{}}}"#,
            #"{"query":{"search":[{"title":"The Witcher 3: Wild Hunt"},{"title":"The Witcher 3: Wild Hunt: Remastered"}]}}"#,
            #"{"cargoquery":[]}"#,
            #"{"query":{"redirects":[{"to":"The Witcher 3: Wild Hunt"}]}}"#,
            #"{"cargoquery":[{"title":{"Page":"The Witcher 3: Wild Hunt","Steam":"292030"}}]}"#,
            #"{"parse":{"wikitext":{"*":"{{Video|hdr=true}}"}}}"#
        ])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.lookup(
            steamAppIDs: [],
            name: "The Witcher 3: Wild Hunt Remastered"
        ) == HDREvidence(support: .hdr, page: "The Witcher 3: Wild Hunt"))
        let requests = await transport.recordedRequests()
        #expect(requests.count == 7)
        let similarCargo = try #require(requests[3].url)
        #expect(URLComponents(url: similarCargo, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "page", value: "The Witcher 3: Wild Hunt: Remastered")
        ])
    }

    @Test func wikiUnrelatedSearchHitIsNotTakenAndAbsenceIsCached() async throws {
        let transport = ProxyFixtureTransport([
            #"{"cargoquery":[]}"#,
            #"{"query":{"pages":{}}}"#,
            #"{"query":{"search":[{"title":"Sea of Stars"},{"title":"Infinite Space III: Sea of Stars"}]}}"#
        ])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.lookup(
            steamAppIDs: [], name: "Sea of Stars: Sunset Edition"
        ) == HDREvidence())
        #expect(try await client.lookup(
            steamAppIDs: [], name: "Sea of Stars: Sunset Edition"
        ) == HDREvidence())
        #expect(await transport.recordedRequests().count == 3)
    }

    @Test func wikiSteamIDsAreSortedDeduplicatedCappedAndCacheKeyIgnoresTitle() async throws {
        let transport = ProxyFixtureTransport([#"{"cargoquery":[]}"#])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        let ids = Array(Int64(1)...Int64(25)) + [10, 5_000_000_000]
        #expect(try await client.lookup(steamAppIDs: ids.reversed(), name: "") == HDREvidence())
        // Invalid wiki title avoids fallback if this unexpectedly misses the cache.
        #expect(try await client.lookup(steamAppIDs: ids, name: "Different [title]") == HDREvidence())
        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "steam", value: (1...20).map(String.init).joined(separator: ","))
        ])
    }

    @Test func wikiInvalidTitlesAndNonpositiveIDsSendNothing() async throws {
        let transport = ProxyFixtureTransport([])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        for title in ["Game [Remastered]", "Game #1", "A|B", "{{x}}", String(repeating: "a", count: 201)] {
            #expect(try await client.lookup(steamAppIDs: [], name: title) == HDREvidence())
        }
        await expectMetadataError({ _ = try await client.lookup(steamAppIDs: [0], name: "Game") }) {
            if case .invalidRequest = $0 { return true }
            return false
        }
        #expect(await transport.recordedRequests().isEmpty)
    }

    @Test func wikiEditionPagesMustAgreeAndLargeListsAreNotFetched() async throws {
        for second in ["true", "false", "unknown"] {
            let transport = ProxyFixtureTransport([
                #"{"cargoquery":[{"title":{"Page":"Game"}},{"title":{"Page":"Game (Deluxe)"}}]}"#,
                #"{"parse":{"wikitext":{"*":"{{Video|hdr=true}}"}}}"#,
                #"{"parse":{"wikitext":{"*":"{{Video|hdr="# + second + #"}}"}}}"#
            ])
            let client = PCGamingWikiClient(
                baseURL: "https://meta.test",
                http: MetadataHTTP(transport: transport)
            )
            let evidence = try await client.lookup(steamAppIDs: [1], name: "Game")
            if second == "true" {
                #expect(evidence == HDREvidence(support: .hdr, page: "Game"))
            } else {
                #expect(evidence == HDREvidence())
            }
        }

        let transport = ProxyFixtureTransport([
            #"{"cargoquery":[{"title":{"Page":"A"}},{"title":{"Page":"B"}},{"title":{"Page":"C"}},{"title":{"Page":"D"}}]}"#
        ])
        let client = PCGamingWikiClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        #expect(try await client.lookup(steamAppIDs: [1], name: "Game") == HDREvidence())
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test func providerHTTPFailuresAreNeverSuccessfulEmptyAnswers() async {
        for status in [307, 400, 403, 404, 429, 500, 502, 503] {
            let igdb = IGDBMetadataClient(
                baseURL: "https://meta.test",
                http: MetadataHTTP(transport: ProxyFixtureTransport(["private echo"], status: status))
            )
            let steam = SteamTagsClient(
                baseURL: "https://meta.test",
                http: MetadataHTTP(transport: ProxyFixtureTransport(["private echo"], status: status))
            )
            let wikiTransport = ProxyFixtureTransport(
                ["private echo", "private echo"], status: status
            )
            let wiki = PCGamingWikiClient(
                baseURL: "https://meta.test",
                http: MetadataHTTP(transport: wikiTransport)
            )

            let matches: (MetadataError) -> Bool = {
                if case .httpStatus(let actual) = $0 { return actual == status }
                return false
            }
            await expectMetadataError({ _ = try await igdb.search("Game") }, matching: matches)
            await expectMetadataError({ _ = try await steam.tags(7) }, matching: matches)
            for _ in 0..<2 {
                await expectMetadataError({
                    _ = try await wiki.lookup(steamAppIDs: [1], name: "Game")
                }, matching: matches)
            }
            #expect(await wikiTransport.recordedRequests().count == 2)
        }
    }

    @Test func unconfiguredProvidersSendNothing() async {
        for baseURL in ["", "   ", "not a url", "http://meta.test"] {
            let transport = ProxyFixtureTransport([])
            let http = MetadataHTTP(transport: transport)
            let matches: (MetadataError) -> Bool = {
                if case .unavailable = $0 { return true }
                return false
            }
            await expectMetadataError({
                _ = try await IGDBMetadataClient(baseURL: baseURL, http: http).search("Game")
            }, matching: matches)
            await expectMetadataError({
                _ = try await SteamTagsClient(baseURL: baseURL, http: http).tags(7)
            }, matching: matches)
            await expectMetadataError({
                _ = try await PCGamingWikiClient(baseURL: baseURL, http: http)
                    .lookup(steamAppIDs: [1], name: "Game")
            }, matching: matches)
            #expect(await transport.recordedRequests().isEmpty)
        }
    }

    @Test func transportFailurePropagates() async {
        let transport = ProxyFixtureTransport([], offline: true)
        let client = IGDBMetadataClient(
            baseURL: "https://meta.test",
            http: MetadataHTTP(transport: transport)
        )
        do {
            _ = try await client.search("Game")
            Issue.record("Expected transport failure")
        } catch FixtureFailure.offline {
            #expect(await transport.recordedRequests().count == 1)
        } catch {
            Issue.record("Transport failure was replaced")
        }
    }
}
