import Foundation

extension GameMetadata {
    /// The HDR chip of the info row (`hdrBadgeKind` of DELOS for Android): the PC gaming wiki's verdict, "unverified" only
    /// when a lookup finished without a failure of that provider, nothing before that. A later refresh failure does not
    /// invalidate evidence that was confirmed.
    public var hdrBadge: NativeHDR? {
        if hdr.support == .unknown, updatedAt <= 0 || pcgwFailedAt != 0 { return nil }
        return hdr.support
    }

    /// HowLongToBeat's headline time when it is a positive count of seconds.
    public var completionSeconds: Int64? {
        guard let seconds = completion?.seconds, seconds > 0 else { return nil }
        return seconds
    }
}

/// How long a game takes, rounded like HowLongToBeat's website: minutes below an hour, half hours up to 100 hours, whole
/// hours beyond ("45 Mins", "3½ Hours"; `completionText` of DELOS for Android).
public enum CompletionLength: Equatable, Sendable {
    case minutes(Int)
    /// [halves]: the length in half hours.
    case hours(halves: Int)

    public init(seconds: Int64) {
        if seconds < 3600 {
            self = .minutes(Int((seconds + 30) / 60))
        } else {
            self = .hours(halves: Int(seconds >= 100 * 3600 ? ((seconds + 1800) / 3600) * 2 : (seconds + 900) / 1800))
        }
    }

    /// The number the plural is chosen by: the minutes, or the hours rounded up.
    public var quantity: Int {
        switch self {
        case .minutes(let count): count
        case .hours(let halves): (halves + 1) / 2
        }
    }

    /// The hours as written beside the unit: whole or with a half ("12", "12½"); nil for minutes.
    public var hoursText: String? {
        guard case .hours(let halves) = self else { return nil }
        return "\(halves / 2)\(halves % 2 == 1 ? "\u{00BD}" : "")"
    }
}
