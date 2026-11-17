import SwiftUI

/// When a drag that began at the left edge opens the side menu: it starts within ``band`` of the edge, travels right at least
/// ``travel`` and more sideways than up or down (a vertical drag near the edge stays the screen's scroll). Stage pixels.
enum EdgeSwipeRule {
    static let band = 28.0
    static let travel = 80.0

    static func opens(start: CGPoint, translation: CGSize) -> Bool {
        start.x <= band && translation.width >= travel && translation.width > abs(translation.height) * 1.5
    }
}

#if os(iOS)
/// A thin strip along the left edge that turns a swipe in from the edge into the side menu (touch has no left menu button).
/// It covers only the edge band, so taps and scrolls everywhere else reach the screen.
struct SideMenuEdgeSwipe: View {
    let onOpen: () -> Void
    @Environment(\.stage) private var stage

    var body: some View {
        Color.clear
            .frame(width: stage.px(EdgeSwipeRule.band))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: stage.px(12), coordinateSpace: .local)
                    .onEnded { drag in
                        let start = CGPoint(x: drag.startLocation.x / stage.scale, y: drag.startLocation.y / stage.scale)
                        let moved = CGSize(width: drag.translation.width / stage.scale, height: drag.translation.height / stage.scale)
                        if EdgeSwipeRule.opens(start: start, translation: moved) { onOpen() }
                    })
            .frame(maxWidth: .infinity, alignment: .leading)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}
#endif
