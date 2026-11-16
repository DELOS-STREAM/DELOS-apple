import AVFoundation
import CoreMedia
import QuartzCore
import Synchronization

/// Shows decoded video. The first renderer is `AVSampleBufferDisplayLayer`, where the system decodes, paces and
/// handles HDR (decision L4); a Metal renderer follows when upscalers or PyroWave need it. Called on the core's video
/// thread.
public protocol VideoRenderer: Sendable {
    /// Shows a frame; returns false when the renderer failed and needs a key frame to start over.
    func enqueue(_ sample: CMSampleBuffer) -> Bool
    /// Drops the frames waiting to be shown (before a new stream or after an error).
    func flush()
}

/// Renders through an `AVSampleBufferDisplayLayer`; a view hosts ``layer`` (on the main actor), while frames go to its
/// `sampleBufferRenderer`, which accepts them from any thread. With pacing (``FramePacer``) each frame gets the time it is
/// shown at on a timebase that follows the host clock; without it, frames are shown as soon as they are decoded.
public final class DisplayLayerRenderer: VideoRenderer {
    public nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer
    private let pacer: Mutex<FramePacer>

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

    public func flush() {
        renderer.flush()
        pacer.withLock { $0.reset() }
    }
}
