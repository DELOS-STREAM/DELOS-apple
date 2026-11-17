import Testing
@testable import DelosData

/// Ports the ranking and Steam-tag rules of Android's GameTags.kt and SteamTags.kt.
@Suite struct GameTagsTests {
    private func genre(_ id: Int, _ name: String = "") -> GameGenre { GameGenre(id: id, name: name.isEmpty ? "g\(id)" : name) }

    @Test func aShooterAndAdventureIsAShooterAndPuzzleBeatsNothingAdventure() {
        #expect(GameTags.rankedGenres([genre(31), genre(5)]).map(\.id) == [5, 31])
        #expect(GameTags.rankedGenres([genre(9), genre(31)]).map(\.id) == [31, 9])
        #expect(GameTags.rankedGenres([genre(14), genre(13)]).map(\.id) == [14, 13])
    }

    @Test func unknownGenresComeAfterTheLadderInTheirOwnOrderWithoutDuplicates() {
        #expect(GameTags.rankedGenres([genre(99), genre(5), genre(98), genre(5)]).map(\.id) == [5, 99, 98])
    }

    @Test func indieCountsOnlyWhenNothingElseIsListed() {
        #expect(GameTags.rankedGenres([genre(32), genre(8)]).map(\.id) == [8])
        #expect(GameTags.rankedGenres([genre(32)]).map(\.id) == [32])
        #expect(GameTags.topGenres([genre(32), genre(8)], steamTags: [], limit: 2).map(\.id) == [8])
    }

    @Test func eroticIsNeverShownAndActionOnlyAsTheOneUsableTheme() {
        #expect(GameTags.rankedThemes([GameGenre(id: 42, name: "Erotic"), GameGenre(id: 19, name: "Horror")]).map(\.id) == [19])
        #expect(GameTags.rankedThemes([GameGenre(id: 1, name: "Action"), GameGenre(id: 19, name: "Horror")]).map(\.id) == [19])
        #expect(GameTags.rankedThemes([GameGenre(id: 1, name: "Action"), GameGenre(id: 42, name: "Erotic")]).map(\.id) == [1])
        #expect(GameTags.rankedThemes([GameGenre(id: 42, name: "Erotic")]).isEmpty)
    }

    @Test func steamTagsMapOntoIGDBEntriesInVoteOrder() {
        let genres = GameTags.steamGenres(["Indie", "Platformer", "  Co-op ", "Puzzle", "Platformer"])
        #expect(genres.map(\.id) == [8, 9])
        #expect(genres.map(\.name) == ["Platform", "Puzzle"])
        #expect(GameTags.steamThemes(["Cyberpunk", "Horror", "Sci-fi"]).map(\.id) == [18, 19])
    }

    @Test func steamTagsMatchCaseInsensitivelyAndStraightenApostrophes() {
        #expect(GameTags.steamGenres(["first-person shooter"]).map(\.id) == [5])
        #expect(GameTags.steamGenres(["Beat \u{2019}em up"]).map(\.id) == [25])
        #expect(GameTags.steamGenres(["Real   Time Strategy"]).map(\.id) == [11])
    }

    @Test func aWeakGenreJoinsOnlyWhenFewerThanTwoStrongOnesExist() {
        #expect(GameTags.steamGenres(["Roguelike", "Platformer"]).map(\.id) == [8, 12])
        #expect(GameTags.steamGenres(["Roguelike", "Platformer", "Puzzle"]).map(\.id) == [8, 9])
    }

    @Test func onlyTheMostVotedFifteenTagsCount() {
        let filler = (0..<15).map { "x\($0)" }
        #expect(GameTags.steamGenres(filler + ["Platformer"]).isEmpty)
        #expect(GameTags.steamGenres(Array(filler.dropFirst()) + ["Platformer"]).map(\.id) == [8])
    }

    @Test func steamGivesTheCardAndIGDBFillsTheRest() {
        let igdb = [genre(5), genre(31)]
        #expect(GameTags.topGenres(igdb, steamTags: ["Puzzle"]).map(\.id) == [9, 5])
        #expect(GameTags.topGenres(igdb, steamTags: ["Puzzle", "Platformer", "Racing"]).map(\.id) == [9, 8])
        #expect(GameTags.topGenres(igdb, steamTags: ["Co-op"]).map(\.id) == [5, 31])
        #expect(GameTags.topGenres(igdb, steamTags: ["Shooter"]).map(\.id) == [5, 31])
    }

    @Test func actionIsAThemeOnlyWhenNothingElseSaysMore() {
        let action = GameGenre(id: 1, name: "Action")
        #expect(GameTags.topThemes([action], steamTags: ["Horror"]).map(\.id) == [19])
        #expect(GameTags.topThemes([action], steamTags: []).map(\.id) == [1])
        #expect(GameTags.topThemes([], steamTags: ["Superhero"]).map(\.id) == [1])
    }

    @Test func noTagTableMapsOneNameTwice() {
        for table in [GameTags.genreTags, GameTags.weakGenreTags, GameTags.themeTags, GameTags.weakThemeTags] {
            let keys = table.flatMap(\.tags).map(GameTags.tagKey)
            #expect(Set(keys).count == keys.count)
        }
        #expect(GameTags.genreTags.allSatisfy { GameTags.genreNames[$0.id] != nil })
        #expect(GameTags.themeTags.allSatisfy { GameTags.themeNames[$0.id] != nil })
    }
}
