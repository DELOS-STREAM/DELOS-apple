import CoreGraphics
import DelosData
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DelosUI

/// Animated artwork played in real time through the app's own players, as the home screen plays it on the iPad Pro 13"
/// (a 1920 × 1440 stage at 0.72 points per stage pixel, two pixels per point): a wide file as the game background
/// (``LoopedAnimation`` of ``HeroFrameRender``'s frames at the default blur), a tall one as a cover (``AnimationPlayer`` at
/// the focused cover's size). Each case draws at 120 Hz for 2 s, as the view's `TimelineView` does, with the main thread
/// idle and then busy for 5 ms of every display frame (as with a screen's own work), and prints the frames it presented
/// against the frames the file's own timing has in that time, the longest a frame stayed against the longest the file
/// keeps one (display frames), what one frame costs on its way (decoded, and rendered for a hero, off the main thread) and
/// what a display frame costs the main thread. Nothing about the machine's speed is asserted.
///
/// A harness, not part of the normal run:
///
///     DELOS_ART_BENCH=1 swift test --filter AnimatedArtBenchmark
///
/// plays generated APNGs (a 1920 × 620 hero and a 600 × 900 cover, 30 frames a second); DELOS_ART_BENCH=/a.png:/b.webp
/// plays those files instead (SteamGridDB's animated heroes and covers: APNG, GIF, animated WebP).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DELOS_ART_BENCH"] != nil))
struct AnimatedArtBenchmark {
    nonisolated static let refresh = 120.0
    nonisolated static let seconds = 2.0
    /// The iPad Pro 13" stage and the focused cover's size there, pixels.
    nonisolated static let area = HeroArea.of(stageWidth: 1920, stageHeight: 1440)
    nonisolated static let cover = (width: 454, height: 681)
    nonisolated static let blur = Appearance().heroBlur

    struct Sample: Sendable, CustomStringConvertible {
        let name: String
        let data: Data
        var description: String { name }
    }

    nonisolated static var samples: [Sample] {
        guard let value = ProcessInfo.processInfo.environment["DELOS_ART_BENCH"] else { return [] }
        let paths = value.split(separator: ":").map(String.init).filter { $0 != "1" && !$0.isEmpty }
        if paths.isEmpty {
            return [Sample(name: "generated hero 1920x620", data: generated(width: 1920, height: 620)),
                    Sample(name: "generated cover 600x900", data: generated(width: 600, height: 900))]
        }
        return paths.compactMap { path in
            (try? Data(contentsOf: URL(fileURLWithPath: path))).map { Sample(name: (path as NSString).lastPathComponent, data: $0) }
        }
    }

    @Test(arguments: samples, [0.0, 5.0])
    func playsAtTheFilesOwnPace(_ sample: Sample, busyMillis: Double) async throws {
        let info = try #require(AnimatedImageInfo.of(sample.data), "\(sample.name) is no animation ImageIO plays")
        let hero = info.width > info.height
        let maxWidth: Int, maxHeight: Int, render: (@Sendable (CGImage) -> CGImage?)?
        let draw: () -> [ObjectIdentifier]
        if hero {
            let still = try #require(await HomeArt.decode(sample.data, maxPixels: 2560))
            let (blur, area) = (Self.blur, Self.area)
            let frames = try #require(await Task.detached { HeroFrameRender(still: still, blur: blur, area: area) }.value)
            let looped = try #require(await LoopedAnimation.load(sample.data, label: sample.name, maxWidth: frames.decodeWidth,
                                                                 render: frames.frame))
            (maxWidth, maxHeight, render) = (frames.decodeWidth, .max, frames.frame)
            draw = {
                let frame = looped.frame(at: .now)
                return [ObjectIdentifier(frame.bottom)] + (frame.top.map { [ObjectIdentifier($0)] } ?? [])
            }
        } else {
            let player = try #require(await AnimationPlayer.load(sample.data, label: sample.name, maxWidth: Self.cover.width,
                                                                 maxHeight: Self.cover.height))
            (maxWidth, maxHeight, render) = (Self.cover.width, Self.cover.height, nil)
            draw = { [ObjectIdentifier(player.frame(at: .now))] }
        }

        // The display frames: what the file's timing shows in that time, and what the player presented
        let ticks = Int(Self.seconds * Self.refresh)
        var due = FrameClock(durations: info.durations, repeats: true, now: 0)
        var expected = 1, ideal = 0, idealHeld = 0
        for tick in 1...ticks {
            if due.draw(at: Double(tick) * 1000 / Self.refresh, ready: true) {
                expected += 1
                idealHeld = 0
            } else {
                idealHeld += 1
                ideal = max(ideal, idealHeld)
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        var presented = 0, longest = 0, held = 0
        var shown: [ObjectIdentifier] = []
        var mainThread: [Double] = []
        for tick in 0..<ticks {
            let before = clock.now
            let frame = draw()
            mainThread.append(Self.millis(clock.now - before))
            if frame != shown {
                presented += 1
                held = 0
                shown = frame
            } else {
                held += 1
                longest = max(longest, held)
            }
            let busy = clock.now + .milliseconds(busyMillis)
            while clock.now < busy {}
            try await clock.sleep(until: start + .seconds(Double(tick + 1) / Self.refresh), tolerance: .zero)
        }

        // One frame's cost off the main thread: decoded alone, then decoded and rendered as the player does it
        let size = AnimatedPlayback.decodeSize(width: info.width, height: info.height, maxWidth: maxWidth, maxHeight: maxHeight)
        let pixels = max(size.width, size.height)
        let decodeOnly = try await Self.cost(sample.data, pixels: pixels, render: nil, frames: info.frameCount)
        let whole = render == nil ? decodeOnly : try await Self.cost(sample.data, pixels: pixels, render: render, frames: info.frameCount)

        let fileFPS = 1000 * Double(info.frameCount) / Double(max(info.loopMillis, 1))
        print(String(
            format: "AnimatedArt %@ [%@ %dx%d, %d frames, %.1f fps], main thread busy %.0f ms a display frame: presented %d of %d frames in %.0f s "
                + "(%.1f fps), longest hold %d display frames (the file's %d); per frame decode %.1f ms (max %.1f), decode+render %.1f ms "
                + "(max %.1f) at %dx%d; player %.3f ms per display frame (max %.2f)",
            sample.name, hero ? "hero" : "cover", info.width, info.height, info.frameCount, fileFPS, busyMillis, presented, expected,
            Self.seconds, Double(presented) / Self.seconds, longest, ideal, decodeOnly.mean, decodeOnly.max, whole.mean, whole.max,
            size.width, size.height, mainThread.reduce(0, +) / Double(mainThread.count), mainThread.max() ?? 0
        ))
    }

    /// The mean and longest time of decoding (and [render]ing) the frames after the first, in order, as the player asks for
    /// them; at most 40.
    private static func cost(_ data: Data, pixels: Int, render: (@Sendable (CGImage) -> CGImage?)?, frames: Int) async throws -> (mean: Double, max: Double) {
        let decoder = try #require(AnimatedFrameDecoder(data: data, maxPixelSize: pixels, render: render))
        _ = await decoder.frame(0)
        let clock = ContinuousClock()
        var times: [Double] = []
        for index in 1..<min(frames, 41) {
            let start = clock.now
            _ = await decoder.frame(index)
            times.append(millis(clock.now - start))
        }
        return (times.reduce(0, +) / Double(max(times.count, 1)), times.max() ?? 0)
    }

    private nonisolated static func millis(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// An APNG of 60 frames at 30 a second, [width] × [height]: a gradient with noise over it (as heavy to inflate as
    /// painted artwork) and a light disc travelling across.
    private nonisolated static func generated(width: Int, height: Int) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 60, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var noise = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 1
        for i in noise.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            noise[i] = i % 4 == 3 ? 40 : UInt8(truncatingIfNeeded: seed >> 24) / 6
        }
        let grain = noise.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        for index in 0..<60 {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let phase = Double(index) / 60
            let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1),
                                                                     CGColor(red: 0.1, green: 0.2, blue: 0.6, alpha: 1)] as CFArray, locations: nil)!
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            context.draw(grain, in: CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 1, alpha: 0.4))
            let disc = Double(min(width, height)) / 2
            context.fillEllipse(in: CGRect(x: (Double(width) - disc) * phase, y: Double(height) / 4, width: disc, height: disc))
            CGImageDestinationAddImage(destination, context.makeImage()!,
                                       [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 1.0 / 30]] as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}
