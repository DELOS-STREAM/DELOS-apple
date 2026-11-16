import Foundation
import Testing
@testable import DelosData

/// Fixtures and expected behavior adapted from:
/// app/src/test/java/com/limelight/shell/data/HowLongToBeatClientTest.kt.
/// All requests terminate in the actor transport; no website requests are made.
struct MetadataHowLongToBeatTests {
    @Test
    func combinedTimeComesFromCompAllNotBannerOrOtherAverages() async throws {
        let fixture = Fixture(
            details: [
                2127: detail(
                    2127,
                    "Cyberpunk 2077",
                    steam: 1091500,
                    stats: """
                    "comp_all":237341,"comp_all_count":10805,
                    "comp_main":94177,"comp_all_avg":253582
                    """
                )
            ],
            searches: [search(1, 1, [(2127, "Cyberpunk 2077")])]
        )

        let result = try await fixture.client.lookup(
            name: "Cyberpunk 2077",
            steamAppIDs: [1091500]
        )

        #expect(result == CompletionTime(
            id: 2127,
            name: "Cyberpunk 2077",
            seconds: 237341,
            url: "https://howlongtobeat.com/game/2127"
        ))

        let requests = await fixture.transport.requests
        #expect(requests.compactMap(\.url).map(\.path).filter {
            $0.hasPrefix("/game/")
        } == ["/game/2127"])
    }

    @Test
    func validCombinedTimeDoesNotRequireHeadlineBanner() async throws {
        for seconds: Int64 in [12772, 80713, 469657] {
            let html = detail(
                1,
                "Game",
                steam: 7,
                stats: "\"comp_all\":\(seconds),\"comp_all_count\":100",
                banner: false
            )
            let fixture = Fixture(
                details: [1: html],
                searches: [search(1, 1, [(1, "Game")])]
            )
            let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [7])
            #expect(result?.seconds == seconds)
        }
    }

    @Test
    func noTimeDoesNotSubstituteMainStoryOrMultiplayerInvestment() async throws {
        for stats in [
            """
            "comp_all":0,"comp_all_count":0,"comp_main":3600,"comp_all_avg":7200
            """,
            "\"comp_all\":3600,\"comp_all_count\":0",
            "\"comp_all\":null,\"comp_all_count\":null",
            """
            "comp_all":0,"comp_all_count":0,"comp_lvl_sp":0,
            "comp_lvl_mp":1,"invested_mp":999999
            """
        ] {
            let fixture = Fixture(
                details: [1: detail(1, "Game", steam: 0, stats: stats)],
                searches: [search(1, 1, [(1, "Game")])]
            )
            let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            #expect(result == nil)
        }
    }

    @Test
    func requestFlowAndFullSearchPayload() async throws {
        let fixture = Fixture(
            details: [
                2127: detail(2127, "Cyberpunk 2077", steam: 1091500),
                2: detail(2, "Cyberpunk 2077: Ultimate Edition", steam: 0)
            ],
            searches: [
                search(1, 1, [
                    (2127, "Cyberpunk 2077"),
                    (2, "Cyberpunk 2077: Ultimate Edition")
                ])
            ]
        )

        let result = try await fixture.client.lookup(
            name: " Cyberpunk \n 2077 ",
            steamAppIDs: [1091500]
        )
        #expect(result?.id == 2127)

        let requests = await fixture.transport.requests
        #expect(requests.compactMap(\.url).map(\.path) == [
            "/",
            "/_next/static/chunks/search.js",
            "/api/search/site/init",
            "/api/search/site",
            "/game/2127",
            "/game/2"
        ])

        let post = try #require(requests.first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "x-auth-token") == "fixture-token")
        #expect(post.value(forHTTPHeaderField: "Referer") == "https://howlongtobeat.com/")
        #expect(post.value(forHTTPHeaderField: "Origin") == "https://howlongtobeat.com")
        #expect(post.value(forHTTPHeaderField: "User-Agent") == "Delos/1.0")
        #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8")

        let body = try #require(post.httpBody)
        let payload = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(payload["searchTerms"] as? [String] == ["Cyberpunk", "2077"])
        #expect(payload["searchType"] as? String == "games")
        #expect(payload["searchPage"] as? Int == 1)
        #expect(payload["size"] as? Int == 20)
        #expect(payload["useCache"] as? Bool == true)

        let options = try #require(payload["searchOptions"] as? [String: Any])
        let games = try #require(options["games"] as? [String: Any])
        #expect(games["userId"] as? Int == 0)
        #expect(games["platform"] as? String == "")
        #expect(games["sortCategory"] as? String == "popular")
        #expect(games["rangeCategory"] as? String == "main")
        #expect(games["rangeTime"] as? [String: Int] == ["min": 0, "max": 0])
        #expect(games["rangeYear"] as? [String: String] == ["min": "", "max": ""])
        #expect(games["modifier"] as? String == "")
        #expect(games["gameplay"] as? [String: String] == [
            "perspective": "", "flow": "", "genre": "", "difficulty": ""
        ])
        #expect(options["users"] as? [String: String] == ["sortCategory": "postcount"])
        #expect(options["lists"] as? [String: String] == ["sortCategory": "follows"])
        #expect(options["filter"] as? String == "")
        #expect(options["sort"] as? Int == 0)
        #expect(options["randomizer"] as? Int == 0)

        let initialization = try #require(requests.first {
            $0.url?.path == "/api/search/site/init"
        })
        let initializationURL = try #require(initialization.url)
        let components = try #require(URLComponents(
            url: initializationURL,
            resolvingAgainstBaseURL: false
        ))
        let timestamp = components.queryItems?.first { $0.name == "t" }?.value
        #expect(Int64(timestamp ?? "").map { $0 > 0 } == true)
        #expect(!requests.contains {
            guard let url = $0.url else { return false }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.contains { $0.name == "q" } == true
        })
    }

    @Test
    func steamIdentityPrecedesNamesAndCanUseAnyPrimaryOrAlternativeID() async throws {
        let scenarios: [(String, String, Int64, Int64?, [Int64], Int64?)] = [
            ("Game", "Game", 222, nil, [111], nil),
            ("Local title", "Provider's Official Title", 111, nil, [111], 1),
            ("Game", "Game", 222, nil, [111, 222], 1),
            ("Game", "Game", 222, 111, [111], 1),
            ("Game", "Game", 0, nil, [111], 1)
        ]

        for (title, providerName, steam, alternative, requested, expected) in scenarios {
            let fixture = Fixture(
                details: [
                    1: detail(1, providerName, steam: steam, alternativeSteam: alternative)
                ],
                searches: [search(1, 1, [(1, providerName)])]
            )
            let result = try await fixture.client.lookup(
                name: title,
                steamAppIDs: requested
            )
            #expect(result?.id == expected)
        }
    }

    @Test
    func literalNamesNormalizeTrademarkPunctuationAndCompatibilityCharacters() async throws {
        let fixture = Fixture(
            details: [1: detail(1, "The Game: Subtitle", steam: 0)],
            searches: [search(1, 1, [(1, "The Game: Subtitle")])]
        )
        let result = try await fixture.client.lookup(
            name: " THE GAME™ — Subtitle® ",
            steamAppIDs: []
        )
        #expect(result?.id == 1)
        #expect(HowLongToBeatClient.normalize("ＧＡＭＥ™") == "game")
    }

    @Test
    func editionFallbackIsOneWayExactFirstAndRefusesTies() async throws {
        let scenarios: [(String, [(Int64, String)], Int64?)] = [
            (
                "Sea of Stars: Sunset Edition",
                [(1, "Sea of Stars"), (3, "Sea of Stars: Definitive Edition")],
                1
            ),
            (
                "Sea of Stars: Sunset Edition",
                [(1, "Sea of Stars"), (2, "Sea of Stars: Sunset Edition")],
                2
            ),
            ("Game: Deluxe Edition", [(1, "Game"), (2, "Game")], nil),
            ("Game: Deluxe Edition", [(1, "Other")], nil),
            ("Sea of Stars", [(3, "Sea of Stars: Definitive Edition")], nil),
            ("Game", [(1, "Game"), (2, "Game")], nil)
        ]

        for (title, entries, expected) in scenarios {
            let details = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.0, detail(
                    $0.0,
                    $0.1,
                    steam: 1244090,
                    stats: "\"comp_all\":\($0.0 * 1000),\"comp_all_count\":100"
                ))
            })
            let fixture = Fixture(details: details, searches: [search(1, 1, entries)])
            let result = try await fixture.client.lookup(name: title, steamAppIDs: [])
            #expect(result?.id == expected)

            if title == "Sea of Stars" || title == "Game: Deluxe Edition" && entries[0].1 == "Other" {
                let requests = await fixture.transport.requests
                #expect(!requests.contains { $0.url?.path.hasPrefix("/game/") == true })
            }
        }
    }

    @Test
    func editionsSharingSteamIDRemainAmbiguousAcrossPages() async throws {
        let fixture = Fixture(
            details: [
                1: detail(1, "Game", steam: 111),
                2: detail(2, "Game: Ultimate Edition", steam: 111)
            ],
            searches: [
                search(1, 2, [(1, "Game")]),
                search(2, 2, [(2, "Game: Ultimate Edition")])
            ]
        )
        let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [111])
        #expect(result == nil)
        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test
    func genuineEmptyAndMissingResultsAreNotErrors() async throws {
        let emptyPage = """
        <script id='__NEXT_DATA__'>
        {"props":{"pageProps":{"game":{"data":{"game":[]}}}}}
        </script>
        """
        let notFound = """
        <script id='__NEXT_DATA__'>{"props":{"pageProps":{"notFound":true}}}</script>
        """

        let fixtures = [
            Fixture(searches: [search(1, 0, [])]),
            Fixture(searches: [search(1, 1, [(1, "Game")])]),
            Fixture(details: [1: emptyPage], searches: [search(1, 1, [(1, "Game")])]),
            Fixture(details: [1: notFound], searches: [search(1, 1, [(1, "Game")])])
        ]

        for fixture in fixtures {
            let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            #expect(result == nil)
        }
    }

    @Test
    func malformedDetailsAreErrorsNotMissingTime() async {
        let valid = detail(1, "Game", steam: 111)
        let pages = [
            "<html>Access denied</html>",
            "<script id='__NEXT_DATA__'>{broken</script>",
            """
            <script id='__NEXT_DATA__'>{"props":{"pageProps":{"indexStats":{}}}}</script>
            """,
            valid.replacingOccurrences(of: "\"game_id\":1", with: "\"game_id\":2"),
            valid.replacingOccurrences(of: "\"comp_all\":237341,", with: ""),
            valid.replacingOccurrences(
                of: "\"comp_all_count\":10805",
                with: "\"comp_all_count\":\"not-a-count\""
            ),
            valid.replacingOccurrences(of: "\"comp_all\":237341", with: "\"comp_all\":-1"),
            valid.replacingOccurrences(of: "\"comp_all_count\":10805", with: "\"comp_all_count\":-1"),
            valid.replacingOccurrences(of: "\"comp_all\":237341", with: "\"comp_all\":true"),
            valid.replacingOccurrences(of: "\"comp_all\":237341", with: "\"comp_all\":1.5"),
            valid.replacingOccurrences(of: "\"profile_steam\":111", with: "\"profile_steam\":{}")
        ]

        for page in pages {
            let fixture = Fixture(
                details: [1: page],
                searches: [search(1, 1, [(1, "Game")])]
            )
            await expectError(.malformed) {
                try await fixture.client.lookup(name: "Game", steamAppIDs: [111])
            }
        }
    }

    @Test
    func integerStringsAreAcceptedWithoutTruncation() throws {
        let page = detail(
            1,
            "Game",
            steam: 111,
            stats: "\"comp_all\":\"237341\",\"comp_all_count\":\"10805\""
        )
        let parsed = try HowLongToBeatClient.parseDetailPage(page, expectedID: 1)
        #expect(parsed?.completion?.seconds == 237341)
        #expect(parsed?.steamAppIDs == [111])
    }

    @Test
    func blockedInitializationStopsBeforeSearch() async {
        for status in [401, 403, 429, 503] {
            let fixture = Fixture(initializationStatus: status)
            await expectError(.http(status)) {
                try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            }
            let requests = await fixture.transport.requests
            #expect(!requests.contains { $0.httpMethod == "POST" })
        }
    }

    @Test
    func malformedSearchShapesPaginationAndIdentitiesAreRejected() async {
        for body in [
            "<html>CAPTCHA</html>",
            "{}",
            #"{"data":{},"pageCurrent":1,"pageTotal":1}"#,
            #"{"data":[],"pageCurrent":2,"pageTotal":2}"#,
            #"{"data":[],"pageCurrent":1,"pageTotal":-1}"#,
            #"{"data":[{"game_id":1,"game_name":"Game"}],"pageCurrent":1,"pageTotal":0}"#,
            #"{"data":[{"game_id":0,"game_name":"Game"}],"pageCurrent":1,"pageTotal":1}"#,
            #"{"data":[{"game_id":1,"game_name":" "}],"pageCurrent":1,"pageTotal":1}"#,
            #"{"data":[{"game_id":true,"game_name":"Game"}],"pageCurrent":1,"pageTotal":1}"#
        ] {
            let fixture = Fixture(searches: [body])
            await expectError(.malformed) {
                try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            }
        }
    }

    @Test
    func discoveryNeverTrustsUnrelatedPOSTOrPopularHomepageData() async {
        for script in [
            "fetch('/api/unrelated', {method:'GET'})",
            "fetch('/api/login', {method:'POST'})"
        ] {
            let fixture = Fixture(script: script)
            await expectError(.malformed) {
                try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            }
            let requests = await fixture.transport.requests
            #expect(!requests.contains { $0.httpMethod == "POST" })
        }
    }

    @Test
    func discoveryRestrictsAndDeduplicatesScriptsButExaminesLaterChunks() throws {
        let html = """
        <SCRIPT SRC="/_next/static/chunks/first.js"></SCRIPT>
        <script src='/_next/static/chunks/first.js'></script>
        <script src='https://outside.invalid/script.js'></script>
        <script src='/_next/static/chunks/ignored.css'></script>
        <script src='/_next/static/chunks/search.js'></script>
        """
        #expect(HowLongToBeatClient.discoverScriptPaths(in: html) == [
            "/_next/static/chunks/first.js",
            "/_next/static/chunks/search.js"
        ])
        #expect(HowLongToBeatClient.discoverSearchPath(
            in: "fetch('/api/search/site///?ignored=1',{method:'POST'})"
        ) == "/api/search/site")
        #expect(HowLongToBeatClient.discoverSearchPath(
            in: "fetch('/api/login',{method:'POST'})"
        ) == nil)
    }

    @Test
    func failedDiscoveryBacksOffThenRetries() async {
        let fixture = Fixture(script: "fetch('/api/unrelated',{method:'GET'})")

        await expectError(.malformed) {
            try await fixture.client.lookup(name: "Game", steamAppIDs: [])
        }
        let firstCount = await fixture.transport.requests.count

        await expectError(.unavailable) {
            try await fixture.client.lookup(name: "Other", steamAppIDs: [])
        }
        let backedOffCount = await fixture.transport.requests.count
        #expect(backedOffCount == firstCount)

        fixture.clock.advance(by: 3600)
        await expectError(.malformed) {
            try await fixture.client.lookup(name: "Game", steamAppIDs: [])
        }
        let retriedCount = await fixture.transport.requests.count
        #expect(retriedCount > firstCount)
    }

    @Test
    func successfulPathIsCachedButAuthorizationRefreshesEveryLookup() async throws {
        let fixture = Fixture(searches: [search(1, 0, [])])
        _ = try await fixture.client.lookup(name: "First", steamAppIDs: [])
        _ = try await fixture.client.lookup(name: "Second", steamAppIDs: [])

        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.url?.path == "/" }.count == 1)
        #expect(requests.filter {
            $0.url?.path == "/_next/static/chunks/search.js"
        }.count == 1)
        #expect(requests.filter {
            $0.url?.path == "/api/search/site/init"
        }.count == 2)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
    }

    @Test
    func lookupIsBoundedAndSkipsUnreadableIndividualDetail() async throws {
        let entries = (1...12).map { (Int64($0), "Game \($0)") }
        let details = Dictionary(uniqueKeysWithValues: entries.map { id, name in
            (
                id,
                id == 1 ? "<html>changed</html>" : detail(
                    id,
                    name,
                    steam: id == 2 ? 111 : 0
                )
            )
        })
        let fixture = Fixture(
            details: details,
            searches: [
                search(1, 5, Array(entries.prefix(6))),
                search(2, 5, Array(entries.dropFirst(6)))
            ]
        )

        let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [111])
        #expect(result?.id == 2)

        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 2)
        #expect(requests.filter { $0.url?.path.hasPrefix("/game/") == true }.count == 5)
    }

    @Test
    func blockedDetailStopsImmediately() async {
        let fixture = Fixture(
            details: [
                2: detail(2, "Game 2", steam: 0),
                3: detail(3, "Game 3", steam: 0)
            ],
            searches: [search(1, 1, [(1, "Game 1"), (2, "Game 2"), (3, "Game 3")])],
            blockedDetails: [1]
        )

        await expectError(.http(429)) {
            try await fixture.client.lookup(name: "Game", steamAppIDs: [111])
        }
        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.url?.path.hasPrefix("/game/") == true }.count == 1)
    }

    @Test
    func optionalAuthorizationFieldsAreForwardedWithoutInventingValues() async throws {
        let fixture = Fixture(
            searches: [search(1, 0, [])],
            initialization: """
            {"token":"fixture-token","requestKey":"fixture-field","requestValue":"fixture-value"}
            """
        )
        let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [])
        #expect(result == nil)

        let requests = await fixture.transport.requests
        let post = try #require(requests.first { $0.httpMethod == "POST" })
        #expect(post.value(forHTTPHeaderField: "x-hp-key") == "fixture-field")
        #expect(post.value(forHTTPHeaderField: "x-hp-val") == "fixture-value")

        let body = try #require(post.httpBody)
        let payload = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(payload["fixture-field"] as? String == "fixture-value")

        let tokenOnly = Fixture(searches: [search(1, 0, [])])
        _ = try await tokenOnly.client.lookup(name: "Game", steamAppIDs: [])
        let tokenOnlyRequests = await tokenOnly.transport.requests
        let tokenOnlyPost = try #require(tokenOnlyRequests.first { $0.httpMethod == "POST" })
        #expect(tokenOnlyPost.value(forHTTPHeaderField: "x-hp-key") == nil)
        #expect(tokenOnlyPost.value(forHTTPHeaderField: "x-hp-val") == nil)
    }

    @Test
    func incompleteOrMalformedAuthorizationIsRejected() async {
        for initialization in [
            #"{"token":"fixture-token","requestKey":"fixture-field"}"#,
            #"{"token":"fixture-token","requestValue":"fixture-value"}"#,
            #"{"token":"fixture-token","requestKey":"","requestValue":"value"}"#,
            #"{"token":"fixture-token","requestKey":7,"requestValue":"value"}"#,
            #"{"token":true}"#,
            #"{"token":" "}"#,
            "{}",
            "<html>blocked</html>"
        ] {
            let fixture = Fixture(initialization: initialization)
            await expectError(.malformed) {
                try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            }
            let requests = await fixture.transport.requests
            #expect(!requests.contains { $0.httpMethod == "POST" })
        }
    }

    @Test
    func cancellationPropagatesAndDoesNotPoisonDiscoveryBackoff() async throws {
        let fixture = Fixture(
            searches: [search(1, 0, [])],
            cancelFirstHomepage: true
        )

        do {
            _ = try await fixture.client.lookup(name: "Game", steamAppIDs: [])
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            let requests = await fixture.transport.requests
            #expect(requests.compactMap(\.url).map(\.path) == ["/"])
        } catch {
            Issue.record("Cancellation must not become a provider error")
        }

        let result = try await fixture.client.lookup(name: "Game", steamAppIDs: [])
        #expect(result == nil)
        let requests = await fixture.transport.requests
        #expect(requests.filter { $0.url?.path == "/" }.count == 2)
    }

    @Test
    func alreadyCancelledLookupMakesNoRequests() async {
        let fixture = Fixture(searches: [search(1, 0, [])])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.client.lookup(name: "Game", steamAppIDs: [])
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            let requests = await fixture.transport.requests
            #expect(requests.isEmpty)
        } catch {
            Issue.record("Expected CancellationError")
        }
    }

    @Test
    func blankNamesDoNotContactProvider() async throws {
        let fixture = Fixture()
        for name in ["", " \n ", "™®—"] {
            let result = try await fixture.client.lookup(name: name, steamAppIDs: [111])
            #expect(result == nil)
        }
        let requests = await fixture.transport.requests
        #expect(requests.isEmpty)
    }

    private enum ExpectedError {
        case malformed
        case unavailable
        case http(Int)
    }

    private func expectError(
        _ expected: ExpectedError,
        operation: () async throws -> CompletionTime?
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected provider error")
        } catch let error as MetadataError {
            switch (expected, error) {
            case (.malformed, .malformedResponse),
                 (.unavailable, .unavailable):
                break
            case let (.http(expectedStatus), .httpStatus(actualStatus)):
                #expect(actualStatus == expectedStatus)
            default:
                Issue.record("Unexpected provider error category")
            }
        } catch {
            Issue.record("Provider failures must use MetadataError")
        }
    }

    private struct Fixture: Sendable {
        let transport: FixtureTransport
        let client: HowLongToBeatClient
        let clock: FixtureClock

        init(
            details: [Int64: String] = [:],
            searches: [String] = [],
            initializationStatus: Int = 200,
            initialization: String = #"{"token":"fixture-token"}"#,
            script: String = """
            fetch("/api/search/site",{method:"POST",headers:{"Content-Type":"application/json"}})
            """,
            blockedDetails: Set<Int64> = [],
            cancelFirstHomepage: Bool = false
        ) {
            let transport = FixtureTransport(
                details: details,
                searches: searches,
                initializationStatus: initializationStatus,
                initialization: initialization,
                script: script,
                blockedDetails: blockedDetails,
                cancelFirstHomepage: cancelFirstHomepage
            )
            let clock = FixtureClock()
            self.transport = transport
            self.clock = clock
            self.client = HowLongToBeatClient(
                http: MetadataHTTP(transport: transport),
                pacer: RequestPacer(intervalMilliseconds: 0),
                clock: { clock.now() }
            )
        }
    }

    private actor FixtureTransport: MetadataTransport {
        private(set) var requests: [URLRequest] = []

        private let details: [Int64: String]
        private let searches: [String]
        private let initializationStatus: Int
        private let initialization: String
        private let script: String
        private let blockedDetails: Set<Int64>
        private var cancelFirstHomepage: Bool

        init(
            details: [Int64: String],
            searches: [String],
            initializationStatus: Int,
            initialization: String,
            script: String,
            blockedDetails: Set<Int64>,
            cancelFirstHomepage: Bool
        ) {
            self.details = details
            self.searches = searches
            self.initializationStatus = initializationStatus
            self.initialization = initialization
            self.script = script
            self.blockedDetails = blockedDetails
            self.cancelFirstHomepage = cancelFirstHomepage
        }

        func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
            requests.append(request)

            guard let url = request.url,
                  url.scheme == "https",
                  url.host == "howlongtobeat.com" else {
                throw MetadataError.invalidRequest
            }

            let status: Int
            let body: String

            switch url.path {
            case "/":
                if cancelFirstHomepage {
                    cancelFirstHomepage = false
                    throw CancellationError()
                }
                status = 200
                body = "<script src='/_next/static/chunks/search.js'></script>"

            case "/_next/static/chunks/search.js":
                status = 200
                body = script

            case "/api/search/site/init":
                status = initializationStatus
                body = initialization

            case "/api/search/site":
                guard request.httpMethod == "POST",
                      let data = request.httpBody,
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let page = payload["searchPage"] as? Int,
                      page > 0,
                      page <= searches.count else {
                    throw MetadataError.invalidRequest
                }
                status = 200
                body = searches[page - 1]

            default:
                guard url.path.hasPrefix("/game/"),
                      let id = Int64(url.lastPathComponent) else {
                    throw MetadataError.invalidRequest
                }
                if blockedDetails.contains(id) {
                    status = 429
                    body = "rate limited"
                } else if let page = details[id] {
                    status = 200
                    body = page
                } else {
                    status = 404
                    body = "not found"
                }
            }

            return MetadataHTTPResponse(
                data: Data(body.utf8),
                status: status,
                headers: ["Content-Type": "text/plain; charset=utf-8"]
            )
        }
    }

    /// NSLock protects every access to the deliberately mutable test clock.
    private final class FixtureClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 0

        func now() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return seconds
        }

        func advance(by amount: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            seconds += amount
        }
    }

    // Inline fixtures adapted from the Android test's detail/search builders.
    private func detail(
        _ id: Int64,
        _ name: String,
        steam: Int64,
        alternativeSteam: Int64? = nil,
        stats: String = "\"comp_all\":237341,\"comp_all_count\":10805",
        banner: Bool = true
    ) -> String {
        let alternate = alternativeSteam.map { ",\"profile_steam_alt\":\($0)" } ?? ""
        let heading = banner ? "<h4>HowLongToBeat</h4><h5>66 Hours</h5>" : ""
        return heading + """
        <script type='application/json' id='__NEXT_DATA__'>
        {"props":{"pageProps":{"game":{"data":{"game":[
        {"game_id":\(id),"game_name":\(quoted(name)),"profile_steam":\(steam)\(alternate),\(stats)}
        ]}}}}}
        </script>
        """
    }

    private func search(
        _ page: Int,
        _ total: Int,
        _ entries: [(Int64, String)]
    ) -> String {
        let games = entries.map {
            "{\"game_id\":\($0.0),\"game_name\":\(quoted($0.1))}"
        }.joined(separator: ",")
        return """
        {"pageCurrent":\(page),"pageTotal":\(total),"data":[\(games)]}
        """
    }

    private func quoted(_ string: String) -> String {
        let data = try! JSONEncoder().encode(string)
        return String(decoding: data, as: UTF8.self)
    }
}
