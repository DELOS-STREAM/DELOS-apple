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
/// ``FrameQueue`` timed by ``FramePacer``, and at each refresh draws the frame the queue hands out (``MetalFrameDrawer``)
/// and presents the drawable. `MetalRenderer` connects it to a `CAMetalLayer` and a `CAMetalDisplayLink`; the
/// replay tests connect it to a virtual clock and virtual refreshes.
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
    }

    private struct NumberedFrame {
        var frame: DecodedFrame
        var sequence: Int
    }

    let drawer: MetalFrameDrawer
    private let clock: Clock
    private let state: Mutex<State>
    private nonisolated(unsafe) var decoder: VideoDecoder!
    private let offscreen = Mutex<(any MTLTexture)?>(nil)
    private let observer = Mutex<(@Sendable (PresentedFrame) -> Void)?>(nil)
    private let conversionChanged = Mutex<(@Sendable (ColorConversion, HDRPictureInfo?) -> Void)?>(nil)

    init?(pacing: FramePacing, fps: Int, clock: @escaping Clock = { CACurrentMediaTime() }, device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let drawer = MetalFrameDrawer(device: device) else { return nil }
        self.drawer = drawer
        self.clock = clock
        state = Mutex(State(queue: FrameQueue(pacing: pacing, fps: fps)))
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
            s.queue.push(NumberedFrame(frame: frame, sequence: s.decoded), arrival: now)
            s.decoded += 1
            s.decodeSeconds += frame.decodeSeconds
        }
    }

    func flush() {
        state.withLock { s in
            s.queue.flush()
            s.lastFrame = nil
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
    /// so a still picture settles too and the stream goes on exactly as without it.
    func tick(_ tick: RefreshTick) {
        let size = tick.drawable.map { (width: $0.texture.width, height: $0.texture.height) }
        let work = state.withLock { s -> (frame: NumberedFrame, due: Double?, pose: ArrivalPose?)? in
            let pose = s.arrivalPose(at: tick.presentation)
            if let taken = s.queue.take(at: tick.presentation, refresh: tick.refresh) {
                s.lastFrame = taken.frame
                s.lastDrawnSize = size ?? (0, 0)
                s.posedOnScreen = pose != nil
                return (taken.frame, taken.due, pose)
            }
            // No new picture: the layer keeps the last one, unless the layer's size changed or the arrival moves it
            guard let last = s.lastFrame else { return nil }
            let resized = size.map { $0 != s.lastDrawnSize } ?? false
            guard resized || pose != nil || s.posedOnScreen else { return nil }
            if let size { s.lastDrawnSize = size }
            s.posedOnScreen = pose != nil
            return (last, nil, pose)
        }
        guard let work else { return }
        draw(work.frame, tick: tick, presented: work.due != nil, due: work.due ?? tick.presentation, arrival: work.pose)
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

    private func draw(_ numbered: NumberedFrame, tick: RefreshTick, presented: Bool, due: Double, arrival: ArrivalPose?) {
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
        } else if let texture = offscreenTexture(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)) {
            target = texture
        } else {
            return
        }
        guard drawer.draw(pixelBuffer, conversion: conversion, into: target, commandBuffer: commandBuffer, arrival: arrival) else { return }
        if let drawable = tick.drawable {
            commandBuffer.present(drawable)
            // The drawing must be done by the time of the refresh it is for; the system's own presented time is not in
            // the iOS SDK. GPU end time and presentation time are on the same clock (seconds of mach absolute time)
            let presentation = tick.presentation
            commandBuffer.addCompletedHandler { [weak self] buffer in
                if buffer.gpuEndTime > presentation { self?.state.withLock { $0.lateRefreshes += 1 } }
            }
        }
        commandBuffer.commit()
        if tick.drawable == nil { commandBuffer.waitUntilCompleted() }
        if presented, let body = observer.withLock({ $0 }) {
            body(PresentedFrame(sequence: numbered.sequence, due: due, presentation: tick.presentation))
        }
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

    /// The cumulative counters; the queue's peak is the peak since the previous call.
    func counters() -> VideoPresentationCounters {
        state.withLock { s in
            let queue = s.queue.counters
            defer { s.queue.resetPeak() }
            return VideoPresentationCounters(
                totalFrames: queue.presented + queue.dropped, droppedFrames: queue.dropped,
                accumulatedDelaySeconds: queue.accumulatedLateness, decodedFrames: s.decoded,
                accumulatedDecodeSeconds: s.decodeSeconds, refreshes: queue.refreshes,
                repeatedRefreshes: queue.repeatedRefreshes, waitingSum: queue.waitingSum, peakWaiting: queue.peakWaiting,
                lateRefreshes: s.lateRefreshes)
        }
    }
}
