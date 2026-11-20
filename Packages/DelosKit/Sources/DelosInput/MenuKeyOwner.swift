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
    /// focus of) every UIKit scroll view; and Tab, which moves the iPad's keyboard focus between groups and is the side
    /// menu's key here.
    public enum Key: CaseIterable, Sendable {
        case upArrow, downArrow, leftArrow, rightArrow, space, pageUp, pageDown, home, end, tab

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
            case .tab: .tab
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
        case .tab: "\t"
        }
    }
}

/// A view that holds the first responder, so that the keys of ``MenuKeys`` end at it and nowhere else: its key
/// commands take priority over the system's behavior (`wantsPriorityOverSystemBehavior`: the focus system and the
/// keyboard scrolling of scroll views) and do nothing. The keys themselves are read by ``MenuInput``.
///
/// The game controllers are the interface's alone too: a `GCEventInteraction` on the window has UIKit deliver their
/// events only through GameController, to ``MenuInput``. Without one the system may also turn a controller's input into
/// UIKit events for whatever view holds the UIKit focus or the first responder (`GCEventViewController`: controllers
/// "control the general UIKit user interface and for many views that is the default behavior"), and a press that UIKit
/// takes never reaches ``MenuInput``.
///
/// It lets go of the first responder while a text field is typed in (``setTyping(_:)``), so the field gets its arrows
/// back, and takes it again when the typing ends.
@MainActor
public final class MenuKeyOwnerView: UIView {
    /// Posted when a text input that had the first responder let go of it (the stream's on-screen keyboard went away): the
    /// keys belong to the interface again, whatever the key window did meanwhile.
    public static let reclaim = Notification.Name("io.github.meitoncz.delos.menuKeyOwner.reclaim")

    private var typing = false
    private var observer: NSObjectProtocol?
    private var reclaimObserver: NSObjectProtocol?
    private let controllerEvents: GCEventInteraction = {
        let interaction = GCEventInteraction()
        interaction.handledEventTypes = .gamepad
        return interaction
    }()
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

    /// Takes the first responder, unless a text field is typed in or another text input holds it: the on-screen keyboard
    /// of a stream (a key window event must not take it away again: the keyboard went down the moment it came up).
    private func claim() {
        guard !typing, window != nil, !isFirstResponder else { return }
        if let holder = UIResponder.current, holder is UIKeyInput {
            KeyboardTileLog.note("menu key owner: leaves the first responder to \(type(of: holder))")
            return
        }
        #if DEBUG
        let previous = UIResponder.current.map { "\(type(of: $0))" } ?? "none"
        let took = becomeFirstResponder()
        KeyboardTileLog.note("menu key owner: claims the first responder from \(previous): \(took)")
        #else
        becomeFirstResponder()
        #endif
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        reclaimObserver.map(NotificationCenter.default.removeObserver)
        reclaimObserver = nil
        controllerEvents.view?.removeInteraction(controllerEvents)
        guard let window else { return }
        window.addInteraction(controllerEvents)
        claim()
        reclaimObserver = NotificationCenter.default.addObserver(forName: Self.reclaim, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                KeyboardTileLog.note("menu key owner: reclaim posted")
                self?.claim()
            }
        }
        // Another window (a share sheet, a system alert) took the key and gave it back: so does the first responder
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                KeyboardTileLog.note("menu key owner: its window became key")
                self?.claim()
            }
        }
    }
}

extension UIResponder {
    private static weak var found: UIResponder?

    /// The first responder of the app, if any (a message sent to nobody goes to it first).
    @MainActor static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(reportAsFirstResponder), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func reportAsFirstResponder() {
        Self.found = self
    }
}

/// Switches the keyboard scrolling off in the scroll view that holds this view (`UIScrollView.allowsKeyboardScrolling`:
/// on from iPadOS 17, it scrolls and animates by itself on every arrow, Page and Space key, next to DELOS's own scroll
/// that follows the focus). The pointer's scroll stays the player's: the scroll view takes the trackpad's two fingers
/// and a wheel with their momentum (`allowedScrollTypesMask` `.all`: continuous and discrete).
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
            if let scroll = current as? UIScrollView {
                if scroll.allowsKeyboardScrolling { scroll.allowsKeyboardScrolling = false }
                if scroll.panGestureRecognizer.allowedScrollTypesMask != .all { scroll.panGestureRecognizer.allowedScrollTypesMask = .all }
            }
            next = current.superview
        }
    }
}
#endif
