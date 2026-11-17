import AVFoundation
import CoreMedia
import QuartzCore
import Synchronization

/// Shows decoded video. Two renderers exist: `AVSampleBufferDisplayLayer`, where the system decodes, paces and handles
/// HDR (decision L4, the default), and ``MetalRenderer``, which decodes with VideoToolbox and presents from a display
/// link (``RendererChoice``). Called on the core's video thread.
public protocol VideoRenderer: Sendable {
    /// What the statistics overlay names as the decoder.
    var name: String { get }
    /// Shows a frame; returns false when the renderer failed and needs a key frame to start over.
    func enqueue(_ sample: CMSampleBuffer) -> Bool
    /// The stream carries (or no longer carries) 10-bit HDR video: the display layer asks for extended dynamic range.
    /// Called from the core's video thread before the first frame.
    func setHDR(_ active: Bool)
    /// Drops the frames waiting to be shown (before a new stream or after an error).
    func flush()
    /// The renderer's cumulative frame counters; nil when it has none yet.
    func presentationCounters() async -> VideoPresentationCounters?

    /// The layer the video view hosts.
    @MainActor var hostLayer: CALayer { get }
    /// The view's size changed: `bounds` in points, `scale` pixels per point.
    @MainActor func resize(to bounds: CGRect, scale: CGFloat)
    /// The view is in a window on a display that refreshes up to `maxFramesPerSecond` times a second.
    @MainActor func attached(maxFramesPerSecond: Int)
    /// The view left its window.
    @MainActor func detached()
    /// The launch scene's exit begins: the picture arrives (``LaunchArrival``) over `duration` seconds, timed by the
    /// renderer's own clock from now. The display layer draws no effects and shows the picture as it is, as when the
    /// arrival cannot run on the GPU.
    func startArrival(duration: Double)
    /// The launch scene went away before its exit ended: the picture is shown plainly from the next refresh on.
    func cancelArrival()
}

extension VideoRenderer {
    public func setHDR(_ active: Bool) {}
    @MainActor public func attached(maxFramesPerSecond: Int) {}
    @MainActor public func detached() {}
    public func startArrival(duration: Double) {}
    public func cancelArrival() {}
}

/// Renders through an `AVSampleBufferDisplayLayer`; a view hosts ``layer`` (on the main actor), while frames go to its
/// `sampleBufferRenderer`, which accepts them from any thread. With pacing (``FramePacer``) each frame gets the time it is
/// shown at on a timebase that follows the host clock; without it, frames are shown as soon as they are decoded.
public final class DisplayLayerRenderer: VideoRenderer {
    public nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer
    private let pacer: Mutex<FramePacer>

    public var name: String { "AVSampleBufferDisplayLayer" }

    @MainActor public var hostLayer: CALayer { layer }

    @MainActor
    public init(pacing: FramePacing = .latency, fps: Int = 60) {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        renderer = layer.sampleBufferRenderer
        pacer = Mutex(FramePacer(pacing: pacing, fps: fps))
        if pacing != .latency {
            var timebase: CMTimebase?
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
            if let timebase {
                CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
                CMTimebaseSetRate(timebase, rate: 1)
                layer.controlTimebase = timebase
            }
        }
    }

    @MainActor public func resize(to bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        CATransaction.commit()
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if renderer.status == .failed {
            renderer.flush()
            pacer.withLock { $0.reset() }
            return false
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if let time = pacer.withLock({ $0.presentationTime(arrival: now) }) {
            Self.schedule(sample, at: time)
        }
        renderer.enqueue(sample)
        return true
    }

    /// Takes the "display immediately" mark off and gives the sample its time on the host clock.
    static func schedule(_ sample: CMSampleBuffer, at seconds: Double) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionaryRemoveValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque())
        }
        CMSampleBufferSetOutputPresentationTimeStamp(sample, newValue: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }

    /// The system shows a layer's HDR pictures above standard white only when the layer asks for extended range; the
    /// pictures themselves carry the transfer function and the metadata (``VideoSamples``). tvOS has no such switch:
    /// its output is HDR when the TV is in an HDR mode.
    public func setHDR(_ active: Bool) {
        #if !os(tvOS)
        DispatchQueue.main.async { [self] in layer.wantsExtendedDynamicRangeContent = active }
        #endif
    }

    public func flush() {
        renderer.flush()
        pacer.withLock { $0.reset() }
    }

    /// The system's own counters: frames it handled (shown and dropped), the dropped ones, and how late the shown ones
    /// were against their time. It does not report decoding or the queue.
    public func presentationCounters() async -> VideoPresentationCounters? {
        await withCheckedContinuation { continuation in
            renderer.loadVideoPerformanceMetrics { metrics in
                continuation.resume(returning: metrics.map {
                    VideoPresentationCounters(
                        totalFrames: $0.totalNumberOfFrames, droppedFrames: $0.numberOfDroppedFrames,
                        accumulatedDelaySeconds: $0.totalAccumulatedFrameDelay)
                })
            }
        }
    }
}
