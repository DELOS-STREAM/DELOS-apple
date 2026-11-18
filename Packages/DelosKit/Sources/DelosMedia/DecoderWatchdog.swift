import CoreMedia
import QuartzCore
import Foundation
import Synchronization

/// Actual presentation telemetry, never enqueue/decode submission counts. Metal renderers can adopt this additively.
public protocol VideoPresentationProgress: Sendable {
    func presentationCounters() async -> VideoPresentationCounters?
}

/// Five seconds of arriving frames without presentation progress. Network silence is not a decoder failure.
public struct DecoderWatchdog: Sendable {
    private let timeout: UInt64
    private var previousArrival: UInt64?
    private var previousPresentation: Int?
    private var previousTime: UInt64?
    private var stalledSince: UInt64?

    public init(timeoutNanoseconds: UInt64 = 5_000_000_000) { timeout = timeoutNanoseconds }
    public mutating func reset() {
        previousArrival = nil; previousPresentation = nil; previousTime = nil; stalledSince = nil
    }
    /// Returns true once per timeout while an observable presentation stall continues.
    public mutating func observe(arrivedFrames: UInt64, presentedFrames: Int?, now: UInt64) -> Bool {
        defer { previousArrival = arrivedFrames; previousPresentation = presentedFrames; previousTime = now }
        guard let presentedFrames, presentedFrames >= 0,
              let oldArrival = previousArrival, let oldPresentation = previousPresentation,
              let oldTime = previousTime, now >= oldTime,
              arrivedFrames >= oldArrival, presentedFrames >= oldPresentation else {
            stalledSince = previousArrival == nil && arrivedFrames > 0 && presentedFrames == 0 ? now : nil
            return false
        }
        guard arrivedFrames > oldArrival, presentedFrames == oldPresentation else {
            stalledSince = nil
            return false
        }
        let start = stalledSince ?? now
        stalledSince = start
        guard now - start >= timeout else { return false }
        stalledSince = now
        return true
    }
}

/// A decorator: all flushes/IDR answers remain on the core video thread; no work is allocated per frame.
public final class WatchdogVideoRenderer: VideoRenderer {
    private struct State: Sendable {
        var arrivals: UInt64 = 0
        var policy = DecoderWatchdog()
        var recoveryPending = false
        var presentedFrames: Int?
    }
    private let renderer: any VideoRenderer
    private let state = Mutex(State())

    public init(renderer: any VideoRenderer) {
        self.renderer = renderer
    }

    public func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let recover = state.withLock { s in
            s.arrivals &+= 1
            guard s.recoveryPending else { return false }
            s.recoveryPending = false
            s.policy.reset()
            return true
        }
        if recover {
            renderer.flush()
            // VideoOutput maps false to DR_NEED_IDR: the core requests a fresh reference chain from the host.
            return false
        }
        return renderer.enqueue(sample)
    }
    public func setHDR(_ active: Bool) { renderer.setHDR(active) }
    public func flush() {
        state.withLock { $0 = State() }
        renderer.flush()
    }

    // The rest is the wrapped renderer's: the view and the statistics talk to the original, the decorator only sits on
    // the core's video thread.
    public var name: String { renderer.name }
    public func presentationCounters() async -> VideoPresentationCounters? { await renderer.presentationCounters() }
    @MainActor public var hostLayer: CALayer { renderer.hostLayer }
    @MainActor public func resize(to bounds: CGRect, scale: CGFloat) { renderer.resize(to: bounds, scale: scale) }
    @MainActor public func attached(to display: VideoDisplay) -> DisplayRefreshPlanner.Plan { renderer.attached(to: display) }
    @MainActor public func detached() { renderer.detached() }
    public func startArrival(duration: Double) { renderer.startArrival(duration: duration) }
    public func cancelArrival() { renderer.cancelArrival() }
    public func setScaleMode(_ mode: VideoScaleMode) { renderer.setScaleMode(mode) }
    public func setUpscaler(_ settings: UpscalerSettings) { renderer.setUpscaler(settings) }
    public var upscalerSettings: UpscalerSettings { renderer.upscalerSettings }
    public var upscalerStatus: UpscalerStatus { renderer.upscalerStatus }
    public var isSupersampling: Bool { renderer.isSupersampling }
    public func observeUpscalerOverload(_ body: (@Sendable (UpscalerMode, Bool) -> Void)?) { renderer.observeUpscalerOverload(body) }

    func observe(_ counters: VideoPresentationCounters?, now: UInt64) {
        let displayed = counters.flatMap { value -> Int? in
            guard value.totalFrames >= 0, value.droppedFrames >= 0, value.totalFrames >= value.droppedFrames else { return nil }
            return value.totalFrames - value.droppedFrames
        }
        state.withLock { s in
            if let displayed, let previous = s.presentedFrames, displayed != previous {
                s.recoveryPending = false
            }
            s.presentedFrames = displayed
            if s.policy.observe(arrivedFrames: s.arrivals, presentedFrames: displayed, now: now) {
                s.recoveryPending = true
            }
        }
    }
}
