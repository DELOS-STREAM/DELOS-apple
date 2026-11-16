import AVFoundation
import CoreMedia

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
/// `sampleBufferRenderer`, which accepts them from any thread.
public final class DisplayLayerRenderer: VideoRenderer {
    public nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer
    private nonisolated(unsafe) let renderer: AVSampleBufferVideoRenderer

    @MainActor
    public init() {
        layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        renderer = layer.sampleBufferRenderer
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        renderer.enqueue(sample)
        return true
    }

    public func flush() {
        renderer.flush()
    }
}
