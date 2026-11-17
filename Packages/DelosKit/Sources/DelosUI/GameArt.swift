import DelosData
import DelosHost
import ImageIO
import Observation
import SwiftUI

/// Art of a game (`GameArt` of DELOS for Android): the two hues and the icon of its procedural placeholder, and the
/// [image] of its game background once loaded (the SteamGridDB hero, else its cover, else the PC's box art).
struct GameArt: Equatable {
    /// "host/app".
    let id: String
    let hue: Double
    let hue2: Double
    let icon: String
    var image: CGImage?

    static func == (a: GameArt, b: GameArt) -> Bool {
        a.id == b.id && a.image.map(ObjectIdentifier.init) == b.image.map(ObjectIdentifier.init)
    }

    /// The placeholder's hues from the app's name (`appArt`: Java's `String.hashCode`, so both apps pick the same).
    init(hostID: String, app: HostApp, image: CGImage? = nil) {
        id = Self.key(hostID, app.id)
        let hue = Double(Int(Self.javaHash(app.title) & 0x7fff_ffff) % 360)
        self.hue = hue
        hue2 = (hue + 35).truncatingRemainder(dividingBy: 360)
        icon = Self.builtInIcon(app) ?? Symbols.sportsEsports
        self.image = image
    }

    /// The placeholder's icon of DELOS's own entries (`appArt`), nil for a game.
    static func builtInIcon(_ app: HostApp) -> String? { BundledArtwork.kind(app)?.icon }

    static func key(_ hostID: String, _ appID: Int) -> String { "\(hostID)/\(appID)" }

    /// `String.hashCode` of the JVM: s[0]·31^(n−1) + … + s[n−1] over UTF-16 code units, in 32-bit arithmetic.
    static func javaHash(_ text: String) -> Int32 {
        text.utf16.reduce(Int32(0)) { $0 &* 31 &+ Int32($1) }
    }
}

/// The artwork of the library on screen (the image half of DELOS for Android's `ArtworkStore`, `BoxArtCache` and
/// `HeroBitmaps`): decoded images kept in memory, each game's colors, the rendered game backgrounds, and the game
/// background the backdrop shows ([hero], `ShellState.hero`).
@MainActor
@Observable
final class HomeArt {
    /// The focused game's art while the library shows; the backdrop draws it.
    var hero: GameArt?
    /// The colors of each game's cover once worked out (a nil value: a grey cover), by game key.
    private(set) var coverColors: [String: GameColors?] = [:]
    /// The colors of each game's background once rendered.
    private(set) var heroColors: [String: GameColors?] = [:]

    @ObservationIgnored let artwork: ArtworkStore
    @ObservationIgnored private var images = MemoryCache<CGImage>(imageBytes: 96 * 1024 * 1024)
    @ObservationIgnored private var renders = MemoryCache<CGImage>(imageBytes: 64 * 1024 * 1024)
    /// The image each game's cover colors were taken from.
    @ObservationIgnored private var coverSources: [String: ObjectIdentifier] = [:]

    init(artwork: ArtworkStore) {
        self.artwork = artwork
    }

    /// The colors the interface takes from a game: its cover's, the game background's while those are unknown.
    func gameColors(_ key: String) -> GameColors? {
        if let cover = coverColors[key] { return cover }
        return heroColors[key] ?? nil
    }

    /// Whether the game's colors are worked out (they may be nil: a grey image).
    func colorsKnown(_ key: String) -> Bool { coverColors[key] != nil || heroColors[key] != nil }

    /// The main hue of the game's background once rendered (the title's gradient).
    func heroHue(_ key: String) -> Double? { (heroColors[key] ?? nil)?.hues.first }

    // MARK: Images

    /// The SteamGridDB image of [kind], decoded; nil when there is none.
    func image(hostID: String, appID: Int, kind: ArtKind) async -> CGImage? {
        let key = "sgdb/\(hostID)/\(appID)/\(kind.rawValue)#\(artwork.version)"
        if let image = images[key] { return image }
        guard let data = await artwork.image(hostID: hostID, appID: appID, kind: kind),
              let image = await Self.decode(data, maxPixels: kind == .logo ? 1200 : kind == .hero ? 2560 : 1500) else { return nil }
        images[key] = image
        return image
    }

    /// The image of [kind] for [app]: DELOS's own entries (Desktop, Remote Input, ...) have bundled artwork, a game its
    /// SteamGridDB image; nil when there is none (the logo of a bundled entry is its name).
    func image(hostID: String, app: HostApp, kind: ArtKind) async -> CGImage? {
        guard let bundled = BundledArtwork.kind(app) else { return await image(hostID: hostID, appID: app.id, kind: kind) }
        let key = "bundled/\(bundled.rawValue)/\(kind.rawValue)"
        if let image = images[key] { return image }
        guard let image = await BundledArtwork.image(bundled, kind, maxPixels: kind == .hero ? 2560 : 1500) else { return nil }
        images[key] = image
        return image
    }

    /// The same without waiting, for what is in memory already.
    func cachedImage(hostID: String, app: HostApp, kind: ArtKind) -> CGImage? {
        if let bundled = BundledArtwork.kind(app) { return images["bundled/\(bundled.rawValue)/\(kind.rawValue)"] }
        return cachedImage(hostID: hostID, appID: app.id, kind: kind)
    }

    /// The PC's box art of an app, from the cache or the PC.
    func boxArt(hostID: String, appID: Int, hosts: HostStore) async -> CGImage? {
        let key = "box/\(hostID)/\(appID)"
        if let image = images[key] { return image }
        guard let (client, _, pin) = try? hosts.pairedClient(hostID),
              let data = await artwork.boxArt(hostID: hostID, appID: appID, fetch: { try await client.appAsset(appID: appID, pin: pin) }),
              let image = await Self.decode(data, maxPixels: 1500) else { return nil }
        images[key] = image
        return image
    }

    /// A choice's thumbnail on the Artwork screen, decoded no larger than a tile needs.
    func thumbnail(_ image: SteamGridDBImage) async -> CGImage? {
        let key = "thumb/\(image.id)"
        if let cached = images[key] { return cached }
        guard let data = await artwork.thumbnail(image), let decoded = await Self.decode(data, maxPixels: 700) else { return nil }
        images[key] = decoded
        return decoded
    }

    func cachedThumbnail(_ image: SteamGridDBImage) -> CGImage? { images["thumb/\(image.id)"] }

    func cachedImage(hostID: String, appID: Int, kind: ArtKind) -> CGImage? {
        images["sgdb/\(hostID)/\(appID)/\(kind.rawValue)#\(artwork.version)"]
    }

    func cachedBoxArt(hostID: String, appID: Int) -> CGImage? { images["box/\(hostID)/\(appID)"] }

    /// Decodes an image no larger than [maxPixels] on its longer side, off the main thread.
    nonisolated static func decode(_ data: Data, maxPixels: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }.value
    }

    // MARK: Colors and backgrounds

    /// Works out the colors of a game's [cover] once per image (`HeroBitmaps.analyzeCover`), off the main thread.
    func analyzeCover(_ key: String, _ cover: CGImage) {
        let source = ObjectIdentifier(cover)
        guard coverSources[key] != source else { return }
        coverSources[key] = source
        Task {
            let colors = await Task.detached(priority: .utility) { () -> GameColors? in
                let width = 120, height = min(max(Int(120.0 * Double(cover.height) / Double(max(cover.width, 1))), 1), 360)
                guard var small = Bitmap(width: width, height: height) else { return nil }
                small.draw(cover, in: CGRect(x: 0, y: 0, width: width, height: height))
                return GameColors.dominant(small.argb())
            }.value
            // A newer image of the game is on its way: its colors replace these
            guard coverSources[key] == source else { return }
            coverColors[key] = .some(colors)
        }
    }

    /// The game background of [art] with a blur of [blur] stage pixels for [area], rendered once and kept.
    func background(_ art: GameArt, blur: Int, area: HeroArea) async -> CGImage? {
        guard let source = art.image else { return nil }
        let key = "\(art.id)/\(ObjectIdentifier(source).hashValue)/\(blur)/\(area.width)x\(area.height)"
        if let image = renders[key] { return image }
        guard let result = await Task.detached(priority: .userInitiated, operation: { HeroRender.render(source, blur: blur, area: area) }).value
        else { return nil }
        renders[key] = result.image
        heroColors[art.id] = .some(result.colors)
        return result.image
    }

    func cachedBackground(_ art: GameArt, blur: Int, area: HeroArea) -> CGImage? {
        guard let source = art.image else { return nil }
        return renders["\(art.id)/\(ObjectIdentifier(source).hashValue)/\(blur)/\(area.width)x\(area.height)"]
    }
}

/// A small least-recently-used memory cache limited by cost (decoded images: bytes), not by count. A value dearer than
/// the whole limit is not kept.
struct MemoryCache<Value> {
    let costLimit: Int
    private let cost: (Value) -> Int
    private var values: [String: (value: Value, cost: Int)] = [:]
    private var order: [String] = []
    private(set) var totalCost = 0

    init(costLimit: Int, cost: @escaping (Value) -> Int) {
        self.costLimit = costLimit
        self.cost = cost
    }

    subscript(key: String) -> Value? {
        mutating get {
            guard let entry = values[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return entry.value
        }
        set {
            order.removeAll { $0 == key }
            if let old = values.removeValue(forKey: key) { totalCost -= old.cost }
            guard let newValue else { return }
            let price = cost(newValue)
            guard price <= costLimit else { return }
            values[key] = (newValue, price)
            totalCost += price
            order.append(key)
            while totalCost > costLimit, !order.isEmpty {
                if let dropped = values.removeValue(forKey: order.removeFirst()) { totalCost -= dropped.cost }
            }
        }
    }
}

extension MemoryCache where Value == CGImage {
    /// A cache of decoded images: a bitmap costs width × height × 4 bytes.
    init(imageBytes: Int) {
        self.init(costLimit: imageBytes) { $0.width * $0.height * 4 }
    }
}
