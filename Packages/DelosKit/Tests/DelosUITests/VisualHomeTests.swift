import Foundation
import Testing
@testable import DelosUI

/// The numbers of the layers, the top navigation's pill and the glide ring that DELOS for Android has (`Scrim`,
/// `SelectionPillMotion`, `GlideRing`).
@MainActor @Suite struct VisualHomeTests {
    @Test func aDialogBlursTheScreenButAContextMenuOnlyDimsIt() {
        let layers = Layers()
        #expect(!layers.blursScreen)
        layers.openDialog(DialogSpec(title: "t", note: "n", fields: [], confirm: "ok", onConfirm: { _ in true }))
        #expect(layers.blursScreen)
        layers.close()
        layers.openContextMenu(ContextMenu(title: "m", items: [MenuItem(icon: "x", label: "a")]), anchor: nil)
        #expect(!layers.blursScreen)
    }

    @Test func theEdgeInTheDirectionOfTravelIsTheStifferSpring() {
        // Different animations: 190 * 1.5 and 190 * 0.75, damping ratio 0.8
        #expect(NavPill.edge(leading: true) != NavPill.edge(leading: false))
    }

    @Test func theGlideRingFollowsTheFocusAndFadesOutAfterItLeaves() async throws {
        let ring = GlideRing()
        let a = CGRect(x: 0, y: 0, width: 100, height: 100), b = CGRect(x: 200, y: 0, width: 100, height: 100)
        ring.focus("a", a)
        #expect(ring.shown == a)
        // The first appearance is a jump (nothing to glide from); the next focus moves the ring
        ring.focus("b", b)
        #expect(ring.shown == b)
        ring.blur("a")
        // "a" no longer holds the ring: its blur changes nothing
        #expect(ring.alpha == 1)
        ring.blur("b")
        for _ in 0..<300 where ring.alpha != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(ring.alpha == 0)
    }

    @Test func aFocusThatArrivesBeforeTheFirstLayoutShowsTheRingWhenTheBoundsAreKnown() {
        let ring = GlideRing()
        ring.focus("a", .zero)
        #expect(ring.shown == nil)
        ring.moved("a", CGRect(x: 10, y: 10, width: 50, height: 50))
        #expect(ring.shown == CGRect(x: 10, y: 10, width: 50, height: 50))
    }
}

/// The look of a focused circle against the Android screenshot of the Devices screen (AYN Odin, 1920 x 1080).
@MainActor @Suite struct CircleLookTests {
    @Test func theRingSitsAroundTheGrownCircleAndIsNotScaledWithIt() {
        // 220 px circle, 1.16 growth, 5 px gap and 5 px ring: 255.2 + 20, the 275 px of the screenshot
        #expect(abs(RingGeometry.outerDiameter(layout: 220, focusScale: 1.16, ring: 5, gap: 5) - 275.2) < 0.001)
    }

    @Test func theGlowKeepsAThirdOfItsAlphaHalfwayThroughTheBlur() {
        // `FocusGlow(26, 70, -16)` of a 220 px circle: from 94 px (full) to 164 px (nothing)
        let (inner, outer) = (94.0, 164.0)
        #expect(GlowDisc.share(at: 90, inner: inner, outer: outer) == 1)
        #expect(abs(GlowDisc.share(at: outer * (94.0 / 164.0 + 1) / 2, inner: inner, outer: outer) - 0.32) < 1e-9)
        #expect(GlowDisc.share(at: outer, inner: inner, outer: outer) == 0)
        // 140 px from the center of the grown circle is 120.7 px in the circle's own units: a glow alpha of .45 * .48
        let share = GlowDisc.share(at: 140 / 1.16, inner: inner, outer: outer)
        #expect(abs(share * 0.45 - 0.217) < 0.003)
    }
}
