import DelosData
import Foundation
import Testing
@testable import DelosUI

@Suite struct ArtworkScreenTests {
    private let url = URL(string: "https://cdn.example/a.png")!

    @Test func theTabsStepRoundInAndroidsOrder() {
        #expect(ArtworkTab.allCases == [.cover, .wide, .hero, .logo])
        #expect(ArtworkTab.cover.step(1) == .wide)
        #expect(ArtworkTab.logo.step(1) == .cover)
        #expect(ArtworkTab.cover.step(-1) == .logo)
        #expect(ArtworkTab.hero.kind == .hero && ArtworkTab.wide.kind == .wide)
    }

    @Test func theColumnsFollowTheStageWidth() {
        #expect(ArtworkTab.allCases.map { $0.columns(forStageWidth: 1920) } == [7, 4, 3, 5])
        // A narrower stage keeps proportion, never below one column
        #expect(ArtworkTab.cover.columns(forStageWidth: 1500) == 5)
        #expect(ArtworkTab.hero.columns(forStageWidth: 800) == 1)
    }

    @Test func theGridFillsItsWidthAndKeepsRoomForTheFocusedTile() {
        for tab in ArtworkTab.allCases {
            let grid = ArtworkGrid(width: 1620, ratio: tab.ratio, columns: tab.columns)
            let used = Double(grid.columns) * grid.tileWidth + Double(grid.columns - 1) * grid.gapX
            #expect(abs(used - 1620) < 0.001)
            // The focused tile's growth and ring fit between two tiles
            #expect(grid.gapX >= grid.tileWidth * (ArtworkGrid.focusScale - 1) + ArtworkGrid.ring - 0.001)
            #expect(abs(grid.tileHeight - grid.tileWidth / tab.ratio) < 0.001)
        }
        #expect(ArtworkGrid(width: 500, ratio: 2, columns: 1).tileWidth == 500)
    }

    @Test func theInfoStripTellsOnlyWhatTheAnswerContained() {
        let bare = SteamGridDBImage(id: 1, url: url)
        #expect(ArtworkFact.of(bare).isEmpty)
        let full = SteamGridDBImage(
            id: 2, url: url, width: 600, height: 900, score: 12, author: "Zed", date: 1_700_000_000, mime: "image/jpeg")
        #expect(ArtworkFact.of(full) == [.size(width: 600, height: 900), .file("JPG"), .score(12, author: "Zed"), .added(1_700_000_000)])
        // A score of 0 is no score; an author alone, a score alone
        #expect(ArtworkFact.of(SteamGridDBImage(id: 3, url: url, author: "Zed")) == [.score(nil, author: "Zed")])
        #expect(ArtworkFact.of(SteamGridDBImage(id: 4, url: url, score: 3)) == [.score(3, author: nil)])
        #expect(ArtworkFact.of(SteamGridDBImage(id: 5, url: url, author: "  ")).isEmpty)
    }

    @Test func theFactsReadInTheInterfaceLanguage() {
        #expect(ArtworkFact.size(width: 600, height: 900).text.value == "600 × 900 px")
        #expect(ArtworkFact.score(12, author: "Zed").text.value == "12 · by Zed")
        #expect(ArtworkFact.score(12, author: nil).text.value == "12")
        #expect(ArtworkFact.score(nil, author: "Zed").text.value == "by Zed")
        // The day is counted in UTC whatever the time zone
        #expect(ArtworkFact.date(1_750_672_800, locale: Locale(identifier: "en_US")) == "Jun 23, 2025")
    }

    @Test func theStripsTitleIsTheStyleElseTheKind() {
        #expect(ArtworkFact.title(SteamGridDBImage(id: 1, url: url, style: "white_logo"), fallback: "Logo") == "White logo")
        #expect(ArtworkFact.title(SteamGridDBImage(id: 1, url: url, style: "some_new_style"), fallback: "Logo") == "Some new style")
        #expect(ArtworkFact.title(SteamGridDBImage(id: 1, url: url), fallback: "Logo") == "Logo")
    }

    @Test func aFoundGameShowsItsYearWhenItHasOne() {
        #expect(ArtworkSearch.label(SteamGridDBGame(id: 1, name: "Hades", year: 2020)) == "Hades (2020)")
        #expect(ArtworkSearch.label(SteamGridDBGame(id: 1, name: "Hades")) == "Hades")
    }

    @Test func theDescribedChoiceKnowsWhetherItIsInUse() {
        let image = SteamGridDBImage(id: 7, url: url)
        #expect(ArtworkDescribed.image(image).isInUse(.image(7)))
        #expect(!ArtworkDescribed.image(image).isInUse(.none))
        #expect(ArtworkDescribed.firstChoice.isInUse(.none))
        #expect(!ArtworkDescribed.firstChoice.isInUse(.image(7)))
    }
}
