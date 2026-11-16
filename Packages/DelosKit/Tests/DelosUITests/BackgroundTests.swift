import CoreGraphics
import Foundation
import Metal
import DelosData
import Testing
@testable import DelosUI

/// Expected values from the Kotlin formulas of `lights()` and `BgParams` (shell/ui/Backdrop.kt in DELOS for Android),
/// the colors from Python's colorsys.hls_to_rgb.
@Suite struct BackgroundTests {
    private func params(dark: Bool) -> BackgroundParams {
        BackgroundParams(colors: DelosColors(palette: .delos, dark: dark), canvas: BackgroundParams.canvas, t: 0)
    }

    private func expect(_ c: RGBA, _ r: Double, _ g: Double, _ b: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(abs(c.red - r) < 1e-5 && abs(c.green - g) < 1e-5 && abs(c.blue - b) < 1e-5, "\(c)", sourceLocation: sourceLocation)
    }

    @Test func darkLightsAreSaturated85AtLightness56And62() {
        let (c1, c2, c3) = params(dark: true).lights
        expect(c1, 0.934000, 0.684667, 0.186000) // hsl(40, 85, 56)
        expect(c2, 0.186000, 0.809333, 0.934000) // hsl(190, 85, 56)
        expect(c3, 0.943000, 0.297000, 0.566167) // hsl(335, 85, 62)
    }

    @Test func lightLightsAreSaturated80AtLightness58And62() {
        let (c1, c2, c3) = params(dark: false).lights
        expect(c1, 0.916000, 0.692000, 0.244000) // hsl(40, 80, 58)
        expect(c2, 0.244000, 0.804000, 0.916000) // hsl(190, 80, 58)
        expect(c3, 0.924000, 0.316000, 0.569333) // hsl(335, 80, 62)
    }

    @Test func lightsScaleEachSaturation() {
        var p = params(dark: true)
        p.sat1 = 0.5
        p.sat2 = 0.25
        p.sat3 = 0
        let (c1, c2, c3) = p.lights
        expect(c1, 0.747000, 0.622333, 0.373000) // hsl(40, 42.5, 56)
        expect(c2, 0.466500, 0.622333, 0.653500) // hsl(190, 21.25, 56)
        expect(c3, 0.62, 0.62, 0.62) // hsl(335, 0, 62)
    }

    @Test func saturationFollowsTheHue() {
        var p = params(dark: true)
        p.sat1 = 0.1
        p.sat2 = 0.2
        p.sat3 = 0.3
        #expect(p.s(40) == 0.1)
        #expect(p.s(190) == 0.2)
        #expect(p.s(335) == 0.3)
        #expect(p.s(222) == 1)
        // A tint apart from the palette's secondary hue (a game's) takes the secondary saturation too
        p.tint = 100
        #expect(p.s(100) == 0.2)
        #expect(p.s(190) == 0.2)
    }

    @Test func theFirstMatchingHueWins() {
        // Kotlin's when: a hue that is both the main and the secondary one is the main one
        var p = params(dark: true)
        p.acc2 = p.acc
        p.tint = p.acc
        p.sat1 = 0.4
        p.sat2 = 0.8
        #expect(p.s(p.acc) == 0.4)
    }

    @Test func glowIsStrongerInTheDarkTheme() {
        #expect(params(dark: true).glow == 0.62)
        #expect(params(dark: false).glow == 0.5)
    }

    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), 2.0, CGSize(width: 960, height: 540)),
        (CGSize(width: 960, height: 600), 1.0, CGSize(width: 960, height: 600)),
        (CGSize(width: 1080, height: 540), 1.0, CGSize(width: 1080, height: 540)),
        (CGSize(width: 1290, height: 2796), 1.34375, CGSize(width: 960, height: 2080.744186)),
    ])
    func theCanvasGrowsAlongTheLongerAxis(size: CGSize, unit: Double, canvas: CGSize) {
        let result = BackgroundParams.canvas(for: size)
        #expect(abs(result.unit - unit) < 1e-6)
        #expect(abs(result.canvas.width - canvas.width) < 1e-3 && abs(result.canvas.height - canvas.height) < 1e-3)
    }

    @Test func everyKindHasItsStyle() {
        let shaders = BackgroundKind.allCases.compactMap { kind -> String? in
            if case let .shader(name) = BackgroundStyle(kind) { name } else { nil }
        }
        #expect(shaders == ["delosNebula", "delosPlasma", "delosLava", "delosCaustics", "delosBokeh", "delosOrbit"])
        #expect([BackgroundKind.aurora, .tide, .silk].allSatisfy { BackgroundStyle($0) == .canvas })
        #expect(BackgroundStyle(.contour) == .contour)
        #expect(BackgroundStyle(.still) == .still)
    }

    @Test func silkSamplesEvery16PixelsPastBothEdges() {
        // -80, -64, ..., 1040 on the 960-pixel canvas
        #expect(CanvasBackgrounds.silkPoints(960) == 71)
    }

    @Test func everyShaderIsInTheLibrary() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try device.makeDefaultLibrary(bundle: Bundle.module)
        let names = Set(library.functionNames)
        for kind in BackgroundKind.allCases {
            if case let .shader(name) = BackgroundStyle(kind) { #expect(names.contains(name), "\(name)") }
        }
        #expect(names.contains("delosContour"))
    }
}
