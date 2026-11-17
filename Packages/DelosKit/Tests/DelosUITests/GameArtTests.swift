import CoreGraphics
import DelosData
import DelosHost
import Foundation
import Testing
@testable import DelosUI

/// The three main colors of a cover on simple made-up images (GameColorsTest of DELOS for Android).
@Suite struct GameColorsTests {
    private func image(_ parts: (UInt32, Int)...) -> [UInt32] { parts.flatMap { Array(repeating: $0.0, count: $0.1) } }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    @Test func redOnNearBlackIsRedNotTheDarkBackground() throws {
        // Carrion: mostly a near-black background with a hint of red, some vivid red
        let colors = try #require(GameColors.dominant(image((0xFF10_0007, 6000), (0xFFFC_1A0C, 600), (0xFFB6_0420, 400))))
        #expect(hueDistance(colors.hues[0], 3) < 12, "main hue \(colors.hues[0])")
        #expect(colors.hues.count == 3 && colors.saturations.count == 3)
    }

    @Test func aGreyImageHasNoColors() {
        #expect(GameColors.dominant(image((0xFFF0_F0F0, 5000), (0xFF20_2020, 3000), (0xFF80_8080, 2000))) == nil)
        // Transparent pixels do not count either
        #expect(GameColors.dominant(image((0x10FF_0000, 5000))) == nil)
        #expect(GameColors.dominant([]) == nil)
    }

    @Test func twoColorsComeOutApartAndTheThirdIsAShade() throws {
        let colors = try #require(GameColors.dominant(image((0xFFFF_FFFF, 5000), (0xFF20_60E0, 3000), (0xFFF0_C020, 2000))))
        #expect(hueDistance(colors.hues[0], colors.hues[1]) > 60)
        #expect(hueDistance(colors.hues[2], colors.hues[0]) <= 15)
    }

    @Test func aSmallVividLogoCountsBesideALargeMutedColor() throws {
        // Returnal: large muted teal, a small vivid yellow logo
        let colors = try #require(GameColors.dominant(image((0xFF0A_1416, 5000), (0xFF2A_5A60, 3000), (0xFF3C_7078, 1500), (0xFFE8_E010, 120))))
        #expect(colors.hues.contains { hueDistance($0, 58) < 15 }, "hues \(colors.hues)")
    }

    @Test func mutedColorsStayMuted() throws {
        let colors = try #require(GameColors.dominant(image((0xFFF0_F0F0, 5000), (0xFF3E_5364, 3000))))
        #expect(colors.saturations[0] < 0.4, "saturation \(colors.saturations[0])")
    }

    @Test func hctMatchesMaterialColorUtilities() {
        // Hct.fromInt of the material-color-utilities tests
        let red = HCT(red: 255, green: 0, blue: 0)
        #expect(abs(red.hue - 27.41) < 0.1 && abs(red.chroma - 113.36) < 0.1 && abs(red.tone - 53.24) < 0.1)
        let blue = HCT(red: 0, green: 0, blue: 255)
        #expect(abs(blue.hue - 282.79) < 0.1 && abs(blue.chroma - 87.23) < 0.1 && abs(blue.tone - 32.30) < 0.1)
        let white = HCT(red: 255, green: 255, blue: 255)
        #expect(white.chroma < 3 && abs(white.tone - 100) < 0.01)
    }

    @Test func hslMatchesAndroidsColorUtils() {
        let (h, s, l) = GameColors.hsl((255, 128, 0))
        #expect(abs(h - 30.1) < 0.1 && abs(s - 1) < 0.001 && abs(l - 0.5) < 0.01)
        #expect(GameColors.hsl((10, 10, 10)).1 == 0)
    }
}

@Suite struct HeroGeometryTests {
    private let area = HeroArea.standard

    @Test func aWideHeroFillsTheWidthAtTheTopAndFadesIntoTheExtension() {
        for (w, h) in [(1920, 620), (3840, 1240)] {
            let layout = HeroGeometry.layout(area, width: w, height: h)
            #expect(layout.extended && layout.left == 0 && layout.top == 0 && layout.width == 2100)
            #expect(abs(layout.height - 678.125) < 0.01 && layout.fade == 160)
        }
        #expect(abs(HeroGeometry.layout(area, width: 920, height: 430).height - 981.52) < 0.01)
        #expect(HeroGeometry.layout(area, width: 1920, height: 1080).extended)
    }

    @Test func anImageAsTallAsTheAreaIsCroppedToFill() {
        let exact = HeroGeometry.layout(area, width: 1000, height: 600)
        #expect(!exact.extended && exact.width == 2100 && exact.height == 1260 && exact.fade == 0)
        let portrait = HeroGeometry.layout(area, width: 600, height: 900)
        #expect(!portrait.extended && portrait.width == 2100 && portrait.height == 3150 && portrait.top == -945)
        let unknown = HeroGeometry.layout(area, width: 0, height: 0)
        #expect(!unknown.extended && unknown.width == 2100 && unknown.height == 1260)
        // A very flat image is still scaled up to half of the (16:9) area (its sides cropped); the fade stays 160
        let flat = HeroGeometry.layout(area, width: 21000, height: 1000)
        #expect(flat.extended && abs(flat.height - 630) < 1e-9 && flat.fade == 160 && flat.left < 0)
    }

    @Test func aTallerStageScalesTheBandUpToTwoThirdsOfTheArea() {
        // iPad Pro 13": a 1920 × 1440 stage, an area of 2100 × 1680; the width-fitted band would be 678 px (40 %), now 1120 (two thirds)
        let tall = HeroArea.of(stageWidth: 1920, stageHeight: 1440)
        let layout = HeroGeometry.layout(tall, width: 1920, height: 620)
        #expect(layout.extended && abs(layout.height - 1120) < 1e-9)
        // Scaled by the height, so wider than the area and centred: the sides are cropped equally
        #expect(layout.width > tall.width && abs(layout.left + (layout.width - tall.width) / 2) < 1e-9)
        // Between 16:9 and 4:3 the share grows evenly: a stage 1260 high (area 2100 × 1470) is halfway
        #expect(abs(HeroGeometry.minBandShare(HeroArea.of(stageWidth: 1920, stageHeight: 1260)) - (0.5 + 0.5 * (2.0 / 3.0 - 0.5))) < 1e-9)
        #expect(abs(HeroGeometry.minBandShare(area) - 0.5) < 1e-9 && abs(HeroGeometry.minBandShare(tall) - 2.0 / 3.0) < 1e-9)
        // On 16:9 nothing changes: the band (678 of 1260) is already above half; the two thirds apply to a stage of 4:3 or taller
        #expect(HeroGeometry.layout(area, width: 1920, height: 620).height < 1260 * 0.55)
        #expect(HeroGeometry.layout(area, width: 1920, height: 620).left == 0)
    }

    @Test func theAreaAddsAMarginAroundAnyStage() {
        #expect(area == HeroArea(width: 2100, height: 1260))
        #expect(HeroArea.of(stageWidth: 2520, stageHeight: 1080) == HeroArea(width: 2756.25, height: 1260))
        #expect(HeroArea.of(stageWidth: 1920, stageHeight: 1440) == HeroArea(width: 2100, height: 1680))
        #expect(HeroRender.height(area) == 252)
        #expect(HeroRender.height(.of(stageWidth: 2520, stageHeight: 1080)) == 192)
        #expect(HeroRender.height(.of(stageWidth: 1920, stageHeight: 1440)) == 336)
    }

    @Test func theFadeRunsFromOpaqueToNothingWithoutSteps() {
        #expect(HeroGeometry.fadeOpacity(0) == 1 && HeroGeometry.fadeOpacity(1) == 0)
        #expect(HeroGeometry.fadeOpacity(0.5) == 0.5 && HeroGeometry.fadeOpacity(-1) == 1 && HeroGeometry.fadeOpacity(2) == 0)
        let samples = stride(from: 0.0, through: 1, by: 0.05).map(HeroGeometry.fadeOpacity)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func theOrbitIsCircularContinuousAndFlatWhenReduced() {
        for step in 0...360 {
            let turn = Double(step) / 360
            let pitch = HeroMotion.pitch(turn, reduced: false), yaw = HeroMotion.yaw(turn, reduced: false)
            #expect(abs((pitch * pitch + yaw * yaw).squareRoot() - 15) < 1e-9)
            #expect(HeroMotion.pitch(turn, reduced: true) == 0 && HeroMotion.yaw(turn, reduced: true) == 0)
        }
        #expect(HeroMotion.turn(at: 0) == 0 && HeroMotion.turn(at: 75) == 0)
        #expect(abs(HeroMotion.turn(at: 87.5) - 0.5) < 1e-9)
        #expect(abs(HeroMotion.turn(at: -12.5) - 0.5) < 1e-9)
    }

    /// Every corner of the stage stays inside the tilted, overscanned area at every phase (HeroMotionTest's projection).
    @Test func theOverscanCoversEveryStageShape() {
        for (w, h) in [(1920.0, 1080.0), (1920, 1200), (1920, 1440), (2400, 1080), (2520, 1080), (2167, 1000), (1600, 1000)] {
            let area = HeroArea.of(stageWidth: w, stageHeight: h)
            let camera = max(area.width, area.height) * HeroMotion.cameraDistanceFactor
            let corners = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)]
            for step in 0...360 {
                let pitch = HeroMotion.pitch(Double(step) / 360, reduced: false) * .pi / 180
                let yaw = HeroMotion.yaw(Double(step) / 360, reduced: false) * .pi / 180
                let image = corners.map { project(x: $0.0 * area.width / 2, y: $0.1 * area.height / 2, pitch: pitch, yaw: yaw, camera: camera) }
                for corner in corners {
                    let (x, y) = (corner.0 * w / 2, corner.1 * h / 2)
                    for edge in image.indices {
                        let a = image[edge], b = image[(edge + 1) % image.count]
                        #expect((b.0 - a.0) * (y - a.1) - (b.1 - a.1) * (x - a.0) > 0, "\(w) x \(h) at \(step)")
                    }
                }
            }
        }
    }

    private func project(x: Double, y: Double, pitch: Double, yaw: Double, camera: Double) -> (Double, Double) {
        let px = x * HeroMotion.overscan, py = y * HeroMotion.overscan
        let rotatedX = px * cos(yaw), rotatedZ = -px * sin(yaw)
        let rotatedY = py * cos(pitch) - rotatedZ * sin(pitch)
        let depth = py * sin(pitch) + rotatedZ * cos(pitch)
        let k = camera / (camera - depth)
        return (rotatedX * k, rotatedY * k)
    }
}

@Suite struct HeroRenderTests {
    /// A [width] × [height] image: the left half [left], the right half [right].
    private func image(width: Int, height: Int, left: (UInt8, UInt8, UInt8), right: (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bitmap = try #require(Bitmap(width: width, height: height))
        for y in 0..<height {
            for x in 0..<width {
                let c = x < width / 2 ? left : right
                let i = (y * width + x) * 4
                bitmap.pixels[i] = c.0
                bitmap.pixels[i + 1] = c.1
                bitmap.pixels[i + 2] = c.2
                bitmap.pixels[i + 3] = 255
            }
        }
        return try #require(bitmap.image())
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var bitmap = try #require(Bitmap(width: image.width, height: image.height))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bitmap.pixels[(y * image.width + x) * 4 + 3]
    }

    @Test func theBackgroundIsSmallFadedDiagonallyAndGivesTheColors() throws {
        let source = try image(width: 1920, height: 620, left: (220, 30, 30), right: (30, 60, 220))
        let result = try #require(HeroRender.render(source, blur: 5, area: .standard))
        #expect(result.image.width == 420 && result.image.height == 252)
        // Opaque in the top-right corner, gone in the bottom-left one
        #expect(try alpha(result.image, x: 419, y: 0) == 255)
        #expect(try alpha(result.image, x: 0, y: 251) == 0)
        let colors = try #require(result.colors)
        let hues = colors.hues.prefix(2).map { $0 < 20 || $0 > 340 ? "red" : $0 > 200 && $0 < 260 ? "blue" : "\($0)" }
        #expect(Set(hues) == ["red", "blue"], "hues \(colors.hues)")
    }

    @Test func anUnblurredBackgroundKeepsMorePixels() throws {
        let source = try image(width: 600, height: 900, left: (40, 200, 90), right: (40, 200, 90))
        let result = try #require(HeroRender.render(source, blur: 0, area: .of(stageWidth: 1920, stageHeight: 1440)))
        #expect(result.image.width == HeroRender.sharpWidth && result.image.height == 1280)
        #expect(result.colors.map { abs($0.hues[0] - 137) < 10 } == true)
    }

    @Test func theSaturationAndBlurFollowAndroid() throws {
        var bitmap = try #require(Bitmap(width: 1, height: 1))
        bitmap.pixels = [200, 100, 50, 255]
        bitmap.saturate(1.15)
        // ColorMatrix.setSaturation(1.15) on (200, 100, 50)
        #expect(bitmap.pixels == [212, 97, 40, 255])
        var stripe = try #require(Bitmap(width: 9, height: 1))
        stripe.pixels = (0..<9).flatMap { $0 == 4 ? [255, 255, 255, 255] : [0, 0, 0, 255] as [UInt8] }
        stripe.boxBlur(radius: 1, passes: 1)
        #expect(stripe.pixels[4 * 4] == 85 && stripe.pixels[3 * 4] == 85 && stripe.pixels[0] == 0)
    }
}

@Suite struct BackdropTintsTests {
    private let target = GameColors(hues: [10, 200, 300], saturations: [0.5, 0.8, 1.1])

    @Test func theFirstGameIsTakenAtOnceAndLaterOnesFollowSmoothly() throws {
        var tints = BackdropTints()
        tints.advance(dt: 0, target: nil, baseTarget: 1)
        #expect(tints.game == nil && tints.baseAlpha == 1)
        tints.advance(dt: 1.0 / 60, target: target, baseTarget: 0.12)
        let game = try #require(tints.game)
        #expect(game.hues == [10, 200, 300])
        #expect(abs(game.saturations[0] - (1 + (0.5 - 1) * 0.04)) < 1e-9)
        #expect(abs((tints.baseAlpha ?? 0) - (1 + (0.12 - 1) * 0.05)) < 1e-9)
        // The next game's hue moves the short way round
        let next = GameColors(hues: [350, 200, 300], saturations: [0.5, 0.8, 1.1])
        tints.advance(dt: 1.0 / 60, target: next, baseTarget: 0.12)
        #expect(abs((tints.game?.hues[0] ?? 0) - (10 - 20 * 0.04)) < 1e-9)
        for _ in 0..<600 { tints.advance(dt: 1.0 / 60, target: next, baseTarget: 0.12) }
        #expect(abs((tints.game?.hues[0] ?? 0) - 350) < 0.01 && abs((tints.baseAlpha ?? 0) - 0.12) < 0.001)
        // Without a target the colors stay where they are
        let held = tints.game
        tints.advance(dt: 1, target: nil, baseTarget: 1)
        #expect(tints.game == held)
    }

    @Test func theSmoothingIsTheFrameLerpOverTime() {
        #expect(abs(BackdropTints.smoothing(0.04, 1.0 / 60) - 0.04) < 1e-12)
        #expect(abs(BackdropTints.smoothing(0.04, 2.0 / 60) - (1 - 0.96 * 0.96)) < 1e-12)
        #expect(BackdropTints.smoothing(0.04, 0) == 0)
    }

    @Test func gameColorsReplaceThePalettesOnEveryBackground() {
        let colors = DelosColors(palette: .delos, dark: true)
        let game = BackdropTints.Game(hues: [10, 200, 300], saturations: [0.5, 0.8, 1.1])
        let p = BackgroundParams(colors: colors, canvas: BackgroundParams.canvas, t: 0, game: game)
        #expect(p.acc == 10 && p.tint == 200 && p.acc2 == 200 && p.acc3 == 300)
        #expect(p.sat1 == 0.5 && p.sat2 == 0.8 && p.sat3 == 1.1 && p.base == colors.baseHue)
        #expect(p.lights.c1 == hsl(10, 85 * 0.5, 56))
    }
}

@MainActor @Suite struct HomeTests {
    @Test func theTitleBoxInfoRowAndCoversStandWhereAndroidPutsThem() {
        let layout = HomeLayout(scale: 1)
        #expect(layout.coverTop == 520 && layout.titleBox == 200 && layout.infoHeight == 44)
        // The info row 44 px above the focused cover's ring (22.925 px above the cover), the title centred above it
        #expect(abs(layout.titleGap - 52.5375) < 1e-9 && abs(layout.titleTop - 156.5375) < 1e-9)
        let large = HomeLayout(scale: 1.3, safeTop: 20)
        #expect(abs(large.coverTop - (430 - 0.3 * 92 + 90)) < 1e-9 && abs(large.infoHeight - 57.2) < 1e-9)
        #expect(large.titleBox < 200 && large.titleTop > 20 + 104 * 1.3)
    }

    @Test func theRowKeepsItsDistanceFromTheBottomOnATallerStage() {
        // iPad Pro 13" in landscape is a 1920 × 1440 stage: the row moves down by the extra 360 px, so the covers end
        // 110 px above the bottom there too, as on 16:9
        let wide = HomeLayout(scale: 1), tall = HomeLayout(scale: 1, stageHeight: 1440)
        #expect(tall.coverTop - wide.coverTop == 360)
        #expect(1440 - (tall.coverTop + HomeLayout.coverHeight) == 1080 - (wide.coverTop + HomeLayout.coverHeight))
        // The title box moves with it and keeps its size
        #expect(tall.titleBox == 200 && tall.titleTop > wide.titleTop)
    }

    @Test func thePlaceholderHuesFollowJavasStringHash() {
        #expect(GameArt.javaHash("hello") == 99_162_322)
        #expect(GameArt.javaHash("") == 0)
        // Overflows like Java's int arithmetic
        #expect(GameArt.javaHash("Counter-Strike 2: Global Offensive") == Int32(truncatingIfNeeded: "Counter-Strike 2: Global Offensive".utf16.reduce(0) { ($0 &* 31 &+ Int64($1)) & 0xFFFF_FFFF }))
        let art = GameArt(hostID: "PC", app: .init(id: 7, title: "hello"))
        #expect(art.id == "PC/7" && art.hue == Double(99_162_322 % 360) && art.hue2 == (art.hue + 35).truncatingRemainder(dividingBy: 360))
    }

    @Test func theStreamingTimeReadsAsOnAndroid() {
        let english = Locale(identifier: "en_US")
        var texts = PlaytimeTexts(.none, locale: english)
        #expect(texts.eyebrowTime == "STREAMING TIME" && texts.eyebrowLast == "LAST STREAMED")
        #expect(texts.full == .init(number: "0", unit: "hours") && texts.short == .init(number: "0", unit: "h") && texts.last == "Never")
        texts = PlaytimeTexts(Playtime(totalSeconds: 3600), locale: english)
        #expect(texts.full == .init(number: "1", unit: "hour"))
        texts = PlaytimeTexts(Playtime(totalSeconds: 20.4 * 3600), locale: english)
        #expect(texts.full == .init(number: "20.4", unit: "hours") && texts.short.unit == "h")
        texts = PlaytimeTexts(Playtime(totalSeconds: 60), locale: english)
        #expect(texts.full == .init(number: "1", unit: "minute") && texts.short == .init(number: "1", unit: "min"))
        texts = PlaytimeTexts(Playtime(totalSeconds: 45 * 60), locale: english)
        #expect(texts.full.unit == "minutes")
        let now = Date()
        #expect(PlaytimeTexts(Playtime(totalSeconds: 1, lastStreamed: now), now: now).last == "Today")
        #expect(PlaytimeTexts.last(.days(3), locale: english) == "3 days ago")
        #expect(PlaytimeTexts.last(.weeks(1), locale: english) == "1 week ago")
        #expect(PlaytimeTexts.parts(.tenthsOfHours(204), short: false, locale: Locale(identifier: "cs_CZ")).number == "20,4")
    }

    @Test func theCoversRowsNeedAKey() {
        var form = CoversForm(enabled: false, automatic: true, pcName: nil)
        var rows = form.rows(.covers)
        #expect(rows.map(\.id) == ["covers_sgdb_key", "covers_sgdb_auto", "covers_sgdb_missing", "covers_sgdb_refresh", "covers_sgdb_choose"])
        #expect(rows.allSatisfy { $0.section == "SteamGridDB" })
        #expect(rows[0].value == .action(label: "Not set") && rows[0].enabled)
        #expect(rows.dropFirst().dropLast().allSatisfy { !$0.enabled })
        #expect(rows[2].help == "Fetches artwork for the apps of the current PC that have none.")
        form = CoversForm(enabled: true, automatic: false, pcName: "Meiton-PC")
        rows = form.rows(.covers)
        #expect(rows[0].value == .action(label: "Added") && rows[1].value == .toggle(false))
        #expect(rows.allSatisfy { $0.enabled })
        #expect(rows[2].help == "Fetches artwork for the apps of Meiton-PC that have none.")
        #expect(form.rows(.appearance).isEmpty)
        #expect(SteamGridDBError.apiHTTP(502).text == "SteamGridDB answered 502")
        #expect(SteamGridDBError.downloadHTTP(404).text == "HTTP 404")
    }
}

@Suite struct MemoryCacheTests {
    private func image(_ side: Int) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    @Test func theLimitIsInBytesNotInCount() {
        // 10×10 images cost 400 bytes each: three fit in 1200
        var cache = MemoryCache<CGImage>(costLimit: 1200) { $0.width * $0.height * 4 }
        for index in 0..<5 { cache["k\(index)"] = image(10) }
        #expect(cache.totalCost == 1200)
        #expect(cache["k0"] == nil && cache["k1"] == nil)
        #expect(cache["k4"] != nil)
    }

    @Test func aBigImageDropsSeveralSmallOnesAndATooBigOneIsNotKept() {
        var cache = MemoryCache<CGImage>(costLimit: 1200) { $0.width * $0.height * 4 }
        for index in 0..<3 { cache["k\(index)"] = image(10) }
        cache["big"] = image(17)   // 1156 bytes
        #expect(cache["big"] != nil && cache["k0"] == nil && cache["k2"] == nil)
        cache["huge"] = image(18)   // 1296 bytes
        #expect(cache["huge"] == nil)
        #expect(cache.totalCost <= 1200)
    }

    @Test func replacingAKeyReplacesItsCost() {
        var cache = MemoryCache<CGImage>(costLimit: 1200) { $0.width * $0.height * 4 }
        cache["a"] = image(10)
        cache["a"] = image(5)
        #expect(cache.totalCost == 100)
    }
}
