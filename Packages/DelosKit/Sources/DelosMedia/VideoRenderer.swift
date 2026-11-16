import AVFoundation
import CoreMedia

/// Shows decoded video. The first renderer is `AVSampleBufferDisplayLayer`, where the system decodes, paces and
/// handles HDR (decision L4); a Metal renderer follows when upscalers or PyroWave need it.
@MainActor
public protocol VideoRenderer: AnyObject {
    /// Shows a frame; returns false when the renderer failed and needs a key frame to start over.
    func enqueue(_ sample: CMSampleBuffer) -> Bool
    /// Drops the frames waiting to be shown (before a new stream or after an error).
    func flush()
}

/// Renders through an `AVSampleBufferDisplayLayer`; the view layer hosts ``layer``.
@MainActor
public final class DisplayLayerRenderer: VideoRenderer {
    public let layer = AVSampleBufferDisplayLayer()

    public init() {
        layer.videoGravity = .resizeAspect
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            return false
        }
        renderer.enqueue(sample)
        return true
    }

    public func flush() {
        layer.sampleBufferRenderer.flush()
    }
}
