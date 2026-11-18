import AVFoundation
import CoreMedia
import QuartzCore
import Synchronization

/// Where the stream's compressed frames go while Picture in Picture may take the stream (``PictureInPictureVideo``). The
/// renderer that gets them after a change starts at a key frame: the frames before it are refused, which ``VideoOutput``
/// turns into an IDR request.
public struct PictureInPictureRoute: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        /// The stream's own renderer; Picture in Picture's layer copies its decoded pictures.
        case main
        /// Picture in Picture's layer decodes the frames itself (the system's decoder keeps running in the background).
        case pictureInPicture
    }

    /// What happens to one compressed frame.
    enum Step: Equatable, Sendable {
        /// To the stream's renderer (after a change it flushes itself and waits for a key frame on its own).
        case main
        case pictureInPicture
        /// Refused until a key frame arrives for Picture in Picture's layer.
        case awaitKeyFrame
    }

    private(set) var target = Target.main
    /// The target changed and the renderers have not been flushed for it yet.
    private(set) var pendingFlush = false
    private var awaitingKeyFrame = false

    /// Whether Picture in Picture's layer shows the stream's renderer's decoded pictures now.
    var mirrors: Bool { target == .main }

    mutating func set(_ new: Target) {
        guard new != target else { return }
        target = new
        pendingFlush = true
    }

    /// The step for the next frame; `flush` is true once after a change, before the frame is handed on.
    mutating func next(keyFrame: Bool) -> (flush: Bool, step: Step) {
        let flush = pendingFlush
        if flush {
            pendingFlush = false
            awaitingKeyFrame = target == .pictureInPicture
        }
        switch target {
        case .main:
            return (flush, .main)
        case .pictureInPicture:
            if awaitingKeyFrame {
                guard keyFrame else { return (flush, .awaitKeyFrame) }
                awaitingKeyFrame = false
            }
            return (flush, .pictureInPicture)
        }
    }
}

/// The stream's renderer with the `AVSampleBufferDisplayLayer` Picture in Picture shows (`checkbox_enable_pip`, Android's
/// observer mode), made only when the profile turned it on and the device has it. AVKit's Picture in Picture shows a
/// sample buffer display layer only; the stream's renderer is Metal (``RendererChoice``), and Metal and VideoToolbox's
/// hardware do not work for an app in the background.
///
/// - While the app is in front, ``MetalRenderer`` draws the stream as always, and the layer (``contentLayer``, behind the
///   Metal layer in the video view) shows each picture VideoToolbox decoded for it, without decoding it again: the system
///   then has a playing layer to take into its window when the app leaves.
/// - While the window shows the stream (``route(to:)`` `.pictureInPicture`, from its start until it stops), the
///   compressed frames go to the layer instead, which decodes them with the system's decoder, starting at a key frame.
/// - When the window stops, the frames go back to the stream's renderer, which waits for a key frame too.
///
/// When the stream's renderer is the display layer itself, its layer is the content and nothing is rerouted. The rest of
/// ``VideoRenderer`` is the stream's renderer's; the layer also follows the HDR switch and the scale mode.
public final class PictureInPictureVideo: VideoRenderer {
    public let main: any VideoRenderer
    /// The layer Picture in Picture shows.
    public let source: DisplayLayerRenderer
    /// The stream's renderer is ``source``: its own layer is shown.
    public let sharesLayer: Bool
    private let route = Mutex(PictureInPictureRoute())

    @MainActor
    public init(wrapping main: any VideoRenderer, options: VideoRenderOptions = VideoRenderOptions()) {
        self.main = main
        if let layer = main as? DisplayLayerRenderer {
            source = layer
            sharesLayer = true
        } else {
            let source = DisplayLayerRenderer(pacing: .latency, options: options)
            self.source = source
            sharesLayer = false
            (main as? MetalRenderer)?.observeDecoded { [weak self] pixelBuffer in
                guard let self, route.withLock({ $0.mirrors }) else { return }
                self.source.show(decoded: pixelBuffer)
            }
        }
    }

    /// The layer the system takes into its Picture in Picture window.
    @MainActor public var contentLayer: AVSampleBufferDisplayLayer { source.layer }

    /// Where the frames go from the next one on: to the layer while the window shows the stream, else to the stream's renderer.
    public func route(to target: PictureInPictureRoute.Target) {
        guard !sharesLayer else { return }
        route.withLock { $0.set(target) }
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard !sharesLayer else { return main.enqueue(sample) }
        let (flush, step) = route.withLock { $0.next(keyFrame: MetalPipeline.isKeyFrame(sample)) }
        if flush {
            // The layer keeps its last picture until its next one; the stream's renderer starts over at a key frame
            source.flushKeepingPicture()
            if step == .main { main.flush() }
        }
        switch step {
        case .main:
            return main.enqueue(sample)
        case .pictureInPicture:
            return source.enqueue(sample)
        case .awaitKeyFrame:
            return false
        }
    }

    public var name: String { main.name }

    public func setHDR(_ active: Bool) {
        main.setHDR(active)
        if !sharesLayer { source.setHDR(active) }
    }

    public func flush() {
        main.flush()
        if !sharesLayer { source.flush() }
    }

    /// The counters of the renderer that gets the frames now (``WatchdogVideoRenderer`` takes the change as a counter reset).
    public func presentationCounters() async -> VideoPresentationCounters? {
        if route.withLock({ $0.target }) == .pictureInPicture, !sharesLayer { return await source.presentationCounters() }
        return await main.presentationCounters()
    }

    @MainActor public var hostLayer: CALayer { main.hostLayer }

    @MainActor public func resize(to bounds: CGRect, scale: CGFloat) {
        main.resize(to: bounds, scale: scale)
        if !sharesLayer { source.resize(to: bounds, scale: scale) }
    }

    @MainActor public func attached(to display: VideoDisplay) -> DisplayRefreshPlanner.Plan { main.attached(to: display) }
    @MainActor public func detached() { main.detached() }
    public func startArrival(duration: Double) { main.startArrival(duration: duration) }
    public func cancelArrival() { main.cancelArrival() }

    public func setScaleMode(_ mode: VideoScaleMode) {
        main.setScaleMode(mode)
        if !sharesLayer { source.setScaleMode(mode) }
    }

    public func setUpscaler(_ settings: UpscalerSettings) { main.setUpscaler(settings) }
    public var upscalerSettings: UpscalerSettings { main.upscalerSettings }
    public var upscalerStatus: UpscalerStatus { main.upscalerStatus }
    public var isSupersampling: Bool { main.isSupersampling }
    public func observeUpscalerOverload(_ body: (@Sendable (UpscalerMode, Bool) -> Void)?) { main.observeUpscalerOverload(body) }
}
