import Foundation

/// What the statistics overlay of a stream shows (`checkbox_enable_perf_overlay` and `checkbox_enable_perf_overlay_lite` of
/// DELOS for Android, which keeps the two as separate switches): nothing, the full panel in a corner, or the compact
/// line at the top center. The stream menu's Overlay tile goes round them in Android's order (`toggleHUD`), and the
/// profile keeps the last one for its next streams.
public enum StatisticsOverlay: String, CaseIterable, Codable, Sendable {
    case off
    case full
    case compact

    /// The overlay after the Overlay tile is activated: off → full → compact → off.
    public var next: StatisticsOverlay {
        switch self {
        case .off: .full
        case .full: .compact
        case .compact: .off
        }
    }

    public var isShown: Bool { self != .off }
}
