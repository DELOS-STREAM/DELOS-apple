import DelosCore
import Foundation
import os
import Synchronization

/// The video path's throughput, stage by stage, in debug builds: once a second one line under the os_log category
/// `StreamPerf` (subsystem `io.github.meitoncz.delos`) and in the diagnostic log, so a device console tells where frames go
/// missing: the host (`host`), the network (`in`, `gap`, `fecfail`, `oos`), the core's receive thread (`submit`), the
/// decoder (`dec`, `decq`, `dect`), the queue (`drop`, `repeat`, `wait`), the display link (`tick`, `tickhz`, `lead`,
/// `budget`), the GPU (`gpu`, `late`, `over` and the passes) or the system's presentation (`glass`, `lost`, `off`).
/// One-off lines (``note(_:)``) say what the launch asked for and how the display was planned. Nothing is counted in
/// release builds.
///
///     StreamPerf req=120 link=120 in=119.8 gap=0 host=120.0 mbps=38.2 fecfail=0 oos=0 asm=0.90/2.10 submit=0.08/0.30/0.90 dec=120/120 decfail=0 decq=1 dect=3.10/4.00 queue=120 selected=120 shown=120 draw=120 drawfail=0 drop=0 full=0 skip=0 gpu-busy=0 repeat=0 wait=0.40 tick=120 tickhz=120.0 lead=16.60 budget=8.30 encode=0.40/0.60 over=0 gpu=0.40/0.60 gpufail=0 late=0 up=off conv=- flow=- fx=- sharp=- present=0.30/0.50 rest=0.05/0.10 glass=120 lost=0 off=0.02/0.10 thermal=nominal lpm=0
///
/// - `req`: the frame rate the stream negotiated; `link`: the rate the display link asks for.
/// - `in`: frames per second from the core; `gap`: frame numbers that never arrived; `host`: the rate the host encoded at
///   (frame numbers over its presentation times); `fecfail`, `oos`: FEC blocks lost beyond repair and packets out of order.
/// - `asm`: first packet to complete frame in the core; `submit`: the receive thread's time per frame in the video output.
/// - `dec`: frames handed to / returned by the decoder; `decq`: most frames waiting for its thread; `dect`: its time.
/// - `queue`: decoded frames queued; `selected`: new frames taken from the queue; `shown`: new frames confirmed by a
///   positive system `presentedTime`, excluding animation/resize redraws. An offscreen drawing is not shown.
///   `draw` counts submitted drawings, `drawfail` failed encoding; `drop` (`full`, `skip`) counts queue discards.
///   `gpu-busy` counts callbacks blocked by two drawings in flight; `repeat` counts callbacks selecting no new frame
///   after the first selection, not an observation of scanout; `wait` is the mean queued count at a callback.
/// - `tick`, `tickhz`: display link callbacks and their measured rate; `lead`: from the callback to the time its picture
///   is estimated to appear; `budget`: callback to the CPU submission deadline (`targetTimestamp`), both medians.
/// - `encode`: callback to command-buffer submission; `over`: submissions after `targetTimestamp`. The GPU may
///   continue after that deadline; crossing it is not itself a GPU deadline miss.
/// - `gpu`: summed command-buffer GPU durations, including intervening contention, not necessarily active shader time;
///   `gpufail`: failed command buffers; `late`: GPU completion after the estimated presentation time.
/// - `up`: the upscaler that drew (`off`, `spatial`, `temporal`, `sharpen`). The drawing's passes (``GPUPassTimer``):
///   `conv` the conversion to RGB, `flow` optical flow, `sharp` Sharpen only, `present` the pass into the drawable.
///   Render samples cover the fragment stage, not the entire render pass. `fx` and `rest` are unclassified residual
///   command-buffer time with/without MetalFX respectively, not measurements of MetalFX cost or compositor work.
/// - `glass`: drawable callbacks with a positive system timestamp, including redraws; `lost`: callbacks reporting no
///   presentation; `off`: observed minus estimated presentation time. Simulators expose no presented time.
///
/// `p50/p99` (and `/max` for `submit`) are milliseconds over the second; `-` means no value. Every recording takes one
/// short lock.
public final class StreamPerf: Sendable {
    /// What a stream records into: an instance in debug builds, nil in release builds.
    public static let standard: StreamPerf? = {
        #if DEBUG
        StreamPerf()
        #else
        nil
        #endif
    }()

    /// Why a decoded frame was never shown.
    enum Drop {
        /// The queue was full when a newer frame arrived (it held ``FrameQueue/capacity`` frames already).
        case queueFull
        /// More than the backlog waited at one refresh: the queue skipped ahead.
        case skipped
    }

    /// Up to `capacity` values of one second; the storage is kept from second to second, so it grows only at first.
    struct Samples {
        private(set) var values: [Double] = []
        static let capacity = 1024

        mutating func add(_ value: Double) {
            if values.count < Self.capacity { values.append(value) }
        }

        mutating func reset() { values.removeAll(keepingCapacity: true) }

        /// The value below which `fraction` of the samples lie (nearest rank); nil without samples.
        static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let rank = Int((Double(sorted.count) * fraction).rounded(.up)) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
    }

    /// One second of counts.
    struct Window {
        var received = 0
        var bytes = 0
        var gaps = 0
        var lastFrameNumber: Int?
        /// The first and last frame of the second with a host time: frame numbers over host time are the rate the host
        /// encoded at, whatever the network lost.
        var firstHost: (number: Int, timeUs: UInt64)?
        var lastHost: (number: Int, timeUs: UInt64)?
        var assemble = Samples()
        var submit = Samples()
        var decodeSubmitted = 0
        var decodeReturned = 0
        var decodeFailed = 0
        var decodeWaiting = 0
        var decode = Samples()
        var queued = 0
        var selected = 0
        var shown = 0
        var drawings = 0
        var drawingFailures = 0
        var encode = Samples()
        var droppedFull = 0
        var droppedSkipped = 0
        var busyRefreshes = 0
        var repeated = 0
        var waitingSum = 0
        var ticks = 0
        var firstTick: Double?
        var lastTick: Double?
        var lead = Samples()
        var budget = Samples()
        var gpu = Samples()
        var gpuFailures = 0
        var late = 0
        var over = 0
        /// The passes by ``GPUPass``'s order, then `fx` and `rest`.
        var passes = [Samples](repeating: Samples(), count: GPUPass.allCases.count + 2)
        var onGlass = 0
        var neverShown = 0
        var offTarget = Samples()

        var isEmpty: Bool {
            received == 0 && ticks == 0 && decodeReturned == 0 && drawings == 0 && drawingFailures == 0
                && gpu.values.isEmpty && gpuFailures == 0 && onGlass == 0 && neverShown == 0
        }

        /// Keeps the sample storage and the frame number the next window continues from.
        mutating func reset() {
            var next = Window(lastFrameNumber: lastFrameNumber)
            next.assemble = assemble; next.submit = submit; next.decode = decode; next.lead = lead; next.budget = budget
            next.gpu = gpu; next.passes = passes; next.offTarget = offTarget; next.encode = encode
            next.assemble.reset(); next.submit.reset(); next.decode.reset(); next.lead.reset(); next.budget.reset()
            next.gpu.reset(); next.offTarget.reset(); next.encode.reset()
            for index in next.passes.indices { next.passes[index].reset() }
            self = next
        }
    }

    private struct State {
        var window = Window()
        /// When the window began (uptime nanoseconds).
        var windowStart: UInt64 = 0
        var requestedFPS = 0
        var linkFrameRate = 0.0
        /// The upscaler of the last drawing; nil: drawn directly.
        var upscaler: UpscalerMode?
        var timer: (any DispatchSourceTimer)?
        /// The core's packet counters at the last line (cumulative since the connection started).
        var lastPackets: RTPStatistics?
        /// The core's video packet counters of the running stream (`LiGetRTPVideoStats`); nil until a stream sets it.
        /// In the state, not in a `Mutex` of its own: a function alone in one is wrapped again at every `withLock`.
        var packetSource: (@Sendable () -> RTPStatistics?)?
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.github.meitoncz.delos.streamperf", qos: .utility)
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "StreamPerf")
    /// Where the lines go: the console and the diagnostic log (tests take them instead).
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void = StreamPerf.log) {
        self.emit = emit
    }

    static func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        DiagLog.d("StreamPerf", line)
    }

    /// A one-off line about the stream (what the launch asked for, the display plan): "StreamPerf <text>".
    public func note(_ text: String) {
        emit("StreamPerf \(text)")
    }

    /// The upscaler settings in the words of the launch line: `upscaler=off` or the mode, its sharpness and its
    /// supersampling level.
    public static func launchText(_ upscaler: UpscalerSettings) -> String {
        "upscaler=\(upscaler.enabled ? name(upscaler.mode) : "off") sharpness=\(upscaler.sharpness) "
            + "supersampling=\(upscaler.supersamplingLevel)"
    }

    /// Where the per-second line reads the core's packet counters (FEC failures and reordering on the network).
    public func setPacketSource(_ source: (@Sendable () -> RTPStatistics?)?) {
        state.withLock { $0.packetSource = source }
    }

    // MARK: The stream

    /// A stream starts: `fps` is the frame rate the host was asked for. Starts the line once a second.
    func begin(requestedFPS fps: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.flush() }
        let previous = state.withLock { s -> (any DispatchSourceTimer)? in
            defer {
                s.window = Window()
                s.windowStart = DispatchTime.now().uptimeNanoseconds
                s.requestedFPS = fps
                s.upscaler = nil
                s.timer = timer
                s.lastPackets = nil
            }
            return s.timer
        }
        previous?.cancel()
        timer.resume()
    }

    /// The stream ended: the last partial second is logged and the line stops.
    func end() {
        let timer = state.withLock { s -> (any DispatchSourceTimer)? in
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
        queue.async { [self] in flush() }
    }

    /// The rate the display link was asked for (the refresh plan's surface frame rate).
    func setLinkFrameRate(_ rate: Double) {
        state.withLock { $0.linkFrameRate = rate }
    }

    // MARK: Recording

    /// A frame came from the core. `frameNumber` the host's; the times are the core's microseconds (first packet, frame
    /// complete) and the host's presentation time.
    func received(frameNumber: Int, bytes: Int, firstPacketUs: UInt64, completeUs: UInt64, hostTimeUs: UInt64) {
        state.withLock { s in
            s.window.received += 1
            s.window.bytes += bytes
            if let last = s.window.lastFrameNumber, frameNumber > last + 1 { s.window.gaps += frameNumber - last - 1 }
            s.window.lastFrameNumber = frameNumber
            if completeUs >= firstPacketUs, firstPacketUs > 0 {
                s.window.assemble.add(Double(completeUs - firstPacketUs) / 1000)
            }
            if hostTimeUs > 0 {
                if s.window.firstHost == nil { s.window.firstHost = (frameNumber, hostTimeUs) }
                s.window.lastHost = (frameNumber, hostTimeUs)
            }
        }
    }

    /// The core's thread spent `seconds` in the video output with the frame (copy, parse, hand to the decoder).
    func submitted(seconds: Double) {
        state.withLock { $0.window.submit.add(seconds * 1000) }
    }

    func decodeSubmitted() {
        state.withLock { $0.window.decodeSubmitted += 1 }
    }

    func decodeReturned(seconds: Double) {
        state.withLock { s in
            s.window.decodeReturned += 1
            s.window.decode.add(seconds * 1000)
        }
    }

    /// `count` frames wait for the decoder's thread now (the one just handed over included).
    func decodeWaiting(_ count: Int) {
        state.withLock { $0.window.decodeWaiting = max($0.window.decodeWaiting, count) }
    }

    func decodeFailed() {
        state.withLock { $0.window.decodeFailed += 1 }
    }

    /// A decoded frame entered the queue.
    func queued() {
        state.withLock { $0.window.queued += 1 }
    }

    func dropped(_ reason: Drop, count: Int = 1) {
        guard count > 0 else { return }
        state.withLock { s in
            switch reason {
            case .queueFull: s.window.droppedFull += count
            case .skipped: s.window.droppedSkipped += count
            }
        }
    }

    /// What one refresh of the display link did.
    struct Refresh {
        /// When its picture appears (seconds).
        var presentation: Double
        /// A new frame was selected; drawing and actual presentation have not been confirmed.
        var selected = false
        /// The previous picture stays (after the first one was shown).
        var repeated = false
        /// A frame waited, and nothing was drawn because two frames of GPU work were still running.
        var gpuBusy = false
        /// Frames in the queue when the callback came.
        var waiting = 0
        /// Seconds from the callback to `presentation`.
        var lead: Double?
        /// Seconds from the callback to the display link's deadline for the drawing.
        var budget: Double?
    }

    /// A refresh of the display link.
    func tick(_ refresh: Refresh) {
        state.withLock { s in
            s.window.ticks += 1
            if s.window.firstTick == nil { s.window.firstTick = refresh.presentation }
            s.window.lastTick = refresh.presentation
            if refresh.selected { s.window.selected += 1 }
            if refresh.repeated { s.window.repeated += 1 }
            if refresh.gpuBusy { s.window.busyRefreshes += 1 }
            s.window.waitingSum += refresh.waiting
            if let lead = refresh.lead { s.window.lead.add(lead * 1000) }
            if let budget = refresh.budget { s.window.budget.add(budget * 1000) }
        }
    }

    /// CPU encoding/submission, measured separately from the GPU and system presentation.
    func drawingSubmitted(seconds: Double, late: Bool) {
        state.withLock { s in
            s.window.drawings += 1
            s.window.encode.add(max(0, seconds) * 1000)
            if late { s.window.over += 1 }
        }
    }

    func drawingFailed() {
        state.withLock { $0.window.drawingFailures += 1 }
    }

    /// GPU completion. The CPU submission deadline is not a GPU deadline.
    func gpuFinished(seconds: Double, late: Bool, failed: Bool = false, upscaler: UpscalerMode? = nil, passes: GPUPassTimes? = nil) {
        state.withLock { s in
            guard !failed else {
                s.window.gpuFailures += 1
                return
            }
            s.window.gpu.add(seconds * 1000)
            if late { s.window.late += 1 }
            s.upscaler = upscaler
            guard let passes else { return }
            for pass in GPUPass.allCases {
                if let time = passes[pass] { s.window.passes[pass.rawValue].add(time * 1000) }
            }
            // Residual time is not attributable: it can include unsampled stages, MetalFX and GPU contention.
            let metalFX = upscaler == .spatial || upscaler == .temporal
            s.window.passes[GPUPass.allCases.count + (metalFX ? 0 : 1)].add(max(0, seconds - passes.total) * 1000)
        }
    }

    /// The system reported a presented drawable: `offset` is the time it appeared minus the time the display link asked
    /// for, nil when it was never shown.
    func presented(offset: Double?, newFrame: Bool) {
        state.withLock { s in
            guard let offset else {
                s.window.neverShown += 1
                return
            }
            s.window.onGlass += 1
            if newFrame { s.window.shown += 1 }
            s.window.offTarget.add(offset * 1000)
        }
    }

    // MARK: The line

    /// Logs the window that ended and starts the next one (skipped when nothing happened in it). `seconds`: the window's
    /// length, measured when nil.
    func flush(seconds: Double? = nil, thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
               lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) {
        let packets = state.withLock { $0.packetSource }?() ?? nil
        let now = DispatchTime.now().uptimeNanoseconds
        let (window, length, fps, link, upscaler, lastPackets) = state.withLock {
            s -> (Window, Double, Int, Double, UpscalerMode?, RTPStatistics?) in
            defer {
                s.window.reset()
                s.windowStart = now
                if let packets { s.lastPackets = packets }
            }
            let measured = s.windowStart > 0 && now > s.windowStart ? Double(now - s.windowStart) / 1_000_000_000 : 1
            return (s.window, seconds ?? measured, s.requestedFPS, s.linkFrameRate, s.upscaler, s.lastPackets)
        }
        guard !window.isEmpty else { return }
        var network: (fecFailed: Int, outOfSequence: Int)?
        if let packets {
            network = (Int(packets.fecFailed &- (lastPackets?.fecFailed ?? 0)),
                       Int(packets.outOfSequence &- (lastPackets?.outOfSequence ?? 0)))
        }
        emit(Self.line(
            window, seconds: length, requestedFPS: fps, linkFrameRate: link, upscaler: upscaler, network: network,
            thermal: thermal, lowPower: lowPower))
    }

    static func line(
        _ w: Window, seconds: Double, requestedFPS: Int, linkFrameRate: Double, upscaler: UpscalerMode? = nil,
        network: (fecFailed: Int, outOfSequence: Int)?, thermal: ProcessInfo.ThermalState, lowPower: Bool
    ) -> String {
        func rate(_ count: Int) -> String { String(format: "%.1f", Double(count) / seconds) }
        func times(_ samples: Samples, max: Bool = false) -> String {
            let sorted = samples.values.sorted()
            guard let p50 = Samples.percentile(sorted, 0.5), let p99 = Samples.percentile(sorted, 0.99) else { return "-" }
            return max ? String(format: "%.2f/%.2f/%.2f", p50, p99, sorted[sorted.count - 1]) : String(format: "%.2f/%.2f", p50, p99)
        }
        func median(_ samples: Samples) -> String {
            Samples.percentile(samples.values.sorted(), 0.5).map { String(format: "%.2f", $0) } ?? "-"
        }
        var host = "-"
        if let first = w.firstHost, let last = w.lastHost, last.timeUs > first.timeUs, last.number > first.number {
            host = String(format: "%.1f", Double(last.number - first.number) * 1_000_000 / Double(last.timeUs - first.timeUs))
        }
        var tickRate = "-"
        if let first = w.firstTick, let last = w.lastTick, last > first, w.ticks > 1 {
            tickRate = String(format: "%.1f", Double(w.ticks - 1) / (last - first))
        }
        let waiting = w.ticks > 0 ? String(format: "%.2f", Double(w.waitingSum) / Double(w.ticks)) : "-"
        func pass(_ pass: GPUPass) -> String { times(w.passes[pass.rawValue]) }
        let extra = GPUPass.allCases.count
        return "StreamPerf req=\(requestedFPS) link=\(Int(linkFrameRate.rounded())) in=\(rate(w.received)) gap=\(w.gaps) host=\(host) "
            + "mbps=\(String(format: "%.1f", Double(w.bytes) * 8 / 1_000_000 / seconds)) "
            + "fecfail=\(network.map { "\($0.fecFailed)" } ?? "-") oos=\(network.map { "\($0.outOfSequence)" } ?? "-") "
            + "asm=\(times(w.assemble)) submit=\(times(w.submit, max: true)) dec=\(w.decodeSubmitted)/\(w.decodeReturned) "
            + "decfail=\(w.decodeFailed) decq=\(w.decodeWaiting) dect=\(times(w.decode)) queue=\(w.queued) "
            + "selected=\(w.selected) shown=\(w.shown) draw=\(w.drawings) drawfail=\(w.drawingFailures) "
            + "drop=\(w.droppedFull + w.droppedSkipped) full=\(w.droppedFull) skip=\(w.droppedSkipped) "
            + "gpu-busy=\(w.busyRefreshes) repeat=\(w.repeated) wait=\(waiting) "
            + "tick=\(w.ticks) tickhz=\(tickRate) lead=\(median(w.lead)) budget=\(median(w.budget)) "
            + "encode=\(times(w.encode)) over=\(w.over) gpu=\(times(w.gpu)) gpufail=\(w.gpuFailures) late=\(w.late) "
            + "up=\(upscaler.map(name) ?? "off") "
            + "conv=\(pass(.conversion)) flow=\(pass(.flow)) fx=\(times(w.passes[extra])) sharp=\(pass(.sharpen)) "
            + "present=\(pass(.present)) rest=\(times(w.passes[extra + 1])) "
            + "glass=\(w.onGlass) lost=\(w.neverShown) off=\(times(w.offTarget)) "
            + "thermal=\(name(thermal)) lpm=\(lowPower ? 1 : 0)"
    }

    static func name(_ mode: UpscalerMode) -> String {
        switch mode {
        case .spatial: "spatial"
        case .temporal: "temporal"
        case .sharpen: "sharpen"
        }
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
