import Foundation

/// The text of the statistics panel's rows that report what the renderer did with the frames: the Decoding row and the
/// Frame queue row of Android's panel. The units are written as Android writes them (`frameQueueText` of
/// `StreamStats.kt`); a row is nil when the renderer reports nothing for it (the display layer reports no decoding time
/// and no queue, only the frames it dropped).
extension StreamStatistics {
    /// Decoding: VideoToolbox's time per picture and how many pictures it decoded per second.
    public var decodingText: String? {
        guard let decodeMilliseconds else { return nil }
        var text = "\(Self.number(decodeMilliseconds, places: 2)) ms"
        if let decodedFPS { text += " · \(Self.number(decodedFPS)) FPS" }
        return text
    }

    /// Frame queue: the frames waiting at a refresh (average and most), the frames skipped (decoded but never shown), the
    /// refreshes that had no new frame and the frames that were drawn too late for their refresh.
    public var frameQueueText: String? {
        var parts: [String] = []
        if let queueWaitingAverage, let queueWaitingPeak {
            parts.append("\(Self.number(queueWaitingAverage)) avg / \(queueWaitingPeak) max waiting")
        }
        if let droppedFramesPerSecond {
            parts.append("\(Self.number(droppedFramesPerSecond)) skipped /s")
        }
        if let repeatedRefreshesPerSecond {
            parts.append("\(Self.number(repeatedRefreshesPerSecond)) repeated /s")
        }
        if let lateRefreshesPerSecond {
            parts.append("\(Self.number(lateRefreshesPerSecond)) late /s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func number(_ value: Double, places: Int = 1) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}
