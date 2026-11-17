import DelosInput
import SwiftUI

extension View {
    /// Put on the *content* of a scroll view that only the focus scrolls (every one of the interface): on an iPad the
    /// scroll view also scrolls on the arrow, Page and Space keys of a hardware keyboard by itself, on top of the
    /// focus (`UIScrollView.allowsKeyboardScrolling`), so this switches that off. No effect on the other platforms: the
    /// Mac app takes the keys in `MacAppDelegate`, and on tvOS the system focus engine is the only scroller.
    func focusDrivenScroll() -> some View {
        #if os(iOS)
        background(KeyboardScrollOff())
        #else
        self
        #endif
    }

    /// The keys that scroll and move the system focus (``MenuKeys``) go to ``MenuInput`` alone, which is reading the
    /// keyboard for the interface: nothing else scrolls or moves a focus on them. [typing]: a text field is typed in
    /// and gets its arrows. iPad and iPhone only: the Mac app takes them in `MacAppDelegate`, tvOS has its focus engine.
    func ownsMenuKeys(typing: Bool) -> some View {
        #if os(iOS)
        background(MenuKeyOwner(typing: typing))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct KeyboardScrollOff: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardScrollOffView {
        let view = KeyboardScrollOffView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: KeyboardScrollOffView, context: Context) {}
}

private struct MenuKeyOwner: UIViewRepresentable {
    let typing: Bool

    func makeUIView(context: Context) -> MenuKeyOwnerView {
        let view = MenuKeyOwnerView()
        view.isUserInteractionEnabled = false
        view.setTyping(typing)
        return view
    }

    func updateUIView(_ view: MenuKeyOwnerView, context: Context) {
        view.setTyping(typing)
    }
}
#endif
