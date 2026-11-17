import CoreGraphics
import DelosHost
import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import DelosData

/// A 64 × 48 animated WebP of four frames lasting 40, 0, 250 and 1000 ms, the last three drawn as partial frames (a blue
/// square moving over a red canvas), made with img2webp and its second duration set to 0 by hand (img2webp refuses 0).
let animatedWebP = Data(base64Encoded: """
UklGRlIBAABXRUJQVlA4WAoAAAASAAAAPwAALwAAQU5JTQYAAAD/////AABBTk1GPAAAAAAAAAAA\
AD8AAC8AACgAAAJWUDhMJAAAAC8/wAsAD/AGkxf8z//8xxLUBEDCMPpnpgDoG9H/CcB74zZ9AUFO\
TUZGAAAAAAAADgAAFQAACQAAAAAAAFZQOEwuAAAALxVAAhAXIBBIcQJrrCBtA6Z7/iVv/uc/wLcF\
RW3bQK9e41eSpToCEf2PFtt9AUFOTUZGAAAABgAADgAAFQAACQAA+gAAAFZQOEwuAAAALxVAAhAX\
IBBIcQJrrCBtA6Z7/iVv/uc/wLcFRW3bQK9e41eSpToCEf2PFtt9AUFOTUZGAAAADAAADgAAFQAA\
CQAA6AMAAFZQOEwuAAAALxVAAhAXIBBIcQJrrCBtA6Z7/iVv/uc/wLcFRW3bQK9e41eSpToCEf2P\
Ftt9AQ==
""")!

/// An image of [delays].count frames of 32 × 24 (one frame and no delays: a still image) of the given type.
func encodedImage(_ type: UTType, delays: [Double]?) -> Data {
    let count = delays?.count ?? 1
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, count, nil)!
    let gif = type == .gif
    for index in 0..<count {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: index * 6, y: 8, width: 6, height: 6))
        let properties = delays.map { delays in
            gif ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[index]]] as CFDictionary
                : [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delays[index]]] as CFDictionary
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, properties)
    }
    CGImageDestinationFinalize(destination)
    return out as Data
}

/// The frame timing, caps and readings of ``AnimatedImageInfo`` (the Android platform's `AnimatedImageDrawable` rules and
/// `AnimatedWebpTest` of DELOS for Android).
@Suite struct AnimatedImageInfoTests {
    @Test func aWebPFrameKeepsTheDurationItsFileSaysEvenZero() {
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0.04, clampedSeconds: 0.04, gif: false) == 40)
        // ImageIO's clamped delay is 100 ms here; the platform's is the file's own
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0, clampedSeconds: 0.1, gif: false) == 0)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0.005, clampedSeconds: 0.1, gif: false) == 5)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 1.25, clampedSeconds: 1.25, gif: false) == 1250)
    }

    @Test func aGIFFrameOfTenMillisecondsOrLessLastsAHundred() {
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0, clampedSeconds: 0.1, gif: true) == 100)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0.01, clampedSeconds: 0.1, gif: true) == 100)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: 0.02, clampedSeconds: 0.02, gif: true) == 20)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: nil, clampedSeconds: nil, gif: true) == 100)
    }

    @Test func theClampedDelayStandsInOnlyWhenTheFileHasNoOtherAndNothingIsNegative() {
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: nil, clampedSeconds: 0.07, gif: false) == 70)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: nil, clampedSeconds: nil, gif: false) == 0)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: -1, clampedSeconds: 0.1, gif: false) == 0)
        #expect(AnimatedImageInfo.frameMillis(unclampedSeconds: .nan, clampedSeconds: 0.1, gif: false) == 0)
    }

    @Test func onlyAnAnimationOnACanvasOfAtMostAHundredMillionPixelsPlays() {
        #expect(AnimatedImageInfo.playable(frameCount: 2, width: 3840, height: 1240))
        #expect(AnimatedImageInfo.playable(frameCount: 2, width: 10_000, height: 10_000))
        #expect(!AnimatedImageInfo.playable(frameCount: 2, width: 10_000, height: 10_001))
        #expect(!AnimatedImageInfo.playable(frameCount: 1, width: 600, height: 900))
        #expect(!AnimatedImageInfo.playable(frameCount: 2, width: 0, height: 900))
    }

    @Test func anAnimatedWebPIsReadWithItsCanvasAndDurations() throws {
        let info = try #require(AnimatedImageInfo.of(animatedWebP))
        #expect(info.width == 64 && info.height == 48)
        #expect(info.durations == [40, 0, 250, 1000])
        #expect(info.loopMillis == 1290)
    }

    @Test func aGIFAndAnAPNGPlayToo() throws {
        let gif = try #require(AnimatedImageInfo.of(encodedImage(.gif, delays: [0.04, 0, 0.01, 0.25])))
        #expect(gif.durations == [40, 100, 100, 250])
        let apng = try #require(AnimatedImageInfo.of(encodedImage(.png, delays: [0.04, 0.5, 0.25])))
        #expect(apng.durations == [40, 500, 250])
        #expect(apng.width == 32 && apng.height == 24)
    }

    @Test func aStillImageOrSomethingElseDoesNotPlay() {
        #expect(AnimatedImageInfo.of(encodedImage(.png, delays: nil)) == nil)
        #expect(AnimatedImageInfo.of(encodedImage(.jpeg, delays: nil)) == nil)
        #expect(AnimatedImageInfo.of(Data("not an image".utf8)) == nil)
    }

    @Test func eachFrameIsDecodedWholeAtTheSizeAskedFor() async throws {
        let decoder = try #require(AnimatedFrameDecoder(data: animatedWebP, maxPixelSize: 64))
        // Frame 2 only redraws x 12…33: the rest of the canvas comes from the frames before it
        let frame = try #require(await decoder.frame(2))
        #expect(frame.width == 64 && frame.height == 48)
        #expect(color(frame, x: 28, y: 15) == "blue")
        #expect(color(frame, x: 5, y: 15) == "red" && color(frame, x: 50, y: 15) == "red")
        let small = try #require(await AnimatedFrameDecoder(data: animatedWebP, maxPixelSize: 32)?.frame(3))
        #expect(small.width == 32 && small.height == 24)
        #expect(await decoder.frame(9) == nil)
    }

    /// The color at ([x], [y]) of [image], y from the bottom as Core Graphics draws.
    private func color(_ image: CGImage, x: Int, y: Int) -> String {
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let at = ((h - 1 - y) * w + x) * 4
        return pixels[at + 2] > 200 && pixels[at] < 50 ? "blue" : pixels[at] > 200 && pixels[at + 2] < 50 ? "red" : "other"
    }
}

/// The animated artwork the store keeps and finds (`ArtworkStore.animatedFile` and `Thumbnails.loadAnimation`).
@MainActor
@Suite struct AnimatedArtworkStoreTests {
    private final class Files: Sendable {
        let routes: [String: (Int, Data)]
        let requests = Mutex<[String]>([])

        init(_ routes: [String: (Int, Data)]) { self.routes = routes }

        var transport: SteamGridDB.Transport {
            { [self] request in
                let url = request.url!
                let key = url.host() == "cdn.example" ? url.path() : String(url.path().dropFirst("/api/v2/".count))
                requests.withLock { $0.append(key) }
                let (status, data) = routes[key] ?? (404, Data())
                return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }

        func count(_ key: String) -> Int { requests.withLock { $0.filter { $0 == key }.count } }
    }

    private static func list(_ entries: String) -> Data { Data(#"{"success":true,"data":[\#(entries)]}"#.utf8) }

    private func store(_ files: Files) -> ArtworkStore {
        let secrets = ArtworkStoreTests.MemoryStorage()
        try? secrets.write(Data("k".utf8), account: "api-key")
        let directory = FileManager.default.temporaryDirectory.appending(path: "delos-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ArtworkStore(
            secrets: secrets, defaults: UserDefaults(suiteName: "delos.tests.\(UUID().uuidString)")!, matches: directory,
            cache: DiskCache(directory: directory.appending(path: "cache"), budget: 1_000_000, maxEntryBytes: 100_000), transport: files.transport)
    }

    @Test func aChosenAnimationIsStoredAsDownloadedAndFoundAgain() async throws {
        let still = encodedImage(.png, delays: nil)
        let files = Files([
            "search/autocomplete/Hades": (200, Self.list(#"{"id":7,"name":"Hades"}"#)),
            "grids/game/7": (200, Self.list(#"{"id":70,"url":"https://cdn.example/cover.png"}"#)),
            "heroes/game/7": (200, Self.list(#"{"id":71,"url":"https://cdn.example/hero.webp"}"#)),
            "logos/game/7": (200, Self.list("")),
            "/cover.png": (200, still),
            "/hero.webp": (200, animatedWebP),
        ])
        let artwork = store(files)
        try await artwork.fetch(hostID: "PC", appID: 1, name: "Hades")
        // The hero keeps every frame: the still readers get the same bytes and decode the first one
        #expect(await artwork.image(hostID: "PC", appID: 1, kind: .hero) == animatedWebP)
        #expect(await artwork.animation(hostID: "PC", appID: 1, kind: .hero) == animatedWebP)
        #expect(await artwork.animation(hostID: "PC", appID: 1, kind: .cover) == nil)
        #expect(await artwork.animation(hostID: "PC", appID: 1, kind: .logo) == nil)
    }

    @Test func aChoiceWhoseThumbnailIsStillPlaysItsFullFile() async throws {
        let files = Files([
            "/thumb.png": (200, encodedImage(.png, delays: nil)),
            "/full.webp": (200, animatedWebP),
        ])
        let artwork = store(files)
        let image = SteamGridDBImage(id: 5, url: URL(string: "https://cdn.example/full.webp")!,
                                     thumb: URL(string: "https://cdn.example/thumb.png")!, mime: "image/webp", animated: true)
        #expect(!artwork.hasNoAnimation(image))
        #expect(await artwork.animation(of: image) == animatedWebP)
        #expect(artwork.animationProgress.isEmpty)
        // Kept: asked again, nothing is downloaded
        #expect(await artwork.animation(of: image) == animatedWebP)
        #expect(files.count("/thumb.png") == 1 && files.count("/full.webp") == 1)
        #expect(!artwork.hasNoAnimation(image))
    }

    @Test func aChoiceThatDoesNotAnimateKeepsItsFirstFrameAndIsNotFetchedAgain() async throws {
        let files = Files(["/thumb.png": (200, encodedImage(.png, delays: nil)), "/full.jpg": (200, encodedImage(.jpeg, delays: nil))])
        let artwork = store(files)
        // The full file of a type that cannot animate is never fetched
        let image = SteamGridDBImage(id: 6, url: URL(string: "https://cdn.example/full.jpg")!,
                                     thumb: URL(string: "https://cdn.example/thumb.png")!, mime: "image/jpeg", animated: true)
        #expect(await artwork.animation(of: image) == nil)
        #expect(artwork.hasNoAnimation(image))
        #expect(await artwork.animation(of: image) == nil)
        #expect(files.count("/thumb.png") == 1 && files.count("/full.jpg") == 0)
        // A still choice has no animation to look for
        let plain = SteamGridDBImage(id: 7, url: URL(string: "https://cdn.example/thumb.png")!, animated: false)
        #expect(await artwork.animation(of: plain) == nil)
    }

    @Test func aFailedDownloadIsTriedAgain() async throws {
        let files = Files([:])
        let artwork = store(files)
        let image = SteamGridDBImage(id: 8, url: URL(string: "https://cdn.example/gone.webp")!, mime: "image/webp", animated: true)
        #expect(await artwork.animation(of: image) == nil)
        #expect(!artwork.hasNoAnimation(image))
        _ = await artwork.animation(of: image)
        #expect(files.count("/gone.webp") == 2)
    }
}
