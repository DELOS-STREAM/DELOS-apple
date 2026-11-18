import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization

/// One refresh of the display, as the display link reports it.
struct RefreshTick: @unchecked Sendable {
    /// When the picture drawn for this refresh appears on the display (seconds on the host clock).
    var presentation: Double
    /// Seconds from one refresh to the next.
    var refresh: Double
    /// The layer's drawable for this refresh; nil draws into an offscreen texture (tests).
    var drawable: (any CAMetalDrawable)?
}

/// The Metal renderer without the layer and the display link: decodes (``VideoDecoder``), keeps the decoded pictures in a
/// ``FrameQueue`` timed by ``FramePacer``, and at each refresh draws the frame the queue hands out (``MetalFrameDrawer``,
/// through the upscaler when it is on) and presents the drawable. `MetalRenderer` connects it to a `CAMetalLayer` and a
/// `CAMetalDisplayLink`; the replay tests connect it to a virtual clock and virtual refreshes.
///
/// The upscaler's output stage: at most two frames of its GPU work in flight (a newer frame replaces one held back for the
/// busy GPU), its load measured in one-second windows that lighten MetalFX Temporal's optical flow (``FlowGovernor``) and
/// report an overload once per stream and mode (``OverloadDetector``; nothing is changed automatically), and a streak of
/// 60 failed drawings switches it off for the stream (the picture is then drawn directly).
///
/// Three threads meet here: the core's video thread (`enqueue`), VideoToolbox's (decoded pictures) and the display link's
/// (`tick`); the queue and the counters are behind one lock that is held for a few assignments only.
final class MetalPipeline: @unchecked Sendable {
    typealias Clock = @Sendable () -> Double

    /// A frame that was drawn for a refresh.
    struct PresentedFrame: Sendable, Equatable {
        /// Number of the picture among those the renderer decoded, from 0.
        var sequence: Int
        /// The time the pacer gave the frame.
        var due: Double
        /// The refresh it was shown at.
        var presentation: Double
    }

    /// About a second of frames: a replaced surface recovers within it, a broken upscaler never does (Android
    /// `MAX_CONSECUTIVE_DRAW_FAILURES`).
    static let maximumUpscalerFailures = 60

    private struct State {
        var queue: FrameQueue<NumberedFrame>
        var decoded = 0
        var decodeSeconds = 0.0
        var lastFrame: NumberedFrame?
        var lastDrawnSize = (width: 0, height: 0)
        var lastConversion: ColorConversion?
        var lastHDRInfo: HDRPictureInfo?
        var awaitingKeyFrame = true
        var lateRefreshes = 0
        /// The launch scene's arrival while it runs.
        var arrival: ArrivalRun?
        /// The picture on screen was drawn with an arrival pose (so it must be drawn again once the arrival ends).
        var posedOnScreen = false
        var scaleMode: VideoScaleMode
        var upscaler: UpscalerSettings
        /// The upscaler broke on this stream: frames are drawn directly until the stream ends.
        var upscalerFailed = false
        var upscalerFailures = 0
        /// The picture on screen came from the upscaler, and how.
        var upscaledOnScreen: UpscaleReport?
        /// A frame held back while the upscaler's GPU work was in flight.
        var held: (frame: NumberedFrame, due: Double)?
        var inFlight = GPUInFlight()
        var window = UpscalerWindowMeter()
        var overload = OverloadDetector()
        var flow = FlowGovernor()
        /// Modes (``UpscalerMode/index`` bits) whose overload was already reported in this stream.
        var overloadReported = 0
        var gpuBusySkipped = 0
        /// Smoothed GPU time per upscaled frame, milliseconds (Android `getGpuTimeMs`).
        var upscalerMilliseconds = 0.0
        var sharpen = SharpenMeter()
        var frameTimes = FrameTimes()
        /// Decoded to presented on the display (Android's avail->present, "Render latency").
        var renderLatency = StageWindow()
        var vrr = false

        /// The arrival's pose for a refresh at `time`, nil when the picture is drawn plainly; an arrival that is complete
        /// at `time` ends here.
        mutating func arrivalPose(at time: Double) -> ArrivalPose? {
            guard let run = arrival else { return nil }
            let opening = run.opening(at: time)
            if opening >= 1 {
                arrival = nil
                return nil
            }
            return LaunchArrival.shouldActivate(opening) ? LaunchArrival.pose(opening: opening) : nil
        }

        var upscalerActive: Bool { upscaler.enabled && !upscalerFailed }

        /// One finished load window: lighten MetalFX Temporal's flow or report an overload. Returns the mode to report, if any.
        mutating func onWindow(_ window: UpscalerWindow?) -> (UpscalerMode, Bool)? {
            guard let window else { return nil }
            _ = flow.onWindow(window)
            guard overload.onWindow(window) else { return nil }
            let mode = upscaler.mode, bit = 1 << mode.index
            guard overloadReported & bit == 0 else { return nil }
            overloadReported |= bit
            return (mode, upscaledOnScreen?.dimensions.isSupersampling ?? false)
        }
    }

    private struct NumberedFrame {
        var frame: DecodedFrame
        var sequence: Int
        /// When it was decoded (the clock's seconds).
        var arrival: Double
    }

    private struct Work {
        var frame: NumberedFrame
        var due: Double?
        var pose: ArrivalPose?
        var scaleMode: VideoScaleMode
        var upscale: UpscaleRequest?
    }

    let drawer: MetalFrameDrawer
    private let clock: Clock
    private let state: Mutex<State>
    private nonisolated(unsafe) var decoder: VideoDecoder!
    private let offscreen = Mutex<(any MTLTexture)?>(nil)
    /// The offscreen target's size when it is not the picture's (tests).
    private let offscreenSize = Mutex<(width: Int, height: Int)?>(nil)
    private let observer = Mutex<(@Sendable (PresentedFrame) -> Void)?>(nil)
    private let conversionChanged = Mutex<(@Sendable (ColorConversion, HDRPictureInfo?) -> Void)?>(nil)
    private let overloadObserver = Mutex<(@Sendable (UpscalerMode, Bool) -> Void)?>(nil)

    init?(
        pacing: FramePacing, fps: Int, options: VideoRenderOptions = VideoRenderOptions(),
        clock: @escaping Clock = { CACurrentMediaTime() }, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        metalFX: MetalFXSupport? = nil
    ) {
        guard let drawer = MetalFrameDrawer(device: device, metalFX: metalFX) else { return nil }
        self.drawer = drawer
        self.clock = clock
        state = Mutex(State(queue: FrameQueue(pacing: pacing, fps: fps), scaleMode: options.scaleMode, upscaler: options.upscaler))
        decoder = VideoDecoder(
            onFrame: { [weak self] frame in self?.decoded(frame) },
            onFailure: { [weak self] _ in self?.state.withLock { $0.awaitingKeyFrame = true } })
    }

    /// Called for every frame that is drawn, on the thread that draws.
    func observePresented(_ body: (@Sendable (PresentedFrame) -> Void)?) {
        observer.withLock { $0 = body }
    }

    /// Called when the pictures' colour description changes (and for the first picture), on the thread that draws.
    /// The HDR metadata of the pictures is reported with it.
    func observeConversion(_ body: (@Sendable (ColorConversion, HDRPictureInfo?) -> Void)?) {
        conversionChanged.withLock { $0 = body }
    }

    /// Called once per stream and mode when the upscaler could not keep up for about two seconds, with the mode and
    /// whether it was supersampling; on the thread that draws.
    func observeUpscalerOverload(_ body: (@Sendable (UpscalerMode, Bool) -> Void)?) {
        overloadObserver.withLock { $0 = body }
    }

    // MARK: Settings while the stream runs

    func setScaleMode(_ mode: VideoScaleMode) {
        state.withLock { $0.scaleMode = mode }
    }

    /// The stream menu's upscaler controls. Switching on after a failure tries again (Android `setUpscalingEnabled`).
    func setUpscaler(_ settings: UpscalerSettings) {
        state.withLock { s in
            if settings.enabled, !s.upscaler.enabled { s.upscalerFailed = false; s.upscalerFailures = 0 }
            if settings.mode != s.upscaler.mode {
                s.overload.reset()
                s.flow.reset()
            }
            s.upscaler = settings
        }
    }

    var upscaler: UpscalerSettings { state.withLock { $0.upscaler } }

    var upscalerStatus: UpscalerStatus {
        state.withLock { s in
            if s.upscaler.enabled, s.upscalerFailed { return .unavailable }
            switch (s.upscaler.enabled, s.upscaledOnScreen) {
            case (true, nil): return .starting
            case (false, .some): return .stopping
            case (true, .some(let report)): return report.fellBack ? .unavailable : .on(report.mode)
            case (false, nil): return .off
            }
        }
    }

    /// Whether the upscaler supersamples now: the stream has the view's size and a scaling mode runs.
    var isSupersampling: Bool {
        state.withLock { s in
            s.upscaler.mode.scales && (s.upscaledOnScreen?.dimensions.isSupersampling ?? false)
        }
    }

    func setVRR(_ active: Bool) {
        state.withLock { $0.vrr = active }
    }

    // MARK: Frames in

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let keyFrame = Self.isKeyFrame(sample)
        let accepted = state.withLock { s in
            if s.awaitingKeyFrame {
                guard keyFrame else { return false }
                s.awaitingKeyFrame = false
            }
            return true
        }
        guard accepted else { return false }
        return decoder.decode(sample)
    }

    static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        return CFDictionaryGetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) == nil
    }

    private func decoded(_ frame: DecodedFrame) {
        let now = clock()
        state.withLock { s in
            s.queue.push(NumberedFrame(frame: frame, sequence: s.decoded, arrival: now), arrival: now)
            s.decoded += 1
            s.decodeSeconds += frame.decodeSeconds
            if s.upscalerActive { s.window.arrived(at: now) }
        }
    }

    func flush() {
        state.withLock { s in
            s.queue.flush()
            s.lastFrame = nil
            s.held = nil
            s.awaitingKeyFrame = true
        }
    }

    /// Blocks until the frames submitted so far are decoded and queued (replay tests only).
    func waitForDecodes() {
        decoder.finishFrames()
    }

    func invalidate() {
        decoder.invalidate()
    }

    // MARK: Refreshes

    /// Shows the frame due at this refresh, if there is one. While the arrival runs the last frame is drawn again at
    /// every refresh with the pose of that refresh's time, and once it ends the last frame is drawn plainly once more,
    /// so a still picture settles too and the stream goes on exactly as without it. While the upscaler's GPU has two
    /// frames in flight the newest frame waits for a later refresh.
    func tick(_ tick: RefreshTick) {
        let size = tick.drawable.map { (width: $0.texture.width, height: $0.texture.height) }
        let now = clock()
        var report: (UpscalerMode, Bool)?
        let work = state.withLock { s -> Work? in
            let pose = s.arrivalPose(at: tick.presentation)
            let upscaling = s.upscalerActive
            var taken = s.queue.take(at: tick.presentation, refresh: tick.refresh).map { (frame: $0.frame, due: $0.due) }
            if taken != nil, s.held != nil {
                // The frame held back for the GPU is replaced by a newer one and will never be shown
                s.held = nil
                s.gpuBusySkipped += 1
                report = s.onWindow(s.window.busySkipped(at: now))
            }
            if upscaling, s.inFlight.shouldSkip(now: now) {
                if let taken { s.held = taken }
                return nil
            }
            if taken == nil, let held = s.held {
                taken = held
                s.held = nil
            }
            func upscale(_ frame: NumberedFrame) -> UpscaleRequest? {
                guard upscaling else { return nil }
                return UpscaleRequest(
                    settings: s.upscaler, sequence: frame.sequence, frameTime: frame.arrival, reuseFlow: s.flow.reuseFlowThisFrame())
            }
            if let taken {
                s.lastFrame = taken.frame
                s.lastDrawnSize = size ?? (0, 0)
                s.posedOnScreen = pose != nil
                return Work(frame: taken.frame, due: taken.due, pose: pose, scaleMode: s.scaleMode, upscale: upscale(taken.frame))
            }
            // No new picture: the layer keeps the last one, unless the layer's size changed, the arrival moves it, or the
            // upscaler was switched on or off
            guard let last = s.lastFrame else { return nil }
            let resized = size.map { $0 != s.lastDrawnSize } ?? false
            let upscalerChanged = upscaling != (s.upscaledOnScreen != nil)
            guard resized || pose != nil || s.posedOnScreen || upscalerChanged else { return nil }
            if let size { s.lastDrawnSize = size }
            s.posedOnScreen = pose != nil
            return Work(frame: last, due: nil, pose: pose, scaleMode: s.scaleMode, upscale: upscale(last))
        }
        if let report { reportOverload(report) }
        guard let work else { return }
        draw(work, tick: tick, now: now)
    }

    /// Starts the launch scene's arrival now on the renderer's clock; it lasts `duration` seconds (the exit's).
    func startArrival(duration: Double) {
        let now = clock()
        state.withLock { $0.arrival = ArrivalRun(start: now, duration: duration) }
    }

    /// Ends the arrival at once: the next refresh draws the picture plainly.
    func cancelArrival() {
        state.withLock { $0.arrival = nil }
    }

    private func reportOverload(_ report: (UpscalerMode, Bool)) {
        overloadObserver.withLock({ $0 })?(report.0, report.1)
    }

    private func draw(_ work: Work, tick: RefreshTick, now: Double) {
        let numbered = work.frame
        let pixelBuffer = numbered.frame.pixelBuffer
        guard let conversion = ColorConversion(pixelBuffer: pixelBuffer),
              let commandBuffer = drawer.queue.makeCommandBuffer() else { return }
        let hdrInfo = conversion.isHDR ? HDRPictureInfo(pixelBuffer: pixelBuffer) : nil
        let changed = state.withLock { s -> Bool in
            defer { s.lastConversion = conversion; s.lastHDRInfo = hdrInfo }
            return s.lastConversion != conversion || s.lastHDRInfo != hdrInfo
        }
        if changed, let body = conversionChanged.withLock({ $0 }) { body(conversion, hdrInfo) }
        let target: any MTLTexture
        if let drawable = tick.drawable {
            target = drawable.texture
        } else if let texture = offscreenTexture(
            width: offscreenSize.withLock({ $0?.width }) ?? CVPixelBufferGetWidth(pixelBuffer),
            height: offscreenSize.withLock({ $0?.height }) ?? CVPixelBufferGetHeight(pixelBuffer)) {
            target = texture
        } else {
            return
        }
        let drawn = drawer.draw(
            pixelBuffer, conversion: conversion, into: target, commandBuffer: commandBuffer, arrival: work.pose,
            scaleMode: work.scaleMode, upscale: work.upscale)
        guard afterDrawing(drawn: drawn, upscaled: work.upscale != nil, report: drawer.lastReport, commandBuffer: commandBuffer, now: now)
        else { return }
        if let drawable = tick.drawable {
            commandBuffer.present(drawable)
            // The drawing must be done by the time of the refresh it is for
            let presentation = tick.presentation
            commandBuffer.addCompletedHandler { [weak self] buffer in
                if buffer.gpuEndTime > presentation { self?.state.withLock { $0.lateRefreshes += 1 } }
            }
            #if !targetEnvironment(simulator)
            // The simulators' SDKs have no presented time: the Render latency stays empty there
            if work.due != nil {
                // Render latency: from the decoded picture to the display's own presented time (0: skipped)
                let decodedAt = numbered.arrival
                drawable.addPresentedHandler { [weak self] shown in
                    let presented = shown.presentedTime
                    guard presented > 0 else { return }
                    self?.state.withLock { $0.renderLatency.record(presented - decodedAt) }
                }
            }
            #endif
        }
        commandBuffer.commit()
        if tick.drawable == nil { commandBuffer.waitUntilCompleted() }
        guard let due = work.due else { return }
        state.withLock { $0.frameTimes.add(tick.presentation) }
        if let body = observer.withLock({ $0 }) {
            body(PresentedFrame(sequence: numbered.sequence, due: due, presentation: tick.presentation))
        }
    }

    /// Books a drawing: the upscaler's failures, its GPU work in flight and its load windows. False when nothing was drawn.
    private func afterDrawing(
        drawn: Bool, upscaled: Bool, report: UpscaleReport?, commandBuffer: any MTLCommandBuffer, now: Double
    ) -> Bool {
        guard upscaled else {
            if drawn { state.withLock { $0.upscaledOnScreen = nil } }
            return drawn
        }
        guard drawn, let report else {
            // A single failed frame is skipped; a streak means the upscaler itself is broken
            state.withLock { s in
                s.upscalerFailures += 1
                if s.upscalerFailures >= Self.maximumUpscalerFailures { s.upscalerFailed = true }
            }
            return false
        }
        let window = state.withLock { s -> UpscalerWindow? in
            s.upscalerFailures = 0
            s.upscaledOnScreen = report
            s.inFlight.submitted()
            return report.fresh ? s.window.drew(at: now) : nil
        }
        if let overload = state.withLock({ $0.onWindow(window) }) { reportOverload(overload) }
        nonisolated(unsafe) let parts = (report.preparation, report.pass)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            func seconds(_ part: (any MTLCommandBuffer)?) -> Double? {
                guard let part, part.status == .completed else { return nil }
                return part.gpuEndTime - part.gpuStartTime
            }
            let frame = buffer.gpuEndTime - buffer.gpuStartTime
            let prepare = seconds(parts.0), pass = seconds(parts.1)
            self?.state.withLock { s in
                s.inFlight.finished()
                let total = frame + (prepare ?? 0) + (pass ?? 0)
                s.window.gpuWork(seconds: total)
                s.upscalerMilliseconds = smoothedMilliseconds(s.upscalerMilliseconds, total * 1000)
                if let pass { s.sharpen.record(passSeconds: pass, prepareSeconds: prepare) }
            }
        }
        return true
    }

    private func offscreenTexture(width: Int, height: Int) -> (any MTLTexture)? {
        offscreen.withLock { texture in
            if let texture, texture.width == width, texture.height == height { return texture }
            let description = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            description.usage = [.renderTarget, .shaderRead]
            description.storageMode = .shared
            texture = drawer.device.makeTexture(descriptor: description)
            return texture
        }
    }

    /// Draws into an offscreen texture of `width` × `height` from now on (tests: a view of another size than the stream).
    func useOffscreenSize(width: Int, height: Int) {
        offscreenSize.withLock { $0 = (width, height) }
    }

    /// The pixels of the last offscreen drawing, BGRA, row by row (replay tests only).
    func offscreenPixels() -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let texture = offscreen.withLock({ $0 }) else { return nil }
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(
            &bytes, bytesPerRow: texture.width * 4,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return (texture.width, texture.height, bytes)
    }

    // MARK: Counters

    /// The cumulative counters and the windows that close with this reading (the queue's peak, the render latency, the
    /// Sharpen only cost).
    func counters() -> VideoPresentationCounters {
        state.withLock { s in
            let queue = s.queue.counters
            defer { s.queue.resetPeak() }
            var counters = VideoPresentationCounters(
                totalFrames: queue.presented + queue.dropped, droppedFrames: queue.dropped,
                accumulatedDelaySeconds: queue.accumulatedLateness, decodedFrames: s.decoded,
                accumulatedDecodeSeconds: s.decodeSeconds, refreshes: queue.refreshes,
                repeatedRefreshes: queue.repeatedRefreshes, waitingSum: queue.waitingSum, peakWaiting: queue.peakWaiting,
                lateRefreshes: s.lateRefreshes)
            counters.onePercentLowFPS = s.frameTimes.onePercentLowFPS
            counters.renderLatency = s.renderLatency.summarize()
            counters.vrr = s.vrr
            let sharpen = s.sharpen.summarize()
            if let report = s.upscaledOnScreen {
                counters.gpuBusySkipped = s.gpuBusySkipped
                counters.upscalingMilliseconds = s.upscalerMilliseconds
                counters.scaleDescription = Self.scaleDescription(report)
                counters.sharpen = report.mode == .sharpen ? sharpen : nil
            }
            return counters
        }
    }

    /// The statistics panel's scale line ("Upscaled to: …", "Supersampled to: …", "Sharpen only: …").
    static func scaleDescription(_ report: UpscaleReport) -> String {
        let d = report.dimensions
        if report.mode == .sharpen { return "Sharpen only: \(d.internalWidth) × \(d.internalHeight)" }
        if d.isSupersampling { return "Supersampled to: \(d.internalWidth) × \(d.internalHeight)" }
        return "Upscaled to: \(d.presentationWidth) × \(d.presentationHeight)"
    }
}
