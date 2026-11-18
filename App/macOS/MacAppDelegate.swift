#if os(macOS)
import AppKit
import DelosUI

/// What only the Mac app needs: quitting leaves a running stream first, and keys the interface does not use make no
/// error sound.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The game keyboard (GameController) reads the keys itself; AppKit would beep for each one nobody handles.
        // Keys with Command, Control or Option (menu shortcuts, Full Keyboard Access, VoiceOver commands), keys typed
        // into a text field and keys for a sheet or panel are left alone.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.passes(modifiers: event.modifierFlags) ? event : nil
        }
        // A second screen gets the companion screen, and the Main screen setting decides where the window goes
        CompanionDisplays.shared.start()
    }

    /// Whether a key goes on to AppKit: a key with Command, Control or Option belongs to the menu bar or to the
    /// accessibility features, a key typed into a text field is the field's, and a sheet or panel (an open or save
    /// dialog, an alert) takes its own keys. Monitors run on the main thread.
    private nonisolated static func passes(modifiers: NSEvent.ModifierFlags) -> Bool {
        if !modifiers.isDisjoint(with: [.command, .control, .option]) { return true }
        return MainActor.assumeIsolated {
            guard let window = NSApp.keyWindow else { return false }
            return window.firstResponder is NSText || window.isSheet || window is NSPanel
        }
    }

    /// Closing the window ends the app: there is one window, and a stream cannot go on without it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Command-Q, the menu's Quit and closing the window: the stream is disconnected first (the game keeps running on
    /// the PC), within a few seconds, and the app quits when that is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard StreamShutdown.shared.hasStream else { return .terminateNow }
        Task { @MainActor in
            await StreamShutdown.shared.leaveAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
