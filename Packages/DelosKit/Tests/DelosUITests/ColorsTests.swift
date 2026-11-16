import Testing
@testable import DelosUI

/// Expected values from Python's colorsys.hls_to_rgb, an independent implementation of the same CSS formula.
@Suite struct ColorsTests {
    @Test(arguments: [
        (222.0, 38.0, 7.0, 0.043400, 0.059360, 0.096600),
        (40, 95, 62, 0.981000, 0.740333, 0.259000),
        (190, 85, 62, 0.297000, 0.835333, 0.943000),
        (335, 85, 68, 0.952000, 0.408000, 0.634667),
        (-30, 50, 50, 0.750000, 0.250000, 0.500000),
        (400, 120, -5, 0, 0, 0),
    ])
    func hslMatchesTheCSSFormula(h: Double, s: Double, l: Double, r: Double, g: Double, b: Double) {
        let c = hsl(h, s, l)
        #expect(abs(c.red - r) < 1e-5 && abs(c.green - g) < 1e-5 && abs(c.blue - b) < 1e-5, "\(h) \(s) \(l) → \(c)")
    }

    @Test func alphaIsClamped() {
        #expect(hsl(0, 0, 0, 1.4).alpha == 1)
        #expect(hsl(0, 0, 0, -1).alpha == 0)
    }

    @Test func darkDelosTokensFollowTheAndroidFormulas() {
        let c = DelosColors(palette: .delos, dark: true)
        #expect(c.bg == hsl(222, 38, 7))
        #expect(c.accent == hsl(40, 95, 62))
        #expect(c.accent2 == hsl(190, 85, 62))
        #expect(c.accent3 == hsl(335, 85, 68))
        // Text saturation is capped by the palette's background saturation (38): 30 stays 30
        #expect(c.text == hsl(222, 30, 96))
        #expect(c.onAccent3 == c.onAccent)
    }

    @Test func mutedPalettesKeepSurfacesAlmostNeutral() {
        // Graphite's background saturation is 7: surfaces drop to the floor of 2, text is capped at 7
        let c = DelosColors(palette: .graphite, dark: true)
        #expect(c.surface == hsl(220, 2, 14, 0.72))
        #expect(c.text == hsl(220, 7, 96))
        #expect(c.accent == hsl(205, 70, 70))
    }

    @Test func lightThemeShiftsTheMainHue() {
        let c = DelosColors(palette: .delos, dark: false)
        #expect(c.accent == hsl(34, 92, 52))
        #expect(c.onAccent3 == RGBA(red: 1, green: 1, blue: 1))
    }

    @Test func hueInterpolationTakesTheShortWay() {
        #expect(abs(lerpHue(350, 10, 0.5) - 0) < 1e-9)
        #expect(abs(lerpHue(10, 350, 0.25) - 5) < 1e-9)
    }
}
