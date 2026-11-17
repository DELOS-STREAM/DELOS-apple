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
