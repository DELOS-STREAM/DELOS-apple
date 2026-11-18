import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization

/// One refresh of the display, as the display link reports it.
struct RefreshTick: @unchecked Sendable {
    /// The display link's estimated presentation time (seconds on the host clock), not an observed presentation.
    var presentation: Double
    /// Seconds from one refresh to the next.
    var refresh: Double
    /// The layer's drawable for this refresh; nil draws into an offscreen texture (tests).
    var drawable: (any CAMetalDrawable)?
    /// The CPU deadline for encoding and requesting presentation; GPU work may finish later.
    var deadline: Double?
}

/// The two display-link deadlines are different: `targetTimestamp` is for CPU submission, while the GPU can run
/// until the estimated presentation time. In particular, GPU completion after the first is not itself a missed frame.
struct FrameDrawingTiming: Sendable {
    var callback: Double
    var presentation: Double
    var submissionDeadline: Double?

    func submittedLate(at time: Double) -> Bool { submissionDeadline.map { time > $0 } ?? false }
    func gpuFinishedLate(at time: Double) -> Bool { time > presentation }
}

/// Accounts for completed presentation feedback, independently of selecting or submitting a frame. A ticket resolves
/// once, even if a GPU error and a skipped-drawable callback both report it. Animation/resize redraws have no ticket.
struct FramePresentationLedger {
    struct Pending: Sendable {
        var ticket: Int
        var sequence: Int
        var due: Double
        var decodedAt: Double
    }

    static let maximumInFlight = 2
    private(set) var inFlight = 0
    private(set) var shown = 0
    private(set) var dropped = 0
    private(set) var accumulatedDelay = 0.0
    private var nextTicket = 0
    private var pending: [Pending] = []

    init() { pending.reserveCapacity(3) }

    var canDraw: Bool { inFlight < Self.maximumInFlight }

    mutating func submitted(sequence: Int, due: Double?, decodedAt: Double) -> Int? {
        inFlight += 1
        guard let due else { return nil }
        let ticket = nextTicket
        nextTicket += 1
        pending.append(Pending(ticket: ticket, sequence: sequence, due: due, decodedAt: decodedAt))
        return ticket
    }

    mutating func gpuCompleted(ticket: Int?, succeeded: Bool) {
        inFlight = max(0, inFlight - 1)
        if !succeeded, let ticket { _ = complete(ticket: ticket, at: nil) }
    }

    /// A positive system timestamp confirms a new picture; zero/nil means it was skipped or drawing failed.
    @discardableResult
    mutating func complete(ticket: Int, at time: Double?) -> Pending? {
        guard let index = pending.firstIndex(where: { $0.ticket == ticket }) else { return nil }
        let frame = pending.remove(at: index)
        guard let time, time > 0 else {
            dropped += 1
            return nil
        }
        shown += 1
        accumulatedDelay += max(0, time - frame.due)
        return frame
    }

    mutating func failedToEncode(newFrame: Bool) {
        if newFrame { dropped += 1 }
    }

    /// Old feedback cannot change the new stream's windows. GPU work is still in flight until its completion callback.
    mutating func flush() { pending.removeAll(keepingCapacity: true) }
}

/// The Metal renderer without the layer and the display link: decodes (``VideoDecoder``), keeps the decoded pictures in a
/// ``FrameQueue`` timed by ``FramePacer``, and at each refresh draws the frame the queue hands out (``MetalFrameDrawer``,
/// through the upscaler when it is on) and presents the drawable. `MetalRenderer` connects it to a `CAMetalLayer` and a
/// `CAMetalDisplayLink`; the replay tests connect it to a virtual clock and virtual refreshes.
///
/// At most two drawings' GPU work is in flight. A busy refresh leaves frames in the bounded queue rather than taking
/// and replacing them outside it. GPU completion releases this limit; selecting or scheduling a drawable does not
/// count as showing a picture. The upscaler's load is measured in one-second windows that report overload once per
/// stream and mode (nothing is changed automatically, and MetalFX Temporal's motion is computed for every frame).
/// A streak of 60 failed drawings switches the upscaler off for the stream (the picture is then drawn directly).
///
/// Three threads meet here: the core's video thread (`enqueue`, which hands the frame to the decoder's own thread), the
/// decoder's or VideoToolbox's (decoded pictures) and the display link's (`tick`); the queue and the counters are behind
/// one lock that is held for a few assignments only.
final class MetalPipeline: @unchecked Sendable {
    typealias Clock = @Sendable () -> Double

    /// A new picture confirmed by the display (or a completed offscreen drawing at its modeled refresh in tests).
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
        var accepting = true
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
        var presentation = FramePresentationLedger()
        var window = UpscalerWindowMeter()
        var overload = OverloadDetector()
        /// Modes (``UpscalerMode/index`` bits) whose overload was already reported in this stream.
        var overloadReported = 0
        /// Refreshes that drew nothing because two drawings' GPU work was still running while a frame waited.
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

        /// One finished load window: report an overload. Returns the mode to report, if any.
        mutating func onWindow(_ window: UpscalerWindow?) -> (UpscalerMode, Bool)? {
            guard let window else { return nil }
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

    /// What the pipeline calls back, in one struct and read as a whole: a function kept in a `Mutex` by itself is
    /// wrapped in two more conversion thunks every time `withLock` touches it (the lock hands its value out `inout`,
    /// and a function in generic storage is converted on the way out and again on the way back in), so a callback
    /// that was read once per frame became a chain thousands of calls deep within a minute.
    private struct Observers {
        var presented: (@Sendable (PresentedFrame) -> Void)?
        var conversion: (@Sendable (ColorConversion, HDRPictureInfo?) -> Void)?
        var overload: (@Sendable (UpscalerMode, Bool) -> Void)?
        var decoded: (@Sendable (CVPixelBuffer) -> Void)?
    }

    let drawer: MetalFrameDrawer
    private let clock: Clock
    private let state: Mutex<State>
    /// Serialize layer reattachment/flush with the drawer's mutable textures, separately from short counter locks.
    private let drawing = NSLock()
    /// Prevent a frame from being handed to the decoder after flush/invalidation has drained it.
    private let submissions = NSLock()
    /// `checkbox_enable_view_top_center`: a picture that leaves room is drawn at the top.
    private let topAligned: Bool
    private nonisolated(unsafe) var decoder: VideoDecoder!
    private let offscreen = Mutex<(any MTLTexture)?>(nil)
    /// The offscreen target's size when it is not the picture's (tests).
    private let offscreenSize = Mutex<(width: Int, height: Int)?>(nil)
    private let observers = Mutex(Observers())
    /// Debug builds: the per-second throughput line (``StreamPerf``).
    private let perf: StreamPerf?

    init?(
        pacing: FramePacing, fps: Int, options: VideoRenderOptions = VideoRenderOptions(),
        clock: @escaping Clock = { CACurrentMediaTime() }, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice(),
        metalFX: MetalFXSupport? = nil, perf: StreamPerf? = StreamPerf.standard
    ) {
        guard let drawer = MetalFrameDrawer(device: device, metalFX: metalFX, timed: perf != nil) else { return nil }
        self.drawer = drawer
        self.clock = clock
        self.perf = perf
        topAligned = options.topAligned
        state = Mutex(State(queue: FrameQueue(pacing: pacing, fps: fps), scaleMode: options.scaleMode, upscaler: options.upscaler))
        decoder = VideoDecoder(
            asynchronous: options.asyncDecode, perf: perf,
            onFrame: { [weak self] frame in self?.decoded(frame) },
            onFailure: { [weak self] _ in
                self?.perf?.decodeFailed()
                self?.state.withLock { $0.awaitingKeyFrame = true }
            })
    }

    /// Called for every new picture confirmed by presentation feedback, on the callback's thread.
    func observePresented(_ body: (@Sendable (PresentedFrame) -> Void)?) {
        observers.withLock { $0.presented = body }
    }

    /// Called when the pictures' colour description changes (and for the first picture), on the thread that draws.
    /// The HDR metadata of the pictures is reported with it.
    func observeConversion(_ body: (@Sendable (ColorConversion, HDRPictureInfo?) -> Void)?) {
        observers.withLock { $0.conversion = body }
    }

    /// Called with every decoded picture as VideoToolbox returns it, on its thread (Picture in Picture's copy of the
    /// stream, ``PictureInPictureVideo``).
    func observeDecoded(_ body: (@Sendable (CVPixelBuffer) -> Void)?) {
        observers.withLock { $0.decoded = body }
    }

    /// Called once per stream and mode when the upscaler could not keep up for about two seconds, with the mode and
    /// whether it was supersampling; on the thread that draws.
    func observeUpscalerOverload(_ body: (@Sendable (UpscalerMode, Bool) -> Void)?) {
        observers.withLock { $0.overload = body }
    }

    // MARK: Settings while the stream runs

    func setScaleMode(_ mode: VideoScaleMode) {
        state.withLock { $0.scaleMode = mode }
    }

    /// The stream menu's upscaler controls. Switching on after a failure tries again (Android `setUpscalingEnabled`).
    func setUpscaler(_ settings: UpscalerSettings) {
        state.withLock { s in
            if settings.enabled, !s.upscaler.enabled { s.upscalerFailed = false; s.upscalerFailures = 0 }
            if settings.mode != s.upscaler.mode { s.overload.reset() }
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

    func retime(fps: Int) {
        state.withLock { $0.queue.retime(fps: fps) }
    }

    /// The rate the display link asks for, for the throughput line.
    func setLinkFrameRate(_ rate: Double) {
        perf?.setLinkFrameRate(rate)
    }

    // MARK: Frames in

    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        submissions.lock()
        defer { submissions.unlock() }
        let keyFrame = Self.isKeyFrame(sample)
        let accepted = state.withLock { s in
            guard s.accepting else { return false }
            if s.awaitingKeyFrame {
                guard keyFrame else { return false }
                s.awaitingKeyFrame = false
            }
            return true
        }
        guard accepted else { return false }
        let submitted = decoder.decode(sample)
        if submitted { perf?.decodeSubmitted() }
        return submitted
    }

    static func isKeyFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return true }
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        return CFDictionaryGetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) == nil
    }

    private func decoded(_ frame: DecodedFrame) {
        let now = clock()
        let overflowed = state.withLock { s -> Int? in
            guard s.accepting else { return nil }
            let dropped = s.queue.counters.dropped
            s.queue.push(NumberedFrame(frame: frame, sequence: s.decoded, arrival: now), arrival: now)
            s.decoded += 1
            s.decodeSeconds += frame.decodeSeconds
            if s.upscalerActive { s.window.arrived(at: now) }
            return s.queue.counters.dropped - dropped
        }
        guard let overflowed else { return }
        if let perf {
            perf.decodeReturned(seconds: frame.decodeSeconds)
            perf.queued()
            perf.dropped(.queueFull, count: overflowed)
        }
        observers.withLock { $0 }.decoded?(frame.pixelBuffer)
    }

    func flush() {
        drawing.lock()
        defer { drawing.unlock() }
        submissions.lock()
        defer { submissions.unlock() }
        // Drain callbacks from the old session before clearing its pictures. discardPending alone leaves
        // asynchronous VideoToolbox frames able to enter the freshly flushed queue.
        decoder.invalidate()
        state.withLock { s in
            s.queue.flush()
            s.lastFrame = nil
            s.awaitingKeyFrame = true
            s.presentation.flush()
            s.lastDrawnSize = (0, 0)
            s.posedOnScreen = false
        }
    }

    /// Blocks until the frames submitted so far are decoded and queued (replay tests only).
    func waitForDecodes() {
        decoder.finishFrames()
    }

    func invalidate() {
        drawing.lock()
        defer { drawing.unlock() }
        submissions.lock()
        defer { submissions.unlock() }
        state.withLock { s in
            s.accepting = false
            s.queue.flush()
            s.lastFrame = nil
            s.presentation.flush()
        }
        decoder.invalidate()
    }

    // MARK: Refreshes

    /// Shows the frame due at this refresh, if there is one. While two drawings' GPU work is still running nothing is
    /// drawn and the frames wait in the queue for the next refresh. While the arrival runs the last frame is drawn again
    /// at every refresh with the pose of that refresh's time, and once it ends the last frame is drawn plainly once more,
    /// so a still picture settles too and the stream goes on exactly as without it.
    func tick(_ tick: RefreshTick) {
        drawing.lock()
        defer { drawing.unlock() }
        guard state.withLock({ $0.accepting }) else { return }
        let size = tick.drawable.map { (width: $0.texture.width, height: $0.texture.height) }
        let now = clock()
        var report: (UpscalerMode, Bool)?
        var refresh = StreamPerf.Refresh(
            presentation: tick.presentation, lead: tick.presentation - now, budget: tick.deadline.map { $0 - now })
        var skipped = 0
        let work = state.withLock { s -> Work? in
            let pose = s.arrivalPose(at: tick.presentation)
            let upscaling = s.upscalerActive
            let before = s.queue.counters
            refresh.waiting = s.queue.waiting
            defer {
                let after = s.queue.counters
                refresh.selected = after.presented > before.presented
                refresh.repeated = after.repeatedRefreshes > before.repeatedRefreshes
                skipped = after.dropped - before.dropped
            }
            if !s.presentation.canDraw {
                s.queue.idle()
                if refresh.waiting > 0 {
                    refresh.gpuBusy = true
                    s.gpuBusySkipped += 1
                    if upscaling { report = s.onWindow(s.window.busySkipped(at: now)) }
                }
                return nil
            }
            let taken = s.queue.take(at: tick.presentation, refresh: tick.refresh)
            func upscale(_ frame: NumberedFrame) -> UpscaleRequest? {
                guard upscaling else { return nil }
                return UpscaleRequest(settings: s.upscaler, sequence: frame.sequence, frameTime: frame.arrival)
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
        if let perf {
            perf.tick(refresh)
            perf.dropped(.skipped, count: skipped)
        }
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
        observers.withLock { $0 }.overload?(report.0, report.1)
    }

    private func draw(_ work: Work, tick: RefreshTick, now: Double) {
        let numbered = work.frame
        let pixelBuffer = numbered.frame.pixelBuffer
        guard let conversion = ColorConversion(pixelBuffer: pixelBuffer),
              let commandBuffer = drawer.queue.makeCommandBuffer() else {
            drawingFailed(work)
            return
        }
        let hdrInfo = conversion.isHDR ? HDRPictureInfo(pixelBuffer: pixelBuffer) : nil
        let changed = state.withLock { s -> Bool in
            defer { s.lastConversion = conversion; s.lastHDRInfo = hdrInfo }
            return s.lastConversion != conversion || s.lastHDRInfo != hdrInfo
        }
        if changed { observers.withLock { $0 }.conversion?(conversion, hdrInfo) }
        let target: any MTLTexture
        if let drawable = tick.drawable {
            target = drawable.texture
        } else if let texture = offscreenTexture(
            width: offscreenSize.withLock({ $0?.width }) ?? CVPixelBufferGetWidth(pixelBuffer),
            height: offscreenSize.withLock({ $0?.height }) ?? CVPixelBufferGetHeight(pixelBuffer)) {
            target = texture
        } else {
            drawingFailed(work)
            return
        }
        let drawn = drawer.draw(
            pixelBuffer, conversion: conversion, into: target, commandBuffer: commandBuffer, arrival: work.pose,
            scaleMode: work.scaleMode, topAligned: topAligned, upscale: work.upscale)
        guard afterDrawing(drawn: drawn, upscaled: work.upscale != nil, report: drawer.lastReport, commandBuffer: commandBuffer, now: now)
        else {
            drawingFailed(work)
            return
        }
        let timing = FrameDrawingTiming(
            callback: now, presentation: tick.presentation, submissionDeadline: tick.deadline)
        let onDisplay = tick.drawable != nil
        #if targetEnvironment(simulator)
        // Simulator drawables expose no presentedTime. Only offscreen tests have an explicitly modeled presentation.
        let due = onDisplay ? nil : work.due
        #else
        let due = work.due
        #endif
        let ticket = state.withLock {
            $0.presentation.submitted(sequence: numbered.sequence, due: due, decodedAt: numbered.arrival)
        }
        if let drawable = tick.drawable {
            #if !targetEnvironment(simulator)
            drawable.addPresentedHandler { [weak self, perf] shown in
                let time = shown.presentedTime
                let confirmed = self?.drawingPresented(ticket: ticket, at: time, onDisplay: true) ?? false
                perf?.presented(offset: time > 0 ? time - timing.presentation : nil, newFrame: confirmed)
            }
            #endif
            // Timed-present variants assert with display-link drawables. The link owns the presentation schedule.
            commandBuffer.present(drawable)
        }
        nonisolated(unsafe) let parts = work.upscale == nil ? nil : drawer.lastReport.map { ($0.preparation, $0.pass) }
        let mode = work.upscale == nil ? nil : drawer.lastReport?.mode
        let passes = drawer.lastPasses, timer = drawer.passTimer
        commandBuffer.addCompletedHandler { [weak self, perf] buffer in
            let succeeded = buffer.status == .completed
            let late = succeeded && onDisplay && timing.gpuFinishedLate(at: buffer.gpuEndTime)
            self?.state.withLock { s in
                s.presentation.gpuCompleted(ticket: ticket, succeeded: succeeded)
                if late { s.lateRefreshes += 1 }
            }
            guard let perf else { return }
            func seconds(_ part: (any MTLCommandBuffer)?) -> Double {
                guard let part, part.status == .completed else { return 0 }
                return part.gpuEndTime - part.gpuStartTime
            }
            let total = buffer.gpuEndTime - buffer.gpuStartTime + seconds(parts?.0) + seconds(parts?.1)
            perf.gpuFinished(
                seconds: total, late: late, failed: !succeeded, upscaler: mode,
                passes: succeeded ? passes.flatMap { timer?.times(of: $0) } : nil)
        }
        commandBuffer.commit()
        let submitted = clock()
        perf?.drawingSubmitted(
            seconds: submitted - timing.callback, late: onDisplay && timing.submittedLate(at: submitted))
        if !onDisplay {
            commandBuffer.waitUntilCompleted()
            _ = drawingPresented(
                ticket: ticket, at: commandBuffer.status == .completed ? tick.presentation : 0, onDisplay: false)
        }
    }

    private func drawingFailed(_ work: Work) {
        state.withLock { $0.presentation.failedToEncode(newFrame: work.due != nil) }
        perf?.drawingFailed()
    }

    /// Returns whether a new frame was confirmed, not a resize/animation redraw or stale feedback after a flush.
    @discardableResult
    private func drawingPresented(ticket: Int?, at time: Double, onDisplay: Bool) -> Bool {
        guard let ticket else { return false }
        let frame = state.withLock { s -> PresentedFrame? in
            guard let frame = s.presentation.complete(ticket: ticket, at: time) else { return nil }
            s.frameTimes.add(time)
            if onDisplay { s.renderLatency.record(time - frame.decodedAt) }
            return PresentedFrame(sequence: frame.sequence, due: frame.due, presentation: time)
        }
        guard let frame else { return false }
        observers.withLock { $0 }.presented?(frame)
        return true
    }

    /// Books a drawing: the upscaler's failures and its load windows. False when nothing was drawn.
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
                totalFrames: s.presentation.shown + s.presentation.dropped + queue.dropped,
                droppedFrames: s.presentation.dropped + queue.dropped,
                accumulatedDelaySeconds: s.presentation.accumulatedDelay, decodedFrames: s.decoded,
                accumulatedDecodeSeconds: s.decodeSeconds, refreshes: queue.refreshes,
                repeatedRefreshes: queue.repeatedRefreshes, waitingSum: queue.waitingSum, peakWaiting: queue.peakWaiting,
                lateRefreshes: s.lateRefreshes)
            counters.onePercentLowFPS = s.frameTimes.onePercentLowFPS
            counters.renderLatency = s.renderLatency.summarize()
            counters.vrr = s.vrr
            counters.gpuBusySkipped = s.gpuBusySkipped
            let sharpen = s.sharpen.summarize()
            if let report = s.upscaledOnScreen {
                counters.upscalingMilliseconds = s.upscalerMilliseconds
                counters.upscale = UpscalerSizes(report)
                counters.sharpen = report.mode == .sharpen ? sharpen : nil
            }
            return counters
        }
    }
}
