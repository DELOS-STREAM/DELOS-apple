#if os(macOS)
import AppKit
import DelosData
import DelosHost
import SwiftUI
@testable import DelosUI

/// Lays a real screen out in a window that is never shown and reads what ends up in its ``FocusModel``: the items the
/// screen registered and their frames, exactly as the app produces them (``FocusItem`` reports each item's frame in the
/// window). The window is the stage's: its size in points and the safe area the device would give it.
@MainActor
final class ScreenHost {
    let size: CGSize
    let stage: Stage
    private let window: NSWindow
    private let hosting: NSHostingView<AnyView>

    init<Content: View>(size: CGSize, safeArea: EdgeInsets = EdgeInsets(), textScale: Double = 1, @ViewBuilder content: () -> Content) {
        self.size = size
        stage = Stage(size: size, safeArea: safeArea, textScale: textScale)
        let root = AnyView(content().environment(\.stage, stage).frame(width: size.width, height: size.height))
        hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
    }

    /// Runs the main loop (and the layout) until [condition] holds, for at most 400 turns of it: the screens are laid out by
    /// SwiftUI between the turns. Returns whether it held.
    @discardableResult
    func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            hosting.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        hosting.layoutSubtreeIfNeeded()
        return condition()
    }

    /// Runs the main loop until [model] has registered [count] or more items and the number has not changed for a few
    /// turns of the loop (the screen's layout has settled). The wait is for the layout, not for a time: it ends as soon as the
    /// items are stable, and after 200 turns of the loop whatever there is.
    func settle(_ model: FocusModel, atLeast count: Int = 1) async -> [AnyHashable: CGRect] {
        var last = -1
        var stable = 0
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
            let frames = model.registeredFrames
            if frames.count == last, frames.count >= count { stable += 1 } else { stable = 0 }
            last = frames.count
            if stable >= 5 { break }
        }
        return model.registeredFrames
    }
}
#endif
