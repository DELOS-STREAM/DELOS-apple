import Foundation
import GameController
import OSLog
#if os(iOS)
import UIKit
#endif

/// Debug builds only: what happens between the stream menu's Keyboard tile and the on-screen keyboard, for a device where
/// the tile raises no keyboard (issue #15, R2-9). Every line goes to the unified log as a notice of the subsystem
/// `io.github.meitoncz.delos`, category `KeyboardTile`:
///
///     log stream --level info --predicate 'subsystem == "io.github.meitoncz.delos" && category == "KeyboardTile"'
///
/// on a Mac that sees the device (Console.app with the device selected shows the same lines). Release builds compile it
/// to nothing.
public enum KeyboardTileLog {
    #if DEBUG
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "KeyboardTile")
    #endif

    public static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        let text = message()
        logger.notice("\(text, privacy: .public)")
        #endif
    }

    #if os(iOS)
    /// The class of the app's first responder, or "none".
    @MainActor public static var firstResponder: String {
        UIResponder.current.map { "\(type(of: $0))" } ?? "none"
    }

    /// Whether a hardware keyboard is connected as GameController sees it (iPadOS shows no on-screen keyboard while one is).
    @MainActor public static var hardwareKeyboard: Bool { GCKeyboard.coalesced != nil }

    /// Starts logging the system's keyboard notifications and the hardware keyboard's connections, once per run.
    @MainActor public static func observeSystem() {
        #if DEBUG
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let keyboard: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "will show"), (UIResponder.keyboardDidShowNotification, "did show"),
            (UIResponder.keyboardWillHideNotification, "will hide"), (UIResponder.keyboardDidHideNotification, "did hide"),
            (UIResponder.keyboardWillChangeFrameNotification, "will change frame"),
        ]
        for (name, label) in keyboard {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                let local = (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool).map { "\($0)" } ?? "?"
                MainActor.assumeIsolated {
                    note("system keyboard \(label): end frame \(frame), local \(local), first responder \(firstResponder)")
                }
            })
        }
        let devices: [(Notification.Name, String)] = [
            (.GCKeyboardDidConnect, "hardware keyboard connected"), (.GCKeyboardDidDisconnect, "hardware keyboard disconnected"),
        ]
        for (name, label) in devices {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { note("\(label) (GCKeyboard.coalesced now \(hardwareKeyboard ? "set" : "nil"))") }
            })
        }
        #endif
    }

    #if DEBUG
    @MainActor private static var observers: [NSObjectProtocol] = []
    #endif
    #endif
}
