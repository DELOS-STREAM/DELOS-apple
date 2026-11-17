import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// The system's color that Settings → Appearance → Material You colors follows (`systemAccentHue` of DELOS for Android,
/// which reads the wallpaper palette). On the Mac it is the accent color of System Settings → Appearance; the interface
/// recolors when it changes. iPhone, iPad and Apple TV have no system color an app can read, so the row is not offered
/// there. A gray (Graphite) accent has no hue: the colors then use the fallback, as Android does without a palette.
@MainActor
@Observable
final class SystemAccent {
    static let shared = SystemAccent()

    /// Whether this platform has a system color to follow.
    nonisolated static var supported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The hue of the system's color in degrees, nil without one.
    static var hue: Double? { shared.hue }

    private(set) var hue: Double?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        #if os(macOS)
        hue = Self.read()
        observer = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SystemAccent.shared.hue = SystemAccent.read() }
        }
        #endif
    }

    #if os(macOS)
    private static func read() -> Double? {
        guard let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation < 0.1 ? nil : Double(hue) * 360
    }
    #endif
}
