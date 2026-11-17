import Foundation
import SwiftUI
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

/// Where the side menu sits and how it arrives (`SideMenuLayer` and `sideEnter` / `sideExit` of DELOS for Android).
@MainActor @Suite struct SideMenuStyleTests {
    private func stage(_ w: Double, _ h: Double, safe: EdgeInsets = EdgeInsets()) -> Stage {
        Stage(size: CGSize(width: w, height: h), safeArea: safe)
    }

    @Test func theEdgePanelIsDockedLeftAndFullHeightAt680StagePixels() {
        let sizes: [(Double, Double)] = [(1920, 1080), (2560, 1440), (1024, 768), (932, 430), (2732, 2048)]
        for size in sizes {
            let s = stage(size.0, size.1)
            let frame = SideMenuStyle(device: .phone, stage: s).frame(s)
            #expect(frame.minX == 0 && frame.minY == 0)
            #expect(frame.width == 680 && frame.height == s.height)
            #expect(abs(s.px(frame.width) - 680 * s.scale) < 1e-9)
        }
    }

    @Test func theEdgePanelReachesUnderTheSafeAreaAndItsContentKeepsClear() {
        let s = stage(2732, 2048, safe: EdgeInsets(top: 24, leading: 59, bottom: 20, trailing: 0))
        let style = SideMenuStyle(device: .mac, stage: s)
        let frame = style.frame(s)
        #expect(frame.minX == 0 && frame.minY == 0 && frame.height == s.height)
        #expect(frame.width == 680 + s.safe.leading)
        #expect(style.contentInsets(s).leading == 40 + s.safe.leading && style.contentInsets(s).top == 48 + s.safe.top)
    }

    @Test func theBoxFloatsWithTheSameGapOnThreeSides() {
        let safe = EdgeInsets(top: 24, leading: 20, bottom: 20, trailing: 20)
        let sizes: [(Double, Double)] = [(2752, 2064), (2064, 2752), (1920, 1080)]
        for size in sizes {
            let s = stage(size.0, size.1, safe: safe)
            let style = SideMenuStyle(device: .pad, stage: s)
            #expect(style.kind == .box)
            let frame = style.frame(s)
            #expect(frame.width == 680)
            #expect(abs(frame.minX - (s.safe.leading + SideMenuStyle.inset)) < 1e-9)
            #expect(abs(frame.minY - (s.safe.top + SideMenuStyle.inset)) < 1e-9)
            #expect(abs(s.height - frame.maxY - (s.safe.bottom + SideMenuStyle.inset)) < 1e-9)
        }
    }

    @Test func theBoxIsForTheIPadAndTheTVOnly() {
        let wide = stage(1920, 1080), phone = stage(932, 430), narrow = stage(320, 700)
        #expect(SideMenuStyle(device: .tv, stage: wide).kind == .box)
        #expect(SideMenuStyle(device: .pad, stage: wide).kind == .box)
        #expect(SideMenuStyle(device: .pad, stage: narrow).kind == .edge)
        #expect(SideMenuStyle(device: .phone, stage: phone).kind == .edge)
        #expect(SideMenuStyle(device: .phone, stage: wide).kind == .edge)
        #expect(SideMenuStyle(device: .mac, stage: wide).kind == .edge)
    }

    @Test func aTVStageKeepsTheBoxInsideItsTitleSafeArea() {
        let s = stage(1920, 1080, safe: Stage.tvTitleSafeArea)
        let frame = SideMenuStyle(device: .tv, stage: s).frame(s)
        #expect(frame.minX > s.safe.leading && frame.minY > s.safe.top && frame.maxY < s.height - s.safe.bottom)
    }

    @Test func thePanelSlidesInFromATenthOfItsWidthToTheLeft() {
        let s = stage(1920, 1080)
        #expect(SideMenu.slideShift(s) == -68)
        #expect(abs(SideMenu.slideShift(stage(2560, 1440)) - -68 * stage(2560, 1440).scale) < 1e-9)
        // `AnyTransition` is opaque: both motions must at least build
        _ = SideMenu.transition(reducedMotion: false, stage: s)
        _ = SideMenu.transition(reducedMotion: true, stage: s)

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
