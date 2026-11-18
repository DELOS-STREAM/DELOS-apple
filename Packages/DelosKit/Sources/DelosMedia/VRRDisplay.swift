import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Whether a stream runs on a variable refresh rate display (`VrrMode` and `DisplayVrr` of DELOS for Android,
/// binding/video/VrrMode.java:19-27): the statistics panel marks its frame rate with VRR then.
public enum VRRDisplay {
    /// The `list_vrr` setting with what the display reports: On forces it, Off disables it, Auto (and an unknown value)
    /// follows the display.
    public static func resolve(setting: String, reported: Bool) -> Bool {
        switch setting {
        case "on": true
        case "off": false
        default: reported
        }
    }

    /// The main display varies its refresh rate: a ProMotion screen (iPhone and iPad above 60 Hz), a Mac display with
    /// adaptive sync (its shortest and longest refresh intervals differ). Apple TV's HDMI output keeps one rate.
    @MainActor public static var reported: Bool {
        #if os(iOS)
        return UIScreen.main.maximumFramesPerSecond > 60
        #elseif os(macOS)
        guard let screen = NSScreen.main else { return false }
        return screen.minimumRefreshInterval < screen.maximumRefreshInterval
        #else
        return false
        #endif
    }
}
