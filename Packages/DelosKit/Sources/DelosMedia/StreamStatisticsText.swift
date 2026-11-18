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
        // Android `frameQueueText`: only when the GPU had too much work in flight
        if let gpuBusySkippedPerSecond, gpuBusySkippedPerSecond > 0 {
            parts.append("\(Self.number(gpuBusySkippedPerSecond)) GPU busy /s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 1 % low: the frame rate of the slowest 1 % of the recent frames (Android `StreamStats.kt:258`).
    public var onePercentLowText: String? {
        onePercentLowFPS.map { "\(Self.number($0)) FPS" }
    }

    /// Render latency: decoded picture to the display's presented time, average / 95th percentile / maximum over the last
    /// second (Android `renderLatencyText`). It leaves out the controller, the network, the host and the decoding.
    public var renderLatencyText: String? {
        renderLatency.map {
            String(format: "%.1f / %.1f / %.1f ms avg/p95/max", locale: Self.posix, $0.averageMilliseconds, $0.p95Milliseconds,
                   $0.maximumMilliseconds)
        }
    }

    /// Upscaling: the upscaler's GPU time per frame (Android `stream_stats_upscaling` row, shown above zero).
    public var upscalingText: String? {
        guard let upscalingMilliseconds, upscalingMilliseconds > 0 else { return nil }
        return "\(Self.number(upscalingMilliseconds, places: 2)) ms"
    }

    /// Sharpen pass: its average and worst time per frame, then the preparation before it (Android `sharpenPassText`).
    public var sharpenPassText: String? {
        guard let sharpen else { return nil }
        var text = String(format: "%.2f ms avg / %.2f max", locale: Self.posix, sharpen.passAverageMilliseconds, sharpen.passMaximumMilliseconds)
        if let prepare = sharpen.prepareAverageMilliseconds {
            text += " · \(sharpen.prepareName) " + String(format: "%.2f ms", locale: Self.posix, prepare)
        }
        if !sharpen.gpuTimed { text += " (CPU submit)" }
        return text
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private static func number(_ value: Double, places: Int = 1) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), places, value)
    }
}
