import CoreMedia
import Foundation
import Metal
import QuartzCore
import Synchronization

/// Decodes with VideoToolbox and presents from the display's own clock: the decoded pictures wait in a small queue
/// (``FrameQueue``, timed by the same ``FramePacing`` modes as the display layer), and a `CAMetalDisplayLink` calls
/// back at every refresh with the drawable for it; the frame that is due at that refresh is drawn into the drawable
/// through a Metal texture cache and presented at the refresh's time. Nothing is shown between refreshes and no frame
/// is shown twice by the system's own pacing, so the interval between shown frames is decided here, not by
/// `AVSampleBufferDisplayLayer`'s internals.
///
/// The second path of decision L4 and the default (``RendererChoice``). It is where the launch scene's arrival
/// (``LaunchArrival``), the upscalers (MetalFX Spatial, MetalFX Temporal, Sharpen only: ``MetalUpscaler``), the scale
/// modes, HDR tone mapping (issue #11) and PyroWave (issue #13) draw.
///
/// `CAMetalDisplayLink` exists on iOS and tvOS 17, and on macOS 14 (the app's minimum is 15), so the Mac needs no second
/// display-link kind.
public final class MetalRenderer: VideoRenderer {
    public var name: String { "VideoToolbox + Metal" }

    private nonisolated(unsafe) let layer: CAMetalLayer
    private let pipeline: MetalPipeline
    private let fps: Int
    private let pacing: FramePacing
    private let options: VideoRenderOptions
    /// Created and stopped on the main actor.
    private nonisolated(unsafe) var ticker: MetalDisplayLinkTicker?

    @MainActor public var hostLayer: CALayer { layer }

    /// Nil when the device has no Metal GPU or the shader library is missing.
    @MainActor
    public init?(pacing: FramePacing, fps: Int, options: VideoRenderOptions = VideoRenderOptions()) {
        guard let pipeline = MetalPipeline(pacing: pacing, fps: fps, options: options) else { return nil }
        self.pipeline = pipeline
        self.fps = fps
        self.pacing = pacing
        self.options = options
        layer = CAMetalLayer()
        layer.device = pipeline.drawer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.colorspace = CGColorSpace(name: ColorConversion().layerColorSpaceName)
        // A stream whose colours differ from the default (BT.2020, HDR) retags the layer at its first picture
        let retag = LayerRetagger(layer)
        pipeline.observeConversion { conversion, hdr in retag.apply(conversion, hdr: hdr) }
    }

    deinit {
        ticker?.stop()
        pipeline.invalidate()
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        pipeline.enqueue(sample)
    }

    public func flush() {
        pipeline.flush()
    }

    public func startArrival(duration: Double) {
        pipeline.startArrival(duration: duration)
    }

    public func cancelArrival() {
        pipeline.cancelArrival()
    }

    public func presentationCounters() async -> VideoPresentationCounters? {
        pipeline.counters()
    }

    public func setScaleMode(_ mode: VideoScaleMode) { pipeline.setScaleMode(mode) }
    public func setUpscaler(_ settings: UpscalerSettings) { pipeline.setUpscaler(settings) }
    public var upscalerSettings: UpscalerSettings { pipeline.upscaler }
    public var upscalerStatus: UpscalerStatus { pipeline.upscalerStatus }
    public var isSupersampling: Bool { pipeline.isSupersampling }
    public func observeUpscalerOverload(_ body: (@Sendable (UpscalerMode, Bool) -> Void)?) {
        pipeline.observeUpscalerOverload(body)
    }

    @MainActor public func resize(to bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.contentsScale = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        if size.width > 0, size.height > 0 { layer.drawableSize = size }
        CATransaction.commit()
    }

    /// Starts the display link at the plan's frame rate (Android's `Surface.setFrameRate`): the highest refresh rate the
    /// stream divides, the stream's own rate when the refresh rate may be reduced, or with VRR. ProMotion screens slow down
    /// when nothing asks for more.
    @MainActor public func attached(to display: VideoDisplay) -> DisplayRefreshPlanner.Plan {
        let plan = options.refreshPlan(for: display, pacing: pacing, fps: fps)
        pipeline.setVRR(plan.vrr)
        ticker?.stop()
        let ticker = MetalDisplayLinkTicker(layer: layer, frameRate: plan.surfaceFrameRate) { [pipeline] tick in
            pipeline.tick(tick)
        }
        ticker.start()
        self.ticker = ticker
        return plan
    }

    @MainActor public func detached() {
        ticker?.stop()
        ticker = nil
    }
}

/// Calls back at every refresh of the display, from a thread of its own (the main thread is busy with the interface and
/// would add its jitter to the pictures).
final class MetalDisplayLinkTicker: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private let handler: @Sendable (RefreshTick) -> Void
    private let nominal: Double
    private let frameRate: Float
    private nonisolated(unsafe) let layer: CAMetalLayer
    private let running = Mutex(false)
    private var lastPresentation: Double?
    private var refresh: Double

    init(layer: CAMetalLayer, frameRate: Double, handler: @escaping @Sendable (RefreshTick) -> Void) {
        self.layer = layer
        self.handler = handler
        self.frameRate = Float(max(frameRate, 1))
        nominal = 1 / max(frameRate, 1)
        refresh = nominal
    }

    func start() {
        guard running.withLock({ state in
            defer { state = true }
            return !state
        }) else { return }
        let thread = Thread { [self] in
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameRateRange = CAFrameRateRange(minimum: frameRate, maximum: frameRate, preferred: frameRate)
            link.preferredFrameLatency = 2
            let runLoop = RunLoop.current
            // Keeps the run loop alive between callbacks
            runLoop.add(Port(), forMode: .default)
            link.add(to: runLoop, forMode: .default)
            while running.withLock({ $0 }) {
                runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25))
            }
            link.invalidate()
        }
        thread.name = "DELOS display link"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        running.withLock { $0 = false }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let presentation = update.targetPresentationTimestamp
        if let last = lastPresentation {
            let delta = presentation - last
            // A refresh the system skipped doubles the delta; the nominal rate is the better guess then
            if delta > 0.5 * nominal, delta < 1.5 * nominal { refresh = delta }
        }
        lastPresentation = presentation
        handler(RefreshTick(presentation: presentation, refresh: refresh, drawable: update.drawable))
    }
}

/// Retags the layer's colour space from the render thread: the layer is touched on the main queue only.
final class LayerRetagger: @unchecked Sendable {
    private weak var layer: CAMetalLayer?

    init(_ layer: CAMetalLayer) {
        self.layer = layer
    }

    func apply(_ conversion: ColorConversion, hdr: HDRPictureInfo?) {
        DispatchQueue.main.async { [self] in
            if let layer { Self.configure(layer, conversion: conversion, hdr: hdr) }
        }
    }

    /// PQ/HLG stay encoded in the shader; Core Animation interprets the matching color-space tag exactly once.
    @MainActor
    static func configure(_ layer: CAMetalLayer, conversion: ColorConversion, hdr: HDRPictureInfo? = nil) {
        layer.pixelFormat = conversion.isHDR ? .rgba16Float : .bgra8Unorm
        #if !os(tvOS)
        // tvOS has no such switch: its output is HDR when the TV is in an HDR mode
        layer.wantsExtendedDynamicRangeContent = conversion.isHDR
        layer.edrMetadata = edrMetadata(conversion, hdr: hdr)
        #endif
        layer.colorspace = CGColorSpace(name: conversion.layerColorSpaceName)
    }

    #if !os(tvOS)
    /// What the display needs to map the pictures: the host's mastering volume and content light level for HDR10 (PQ;
    /// PQ stays encoded in the shader, so one unit of the layer is 10,000 nits), the HLG description for HLG, nothing
    /// for SDR or when the host sent none.
    static func edrMetadata(_ conversion: ColorConversion, hdr: HDRPictureInfo?) -> CAEDRMetadata? {
        switch conversion.transfer {
        case .sdr: nil
        case .hlg: CAEDRMetadata.hlg
        case .pq:
            hdr.map {
                CAEDRMetadata.hdr10(
                    displayInfo: $0.masteringDisplayColorVolume, contentInfo: $0.contentLightLevelInfo, opticalOutputScale: 10_000)
            }
        }
    }
    #endif
}
