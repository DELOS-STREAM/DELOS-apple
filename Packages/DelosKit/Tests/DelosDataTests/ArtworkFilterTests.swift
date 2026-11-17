import Foundation
import Synchronization
import Testing
@testable import DelosData

@Suite struct ArtworkFilterTests {
    private func items(_ query: ArtQuery) -> [String: String] {
        Dictionary(uniqueKeysWithValues: query.params.map { ($0.name, $0.value ?? "") })
    }

    private func image(_ id: Int, score: Int = 0, date: Int? = nil, animated: Bool = false) -> SteamGridDBImage {
        SteamGridDBImage(id: id, url: URL(string: "https://cdn.example/\(id).png")!, score: score, date: date, animated: animated)
    }

    @Test func noFilterAsksForBothTypesOfEveryKindButLogos() {
        let cover = ArtFilterRules.queries(.cover, ArtFilters())
        #expect(cover.map(\.animated) == [false, true])
        #expect(items(cover[0]) == ["types": "static", "nsfw": "false", "humor": "false", "mimes": "image/png,image/jpeg,image/webp",
                                    "dimensions": "600x900,660x930,342x482"])
        #expect(items(cover[1])["types"] == "animated" && items(cover[1])["mimes"] == "image/webp")
        #expect(ArtFilterRules.queries(.logo, ArtFilters(type: .animated)).map(\.animated) == [false])
        #expect(items(ArtFilterRules.queries(.hero, ArtFilters())[0])["dimensions"] == nil)
    }

    @Test func styleAndDimensionsGoIntoTheRequest() {
        let queries = ArtFilterRules.queries(.cover, ArtFilters(type: .still, style: "blurred", dimensions: "342x482"))
        #expect(queries.count == 1)
        #expect(items(queries[0])["styles"] == "blurred" && items(queries[0])["dimensions"] == "342x482")
        // A value the kind cannot filter by never reaches a request
        let stale = ArtFilterRules.queries(.logo, ArtFilters(type: .animated, style: "blurred", dimensions: "600x900"))
        #expect(items(stale[0])["styles"] == nil && items(stale[0])["dimensions"] == nil && items(stale[0])["types"] == "static")
    }

    @Test func theFilterPillCountsWhatDiffersFromTheDefaults() {
        #expect(ArtFilters().activeCount == 0 && !ArtFilters().active)
        let all = ArtFilters(type: .animated, style: "alternate", dimensions: "600x900", sort: .newest)
        #expect(all.activeCount == 4)
        #expect(ArtFilterRules.chips(all) == [.type(.animated), .style("alternate"), .dimensions("600x900"), .sort(.newest)])
        #expect(ArtFilterRules.clear(all, .style("alternate")) == ArtFilters(type: .animated, dimensions: "600x900", sort: .newest))
    }

    @Test func mergeKeepsAnImageOnceAndInterleavesTheAnswers() {
        let merged = ArtFilterRules.merge([[image(1), image(2), image(3)], [image(2), image(9, animated: true)]])
        #expect(merged.map(\.id) == [1, 9, 2, 3])
    }

    @Test func sortsAreStableAndFallBackToTheId() {
        let images = [image(1, score: 5, date: 10), image(2, score: 9, date: 5), image(3, score: 5, date: nil), image(4, score: 9, date: 5)]
        #expect(ArtFilterRules.sort(images, .score).map(\.id) == [2, 4, 1, 3])
        #expect(ArtFilterRules.sort(images, .newest).map(\.id) == [1, 4, 2, 3])
        #expect(ArtFilterRules.sort(images, .oldest).map(\.id) == [2, 4, 1, 3])
    }

    @Test func theCacheKeyIgnoresTheSort() {
        #expect(ArtFilterRules.cacheKey(.cover, ArtFilters(sort: .newest)) == ArtFilterRules.cacheKey(.cover, ArtFilters()))
        #expect(ArtFilterRules.cacheKey(.cover, ArtFilters(type: .still)) != ArtFilterRules.cacheKey(.cover, ArtFilters()))
    }

    @Test func theClientSendsBothRequestsAndKeepsTheStillImagesWhenTheAnimatedOneFails() async throws {
        let seen = Mutex<[String]>([])
        let client = SteamGridDB(key: "k") { request in
            let query = request.url!.query() ?? ""
            seen.withLock { $0.append(query) }
            let animated = query.contains("types=animated")
            let status = animated ? 500 : 200
            let body = animated ? "" : #"{"success":true,"data":[{"id":1,"url":"https://cdn.example/a.png","score":3}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let images = try await client.images(gameID: 7, kind: .hero, filters: ArtFilters())
        #expect(images.map(\.id) == [1] && !images[0].animated)
        #expect(seen.withLock { $0.count } == 2)
    }
}
