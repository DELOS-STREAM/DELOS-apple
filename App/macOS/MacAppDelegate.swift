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
        // Keys with Command (the menu bar's shortcuts) and keys typed into a text field are left alone.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.passes(commandHeld: event.modifierFlags.contains(.command)) ? event : nil
        }
    }

    /// Whether a key goes on to AppKit: a key with Command is a shortcut of the menu bar, and a key typed into a text
    /// field is the field's. Monitors run on the main thread.
    private nonisolated static func passes(commandHeld: Bool) -> Bool {
        if commandHeld { return true }
        return MainActor.assumeIsolated { NSApp.keyWindow?.firstResponder is NSText }
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
