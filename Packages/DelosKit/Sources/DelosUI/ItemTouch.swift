import CoreGraphics
import DelosInput

/// What a tap or a click on a ``FocusItem`` does (docs/ARCHITECTURE.md, "Focus" and "Pointer"), apart from SwiftUI and UIKit
/// so the rules are tested.
enum ItemTouch: Equatable {
    /// The item only takes the focus (the move cue): a finger's first tap on an item that a first tap only focuses.
    case focusOnly
    /// A's action, once the press has landed.
    case activate
    /// The item's own tap (``FocusItem``'s `tap`), told whether the item had the focus.
    case own(wasFocused: Bool)

    /// How long a finger holds an item for its context menu, in seconds: far longer than a tap, so a tap never opens it.
    static let menuHold = 0.5

    /// A tap or a click on an item. [focused]: the item had the focus before it; [kind]: the kind of input when the tap lands
    /// (``ControllerGlyphs/kind``): the pointer's click counts as on the focused item, as its hover moved the focus there, so
    /// a click is never only the first tap that focuses; [ownTap]: the item has its own tap; [firstTapFocuses]:
    /// ``FocusItem/focusingOnFirstTap()``.
    static func of(focused: Bool, kind: InputKind, ownTap: Bool, firstTapFocuses: Bool) -> ItemTouch {
        let wasFocused = focused || kind == .pointer
        if ownTap { return .own(wasFocused: wasFocused) }
        return firstTapFocuses && !wasFocused ? .focusOnly : .activate
    }

    /// Whether the window's tap recognizer of the secondary button (iPad, `InputKindProbe`) may take a touch: only the
    /// pointer's ([indirect]: a right click, the trackpad's two-finger click). UIKit evaluates `buttonMaskRequired` on
    /// indirect input devices only (UITapGestureRecognizer.h), so a finger's tap passed the secondary mask: the recognizer
    /// noted the pointer before the item's tap read the kind (a cover's first tap started the game) and opened the context
    /// menu of the item under the finger (a PC's circle on the start screen).
    static func takesSecondaryClick(indirect: Bool) -> Bool { indirect }
}

/// The cover gesture decides its axis before recognition, not in an already-active drag callback.
enum CoverDragDirection: Equatable {
    case undecided, horizontalScroll, verticalSwipe

    static func of(translation: CGSize, minimumDistance: CGFloat) -> Self {
        let horizontal = abs(translation.width), vertical = abs(translation.height)
        guard max(horizontal, vertical) >= minimumDistance else { return .undecided }
        // Do not steal an almost-diagonal drag from the row while the player's intent is still unclear.
        if horizontal > vertical * 1.2 { return .horizontalScroll }
        if vertical > horizontal * 1.2 { return .verticalSwipe }
        return .undecided
    }
}
