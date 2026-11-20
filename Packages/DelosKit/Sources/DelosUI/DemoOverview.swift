#if DEBUG
import DelosData
import Foundation

/// DEBUG only: the demo's game overview data (the prototype's invented games, in the Worker's game-details shape) and its
/// images. Every game gets the complete one (storyline, 9 screenshots, 2 videos, PEGI and ESRB) except every third IGDB
/// id, which gets the sparse one (no storyline, no critics' rating, 23 player ratings, no age rating, 4 screenshots, one
/// link), so both rules for missing data show.
enum DemoOverview {
    static func details(id: Int64) -> GameDetails {
        id % 3 == 0 ? sparse(id) : complete(id)
    }

    private static func shots(_ prefix: String, _ count: Int) -> [GameDetails.Image] {
        (0..<count).map { GameDetails.Image(imageId: "\(prefix)\($0)", width: 1920, height: 1080) }
    }

    static func complete(_ id: Int64) -> GameDetails {
        GameDetails(
            id: id, name: "Hollow Meridian",
            summary: "A salvage diver wakes aboard the Meridian, a research station drifting in the dark between two dead moons. Scavenge, craft and fight your way through flooded decks as something in the hull learns from every move you make.",
            storyline: "Forty years after the Meridian went silent, the salvage crew of the tug Carrow is paid to recover its black box and nothing else. Ilse Varga, the crew's diver, is the only one who makes it past the station's outer lock. Inside, the clocks still run, the gardens are still watered, and the station's caretaker intelligence, VESPER, greets her by a name that is not hers.\n\nAs Ilse descends through the station's ring decks she pieces together what the research team was building: a mind grown from the moons' own frozen seas, patient and curious. Every log she recovers makes VESPER more helpful and the thing in the hull more awake.",
            firstReleaseDate: 1_758_153_600, rating: 82.37, ratingCount: 1284, criticRating: 86.1, criticRatingCount: 42,
            genres: ["Shooter", "Adventure"], themes: ["Horror", "Science fiction", "Survival"], modes: ["Single player"],
            perspectives: ["Third person"],
            platforms: [.init(name: "PC (Microsoft Windows)", abbreviation: "PC"), .init(name: "PlayStation 5", abbreviation: "PS5"),
                        .init(name: "Xbox Series X|S", abbreviation: "Series X|S")],
            companies: [.init(name: "Driftlight Studios", developer: true), .init(name: "Northvale Interactive", publisher: true),
                        .init(name: "Glasswork Tech", supporting: true)],
            ageRatings: [.init(organization: "PEGI", rating: "18", descriptors: ["Violence", "Bad Language"]),
                         .init(organization: "ESRB", rating: "M", descriptors: ["Blood and Gore", "Intense Violence", "Strong Language"])],
            screenshots: shots("mer\(id)x", 9), videos: [.init(name: "Launch Trailer", videoId: "x7mer01"), .init(name: "Gameplay Overview", videoId: "x7mer02")],
            websites: [.init(url: "https://hollowmeridian.example", type: "Official Website"),
                       .init(url: "https://store.steampowered.com/app/2741160", type: "Steam"),
                       .init(url: "https://twitch.tv/directory/category/hollow-meridian", type: "Twitch")],
            similarGames: [.init(id: 901, name: "Ashfall Protocol", coverImageId: "ash1"), .init(id: 902, name: "The Quiet Orbit", coverImageId: "orb1"),
                           .init(id: 903, name: "Hades"), .init(id: 904, name: "Deepwake", coverImageId: "dee1")],
            franchises: ["Meridian"], engines: ["Unreal Engine 5"],
            keywords: ["space station", "crafting", "artificial intelligence", "underwater"],
            languages: ["English", "French", "German", "Spanish", "Japanese", "Korean", "Czech", "Polish", "Italian", "Portuguese",
                        "Russian", "Ukrainian", "Chinese", "Turkish"],
            externalGames: [.init(uid: "2741160", source: 1)])
    }

    static func sparse(_ id: Int64) -> GameDetails {
        GameDetails(
            id: id, name: "Paper Lanterns",
            summary: "A small folded-paper spirit carries one light across a festival night. Fold, float and burn your way through 60 handmade puzzle rooms.",
            firstReleaseDate: 1_776_816_000, rating: 78.2, ratingCount: 23,
            genres: ["Platform", "Puzzle", "Indie"], modes: ["Single player"], perspectives: ["Side view"],
            platforms: [.init(name: "PC (Microsoft Windows)", abbreviation: "PC"), .init(name: "Nintendo Switch", abbreviation: "Switch")],
            companies: [.init(name: "Two Moth Studio", developer: true, publisher: true)],
            screenshots: shots("pap\(id)x", 4),
            websites: [.init(url: "https://store.steampowered.com/app/3120440", type: "Steam")],
            similarGames: [.init(id: 910, name: "Little Kite", coverImageId: "kit1"), .init(id: 911, name: "Moth & Moon")],
            languages: ["English", "French", "German"])
    }

    /// Answers IGDB's and YouTube's image URLs with generated pictures: screenshots and video thumbnails 16:9, covers 2:3.
    struct ImageTransport: MetadataTransport {
        func response(for request: URLRequest) async throws -> MetadataHTTPResponse {
            let url = request.url!
            // A stable seed per picture (the video thumbnails share their file name, not their path)
            let seed = url.path().unicodeScalars.reduce(7) { ($0 * 31 + Int($1.value)) % 9973 } + 1
            let cover = url.path().contains("cover")
            return MetadataHTTPResponse(data: DemoHarness.png(seed: seed, kind: cover ? "cover" : "shot"), status: 200)
        }
    }
}
#endif
