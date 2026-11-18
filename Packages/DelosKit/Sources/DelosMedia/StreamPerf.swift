import DelosCore
import Foundation
import os
import Synchronization

/// The video path's throughput, stage by stage, in debug builds: once a second one line under the os_log category
/// `StreamPerf` (subsystem `io.github.meitoncz.delos`) and in the diagnostic log, so a device console tells where frames go
/// missing: the host (`host`), the network (`in`, `gap`, `fecfail`, `oos`), the core's receive thread (`submit`), the
/// decoder (`dec`, `decq`, `dect`), the queue (`drop`), the display (`tick`, `tickhz`) or the GPU (`gpu`, `late`). One-off
/// lines (``note(_:)``) say what the launch asked for and how the display was planned. Nothing is counted in release
/// builds.
///
///     StreamPerf req=120 link=120 in=119.8 gap=0 host=120.0 mbps=38.2 fecfail=0 oos=0 asm=0.90/2.10 submit=0.08/0.30/0.90 dec=120/120 decfail=0 decq=1 dect=3.10/4.00 queue=120 shown=120 drop=0 full=0 skip=0 gpu-busy=0 repeat=0 tick=120 tickhz=120.0 gpu=0.40/0.60 late=0 thermal=nominal lpm=0
///
/// - `req`: the frame rate the stream negotiated; `link`: the rate the display link asks for.
/// - `in`: frames per second from the core; `gap`: frame numbers that never arrived; `host`: the rate the host encoded at
///   (frame numbers over its presentation times); `fecfail`, `oos`: FEC blocks lost beyond repair and packets out of order.
/// - `asm`: first packet to complete frame in the core; `submit`: the receive thread's time per frame in the video output.
/// - `dec`: frames handed to / returned by the decoder; `decq`: most frames waiting for its thread; `dect`: its time.
/// - `queue`, `shown`, `drop` (`full`: pushed out of a full queue, `skip`: skipped behind a newer due frame, `gpu-busy`:
///   replaced while the upscaler's GPU was busy), `repeat`: refreshes that kept the previous picture.
/// - `tick`, `tickhz`: display link callbacks and their measured rate; `gpu`: GPU time per drawing; `late`: drawings the
///   GPU finished after their refresh.
///
/// `p50/p99` (and `/max` for `submit`) are milliseconds over the second. Every recording takes one short lock.
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
        /// More than the backlog was due at one refresh: the queue skipped ahead.
        case skipped
        /// It waited for the upscaler's busy GPU and a newer frame replaced it.
        case gpuBusy
    }

    /// Up to `capacity` values of one second, kept from second to second without allocating again.
    struct Samples {
        private(set) var values: [Double] = []
        static let capacity = 1024

        init() { values.reserveCapacity(Self.capacity) }

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
        var shown = 0
        var droppedFull = 0
        var droppedSkipped = 0
        var droppedGPUBusy = 0
        var repeated = 0
        var ticks = 0
        var firstTick: Double?
        var lastTick: Double?
        var gpu = Samples()
        var late = 0

        var isEmpty: Bool { received == 0 && ticks == 0 && decodeReturned == 0 }

        /// Keeps the sample storage and the frame number the next window continues from.
        mutating func reset() {
            let number = lastFrameNumber
            var assemble = self.assemble, submit = self.submit, decode = self.decode, gpu = self.gpu
            assemble.reset(); submit.reset(); decode.reset(); gpu.reset()
            self = Window(lastFrameNumber: number, assemble: assemble, submit: submit, decode: decode, gpu: gpu)
        }
    }

    private struct State {
        var window = Window()
        /// When the window began (uptime nanoseconds).
        var windowStart: UInt64 = 0
        var requestedFPS = 0
        var linkFrameRate = 0.0
        var timer: (any DispatchSourceTimer)?
        /// The core's packet counters at the last line (cumulative since the connection started).
        var lastPackets: RTPStatistics?
    }

    private let state = Mutex(State())
    /// The core's video packet counters of the running stream (`LiGetRTPVideoStats`); nil until a stream sets it.
    private let packetSource = Mutex<(@Sendable () -> RTPStatistics?)?>(nil)
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

    /// Where the per-second line reads the core's packet counters (FEC failures and reordering on the network).
    public func setPacketSource(_ source: (@Sendable () -> RTPStatistics?)?) {
        packetSource.withLock { $0 = source }
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
            case .gpuBusy: s.window.droppedGPUBusy += count
            }
        }
    }

    /// A refresh of the display link for the picture shown at `presentation` (seconds); `shown`: a new frame was taken for
    /// it, `repeated`: the previous picture stays (after the first one was shown).
    func tick(presentation: Double, shown: Bool, repeated: Bool) {
        state.withLock { s in
            s.window.ticks += 1
            if s.window.firstTick == nil { s.window.firstTick = presentation }
            s.window.lastTick = presentation
            if shown { s.window.shown += 1 }
            if repeated { s.window.repeated += 1 }
        }
    }

    /// The GPU finished a frame's drawing in `seconds`; `late`: after the time of the refresh it was drawn for.
    func gpuFinished(seconds: Double, late: Bool) {
        state.withLock { s in
            s.window.gpu.add(seconds * 1000)
            if late { s.window.late += 1 }
        }
    }

    // MARK: The line

    /// Logs the window that ended and starts the next one (skipped when nothing happened in it). `seconds`: the window's
    /// length, measured when nil.
    func flush(seconds: Double? = nil, thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState,
               lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) {
        let packets = packetSource.withLock { $0 }?() ?? nil
        let now = DispatchTime.now().uptimeNanoseconds
        let (window, length, fps, link, lastPackets) = state.withLock { s -> (Window, Double, Int, Double, RTPStatistics?) in
            defer {
                s.window.reset()
                s.windowStart = now
                if let packets { s.lastPackets = packets }
            }
            let measured = s.windowStart > 0 && now > s.windowStart ? Double(now - s.windowStart) / 1_000_000_000 : 1
            return (s.window, seconds ?? measured, s.requestedFPS, s.linkFrameRate, s.lastPackets)
        }
        guard !window.isEmpty else { return }
        var network: (fecFailed: Int, outOfSequence: Int)?
        if let packets {
            network = (Int(packets.fecFailed &- (lastPackets?.fecFailed ?? 0)),
                       Int(packets.outOfSequence &- (lastPackets?.outOfSequence ?? 0)))
        }
        emit(Self.line(
            window, seconds: length, requestedFPS: fps, linkFrameRate: link, network: network, thermal: thermal, lowPower: lowPower))
    }

    static func line(
        _ w: Window, seconds: Double, requestedFPS: Int, linkFrameRate: Double, network: (fecFailed: Int, outOfSequence: Int)?,
        thermal: ProcessInfo.ThermalState, lowPower: Bool
    ) -> String {
        func rate(_ count: Int) -> String { String(format: "%.1f", Double(count) / seconds) }
        func times(_ samples: Samples, max: Bool = false) -> String {
            let sorted = samples.values.sorted()
            guard let p50 = Samples.percentile(sorted, 0.5), let p99 = Samples.percentile(sorted, 0.99) else { return "-" }
            return max ? String(format: "%.2f/%.2f/%.2f", p50, p99, sorted[sorted.count - 1]) : String(format: "%.2f/%.2f", p50, p99)
        }
        var host = "-"
        if let first = w.firstHost, let last = w.lastHost, last.timeUs > first.timeUs, last.number > first.number {
            host = String(format: "%.1f", Double(last.number - first.number) * 1_000_000 / Double(last.timeUs - first.timeUs))
        }
        var tickRate = "-"
        if let first = w.firstTick, let last = w.lastTick, last > first, w.ticks > 1 {
            tickRate = String(format: "%.1f", Double(w.ticks - 1) / (last - first))
        }
        let dropped = w.droppedFull + w.droppedSkipped + w.droppedGPUBusy
        return "StreamPerf req=\(requestedFPS) link=\(Int(linkFrameRate.rounded())) in=\(rate(w.received)) gap=\(w.gaps) host=\(host) "
            + "mbps=\(String(format: "%.1f", Double(w.bytes) * 8 / 1_000_000 / seconds)) "
            + "fecfail=\(network.map { "\($0.fecFailed)" } ?? "-") oos=\(network.map { "\($0.outOfSequence)" } ?? "-") "
            + "asm=\(times(w.assemble)) submit=\(times(w.submit, max: true)) dec=\(w.decodeSubmitted)/\(w.decodeReturned) "
            + "decfail=\(w.decodeFailed) decq=\(w.decodeWaiting) dect=\(times(w.decode)) queue=\(w.queued) shown=\(w.shown) "
            + "drop=\(dropped) full=\(w.droppedFull) skip=\(w.droppedSkipped) gpu-busy=\(w.droppedGPUBusy) repeat=\(w.repeated) "
            + "tick=\(w.ticks) tickhz=\(tickRate) gpu=\(times(w.gpu)) late=\(w.late) thermal=\(name(thermal)) lpm=\(lowPower ? 1 : 0)"
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
