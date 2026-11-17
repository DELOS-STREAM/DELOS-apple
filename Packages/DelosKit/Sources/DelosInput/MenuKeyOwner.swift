import Foundation
import GameController
#if os(iOS)
import UIKit
#endif

/// The keys with which the system moves or scrolls on its own, and that DELOS must therefore take from it.
///
/// ``MenuInput`` reads a hardware keyboard through GameController, which only observes: the same key press also goes to
/// UIKit, where an iPad scrolls the scroll view under the focus (`UIScrollView.allowsKeyboardScrolling`, animated and
/// repeated by the system) and moves its own focus. With both at work the library row crawled under the focus and the
/// focus ran off the screen (owner's iPad with a Magic Keyboard). DELOS moves the focus and the scroll views itself, so
/// these keys belong to ``MenuInput`` alone: ``MenuKeyOwnerView`` takes them at the top of the responder chain, and the
/// scroll views switch their own keyboard scrolling off (``KeyboardScrollOffView``). The Mac app swallows every plain
/// key already (`MacAppDelegate`), and tvOS wants the system's focus engine.
public enum MenuKeys {
    /// The four arrows, Space, Page Up and Down, Home and End: the keys that scroll (and, for the arrows, move the
    /// focus of) every UIKit scroll view.
    public enum Key: CaseIterable, Sendable {
        case upArrow, downArrow, leftArrow, rightArrow, space, pageUp, pageDown, home, end

        public var keyCode: GCKeyCode {
            switch self {
            case .upArrow: .upArrow
            case .downArrow: .downArrow
            case .leftArrow: .leftArrow
            case .rightArrow: .rightArrow
            case .space: .spacebar
            case .pageUp: .pageUp
            case .pageDown: .pageDown
            case .home: .home
            case .end: .end
            }
        }
    }

    /// Whether the system must not see this key: every key that ``MenuInput`` turns into a move or a scroll of ours.
    public static func isOwned(_ code: GCKeyCode) -> Bool {
        Key.allCases.contains { $0.keyCode == code }
    }
}

#if os(iOS)
extension MenuKeys.Key {
    /// The `UIKeyCommand` input string of the key.
    var input: String {
        switch self {
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .leftArrow: UIKeyCommand.inputLeftArrow
        case .rightArrow: UIKeyCommand.inputRightArrow
        case .space: " "
        case .pageUp: UIKeyCommand.inputPageUp
        case .pageDown: UIKeyCommand.inputPageDown
        case .home: UIKeyCommand.inputHome
        case .end: UIKeyCommand.inputEnd
        }
    }
}

/// A view that holds the first responder, so that the keys of ``MenuKeys`` end at it and nowhere else: its key
/// commands take priority over the system's behavior (`wantsPriorityOverSystemBehavior`: the focus system and the
/// keyboard scrolling of scroll views) and do nothing. The keys themselves are read by ``MenuInput``.
///
/// It lets go of the first responder while a text field is typed in (``setTyping(_:)``), so the field gets its arrows
/// back, and takes it again when the typing ends.
@MainActor
public final class MenuKeyOwnerView: UIView {
    private var typing = false
    private var observer: NSObjectProtocol?
    private lazy var commands: [UIKeyCommand] = MenuKeys.Key.allCases.map { key in
        let command = UIKeyCommand(input: key.input, modifierFlags: [], action: #selector(swallow))
        command.wantsPriorityOverSystemBehavior = true
        // Left stays left in a right-to-left language: the key is not a shortcut with a direction of its own
        command.allowsAutomaticMirroring = false
        return command
    }

    public override var canBecomeFirstResponder: Bool { true }

    public override var keyCommands: [UIKeyCommand]? { typing ? nil : commands }

    /// The keys are taken and dropped here: ``MenuInput`` has them already.
    @objc private func swallow() {}

    public func setTyping(_ typing: Bool) {
        guard typing != self.typing else { return }
        self.typing = typing
        if typing { resignFirstResponder() } else { claim() }
    }

    /// Takes the first responder, unless a text field is typed in.
    private func claim() {
        guard !typing, window != nil, !isFirstResponder else { return }
        becomeFirstResponder()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        guard window != nil else { return }
        claim()
        // Another window (a share sheet, a system alert) took the key and gave it back: so does the first responder
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.claim() }
        }
    }
}

/// Switches the keyboard scrolling off in the scroll view that holds this view (`UIScrollView.allowsKeyboardScrolling`:
/// on from iPadOS 17, it scrolls and animates by itself on every arrow, Page and Space key, next to DELOS's own scroll
/// that follows the focus).
@MainActor
public final class KeyboardScrollOffView: UIView {
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        Self.apply(from: self)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        Self.apply(from: self)
    }

    /// Every scroll view above [view] (its content may sit in a scroll view inside another one).
    static func apply(from view: UIView) {
        var next = view.superview
        while let current = next {
            if let scroll = current as? UIScrollView, scroll.allowsKeyboardScrolling { scroll.allowsKeyboardScrolling = false }
            next = current.superview
        }
    }
}
#endif
