import DelosCore
import DelosInput
import GameController

/// The toast of ``HomeButtonHint``: it tells that the controller's Home button stays with the system, names the other
/// ways to the stream menu, and its action opens the system's page where the per-app Home action is left to DELOS. One
/// for the app's whole interface (the shell and a stream share the toast stage), started with it.
@MainActor
final class HomeButtonNotice {
    /// How long the notice stays: it tells more than a message and has an action to reach.
    static let durationMs: Double = 12_000
    /// The lines the notice may take: its text names the alternatives.
    static let maxLines = 4

    private let toasts: Toasts
    /// Whether the current profile's swipe up from the bottom edge opens the stream menu.
    private let swipeOn: @MainActor () -> Bool
    private var hint: HomeButtonHint?
    /// The toast of the notice while it may still be on the stage.
    private var toastID: Int?

    init(toasts: Toasts, swipeOn: @escaping @MainActor () -> Bool) {
        self.toasts = toasts
        self.swipeOn = swipeOn
    }

    /// Starts watching the controllers; nothing where the system has no per-app Home action (``HomeButtonHint/systemReader()``).
    func start() {
        guard hint == nil, let reader = HomeButtonHint.systemReader() else { return }
        let hint = HomeButtonHint(reader: reader) { [weak self] event in self?.handle(event) }
        self.hint = hint
        hint.start()
    }

    private func handle(_ event: HomeButtonHint.Event) {
        switch event {
        case .show:
            let keyboard = Self.mac || GCKeyboard.coalesced != nil
            let way = StreamMenuWay.choose(touch: Self.touch, swipeOn: swipeOn(), keyboard: keyboard)
            toastID = toasts.show(
                Self.text(way), icon: Symbols.gamepadButtons,
                action: ToastAction(label: L("home_button_hint_action")) { [weak self] in self?.hint?.openSettings() },
                durationMs: Self.durationMs, kind: .info, maxLines: Self.maxLines)
        case .hide:
            if let toastID { toasts.hide(toastID) }
            toastID = nil
        }
    }

    /// The notice's text for [way].
    static func text(_ way: StreamMenuWay) -> String {
        switch way {
        case .swipe: L("home_button_hint_swipe")
        case .keys: L("home_button_hint_keys")
        case .buttons: L("home_button_hint_buttons")
        }
    }

    #if os(iOS)
    private static let touch = true
    #else
    private static let touch = false
    #endif
    #if os(macOS)
    private static let mac = true
    #else
    private static let mac = false
    #endif
}
