import Foundation

/// The upscaler's sizes: the presentation size is the picture's rectangle on the view (even), and the internal size the one
/// the upscaler reconstructs at, larger than the presentation when the stream already has the view's size (supersampling:
/// 4/3 at level 1, 2 at level 2) and that size fits the limits. MetalFX writes the stream enlarged by one factor on both
/// axes up to it (``MetalUpscaler/scalerOutput(input:target:scales:)``).
struct UpscalerDimensions: Equatable {
    static let maxInternalWidth = 3840
    static let maxInternalHeight = 3840
    static let maxInternalPixels = 3840 * 2160
    static let nativeTolerance = 2

    var presentationWidth: Int
    var presentationHeight: Int
    var internalWidth: Int
    var internalHeight: Int

    var isSupersampling: Bool { internalWidth > presentationWidth && internalHeight > presentationHeight }

    static func plan(
        source: (width: Int, height: Int), presentation: (width: Int, height: Int), maxTextureSize: Int, supersamplingLevel: Int
    ) -> UpscalerDimensions {
        let outputWidth = even(max(2, presentation.width)), outputHeight = even(max(2, presentation.height))
        let native = isNativeInput(source: source, presentation: presentation)
        let numerator = supersamplingLevel >= 2 ? 2 : 4, denominator = supersamplingLevel >= 2 ? 1 : 3
        let width = even(outputWidth * numerator / denominator), height = even(outputHeight * numerator / denominator)
        let fits = width <= maxTextureSize && height <= maxTextureSize && width <= maxInternalWidth
            && height <= maxInternalHeight && width * height <= maxInternalPixels
        return native && fits
            ? UpscalerDimensions(presentationWidth: outputWidth, presentationHeight: outputHeight, internalWidth: width, internalHeight: height)
            : UpscalerDimensions(presentationWidth: outputWidth, presentationHeight: outputHeight, internalWidth: outputWidth, internalHeight: outputHeight)
    }

    static func isNativeInput(source: (width: Int, height: Int), presentation: (width: Int, height: Int)) -> Bool {
        abs(source.width - presentation.width) <= nativeTolerance && abs(source.height - presentation.height) <= nativeTolerance
    }

    private static func even(_ value: Int) -> Int { value & ~1 }
}

/// What the upscaler's output stage saw in one statistics window of about a second (Android `FrameQueueStats.java`, the
/// fields the load decisions read).
struct UpscalerWindow: Equatable {
    /// Frames drawn through the upscaler.
    var draws = 0
    /// Frames that waited for a busy GPU and were replaced by a newer one without being drawn.
    var busySkipped = 0
    /// GPU time per frame in milliseconds, -1 when no frame's time is known yet.
    var gpuAverageMilliseconds: Double = -1
    var gpuMaximumMilliseconds: Double = -1
    /// Frames the decoder delivered.
    var arrived = 0
    var seconds = 0.0

    var arrivedPerSecond: Double { seconds > 0 ? Double(arrived) / seconds : 0 }
    var busySkippedPerSecond: Double { seconds > 0 ? Double(busySkipped) / seconds : 0 }
}

/// Collects one ``UpscalerWindow`` after another on the renderer's clock.
struct UpscalerWindowMeter {
    static let windowSeconds = 1.0
    private var start: Double?
    private var current = UpscalerWindow()
    private var gpuSum = 0.0
    private var gpuCount = 0
    private var gpuMaximum = 0.0

    mutating func arrived(at now: Double) { open(now); current.arrived += 1 }
    mutating func drew(at now: Double) -> UpscalerWindow? { open(now); current.draws += 1; return close(at: now) }
    mutating func busySkipped(at now: Double) -> UpscalerWindow? { open(now); current.busySkipped += 1; return close(at: now) }

    mutating func gpuWork(seconds: Double) {
        let milliseconds = seconds * 1000
        gpuSum += milliseconds
        gpuCount += 1
        gpuMaximum = max(gpuMaximum, milliseconds)
    }

    mutating func reset() { self = UpscalerWindowMeter() }

    private mutating func open(_ now: Double) { if start == nil { start = now } }

    private mutating func close(at now: Double) -> UpscalerWindow? {
        guard let start, now - start >= Self.windowSeconds else { return nil }
        var window = current
        window.seconds = now - start
        window.gpuAverageMilliseconds = gpuCount > 0 ? gpuSum / Double(gpuCount) : -1
        window.gpuMaximumMilliseconds = gpuCount > 0 ? gpuMaximum : -1
        self = UpscalerWindowMeter()
        self.start = now
        return window
    }
}

/// Decides from the windows whether the upscaler is too heavy for the stream's frame rate (Android `OverloadDetector.java`):
/// a window is overloaded when the GPU time per frame is above 90 % of the frame period or more than 20 % of the frames that
/// were drawn or waited for the GPU were dropped because it was busy. Two overloaded windows in a row report it once; windows
/// with very few frames neither count nor break a streak.
struct OverloadDetector {
    static let gpuShare = 0.9
    static let busyShare = 0.2
    static let windowsInARow = 2
    static let minimumFrames = 20

    private var streak = 0

    mutating func reset() { streak = 0 }

    /// True when the overload has just been established.
    mutating func onWindow(_ window: UpscalerWindow) -> Bool {
        guard window.arrived >= Self.minimumFrames, window.arrivedPerSecond > 0 else { return false }
        if Self.isOverloaded(window) {
            streak += 1
            if streak >= Self.windowsInARow {
                streak = 0
                return true
            }
        } else {
            streak = 0
        }
        return false
    }

    static func isOverloaded(_ window: UpscalerWindow) -> Bool {
        let period = 1000 / window.arrivedPerSecond
        let gpuBound = window.gpuAverageMilliseconds > gpuShare * period
        let offered = window.draws + window.busySkipped
        let dropping = offered > 0 && Double(window.busySkipped) / Double(offered) > busyShare
        return gpuBound || dropping
    }
}

/// Bounds the upscaler's frames of GPU work in flight (Android `GpuInFlight.java`): with two frames still running the next
/// draw waits; a frame that never finishes does not freeze the picture, after 250 ms of continuous waiting the count is
/// cleared.
struct GPUInFlight {
    static let maximum = 2
    static let stuckSeconds = 0.25

    private(set) var count = 0
    private var busySince: Double?

    mutating func submitted() { count += 1 }
    mutating func finished() { count = max(0, count - 1) }

    mutating func shouldSkip(now: Double) -> Bool {
        guard count >= Self.maximum else {
            busySince = nil
            return false
        }
        let since = busySince ?? now
        busySince = since
        if now - since > Self.stuckSeconds {
            count = 0
            busySince = nil
            return false
        }
        return true
    }
}

/// An exponential moving average whose first sample is taken as it is.
func smoothedMilliseconds(_ previous: Double, _ sample: Double) -> Double {
    previous <= 0 ? sample : previous * 0.8 + sample * 0.2
}
