// One stream: connects the C core to a host, reports its progress and feeds the sinks.
import CDelosCommon

/// One connection to a host's stream.
///
/// A session runs once: `start` connects, `stop` (or the host ending the stream) disconnects, and `events` finishes.
/// The C core supports one connection per process, so `start` fails with `StreamError.anotherSessionActive` while
/// another session is starting, running or stopping. After a `.terminated` event the session stops itself.
public actor StreamSession {
    /// The core's reports in order; finishes when the session has stopped.
    public nonisolated let events: AsyncStream<StreamEvent>

    private let continuation: AsyncStream<StreamEvent>.Continuation
    private let videoSink: (any VideoDecodeUnitSink)?
    private let audioSink: (any AudioSampleSink)?
    private let roundTrip: @Sendable () -> (rtt: UInt32, variance: UInt32)?

    private enum State {
        case idle
        /// `LiStartConnection` runs on its own thread.
        case starting(CoreContext)
        case running(CoreContext)
        /// `LiStopConnection` runs on its own thread.
        case stopping
        case stopped
    }

    private var state = State.idle
    /// `stop` calls that wait for a start or a stop in progress to end.
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    /// What the running connection encrypts; nil before it started.
    public private(set) var encryption: StreamEncryption?

    /// Sinks left out receive nothing; the core discards their data.
    public init(videoSink: (any VideoDecodeUnitSink)? = nil, audioSink: (any AudioSampleSink)? = nil) {
        self.init(videoSink: videoSink, audioSink: audioSink, roundTrip: Self.coreRoundTrip)
    }

    /// `roundTrip` reads the core's round-trip estimate; tests count the reads.
    init(
        videoSink: (any VideoDecodeUnitSink)?, audioSink: (any AudioSampleSink)?,
        roundTrip: @escaping @Sendable () -> (rtt: UInt32, variance: UInt32)?
    ) {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.videoSink = videoSink
        self.audioSink = audioSink
        self.roundTrip = roundTrip
    }

    /// Connects to the host and returns once the stream runs (all stages done).
    ///
    /// The host must have launched or resumed the app first; `configuration.remoteInputKey` must be the key of that
    /// request. Cancelling the calling task interrupts the connection attempt, also before the core has begun.
    public func start(server: ServerInformation, configuration: StreamConfiguration) async throws(StreamError) {
        guard case .idle = state else { throw .alreadyStarted }
        let context = CoreContext(
            events: continuation, video: videoSink, audio: audioSink,
            onTermination: { [weak self] in
                Task { await self?.stop() }
            })
        guard CoreBridge.claim(context) else { throw .anotherSessionActive }
        state = .starting(context)

        let videoCapabilities = videoSink?.capabilities ?? []
        let audioCapabilities = audioSink?.capabilities ?? []
        let code = await withTaskCancellationHandler {
            await runOnCoreThread("DELOS core start") { () -> Int32? in
                // Stopped before this thread ran: the core is not started at all
                guard !context.interruptRequested else { return nil }
                return server.withCValue { info in
                    var config = configuration.cValue
                    var listener = CoreBridge.listenerCallbacks()
                    var video = CoreBridge.videoCallbacks(capabilities: videoCapabilities)
                    var audio = CoreBridge.audioCallbacks(capabilities: audioCapabilities)
                    return LiStartConnection(&info, &config, &listener, &video, &audio, nil, 0, nil, 0)
                }
            }
        } onCancel: {
            context.interrupt()
        }

        let cancelled = context.interruptRequested || Task.isCancelled
        if code == 0 {
            state = .running(context)
            if cancelled {
                await stop()
                throw .cancelled
            }
            let encryption = StreamEncryption.read(serverAppVersion: server.appVersion)
            self.encryption = encryption
            DiagLog.i("Stream", "Stream started")
            if let video = context.negotiatedVideo.withLock({ $0 }) {
                DiagLog.i("Stream", StreamLogLines.negotiated(
                    format: video.format, width: video.width, height: video.height, fps: video.frameRate, bitrateKbps: configuration.bitrateKbps))
            }
            DiagLog.i("Stream", encryption.logLine)
            return
        }

        // A failed LiStartConnection has already undone its stages.
        finish(context)
        guard let code, !cancelled else {
            DiagLog.i("Stream", "Stream start cancelled")
            throw .cancelled
        }
        if let failure = context.failedStage.withLock({ $0 }) {
            DiagLog.e("Stream", "Stream start failed at stage \(failure.stage) with error \(failure.errorCode)")
            throw .stageFailed(failure.stage, errorCode: failure.errorCode)
        }
        DiagLog.e("Stream", "Stream start rejected by the core (\(code))")
        throw .rejected(code: code)
    }

    /// Disconnects and finishes `events`; returns once the core is released, so a new session can start. During
    /// `start` it interrupts the attempt and waits for it to unwind, and `start` throws `StreamError.cancelled`.
    public func stop() async {
        switch state {
        case .idle:
            state = .stopped
            continuation.finish()
        case .starting(let context):
            context.interrupt()
            await withCheckedContinuation { stopWaiters.append($0) }
        case .running(let context):
            state = .stopping
            await runOnCoreThread("DELOS core stop") { LiStopConnection() }
            finish(context)
            DiagLog.i("Stream", "Stream stopped")
        case .stopping:
            await withCheckedContinuation { stopWaiters.append($0) }
        case .stopped:
            break
        }
    }

    /// The round-trip time to the host and its variance as the control stream measures them; nil before the first
    /// measurement and whenever the stream does not run. The core allows this read only between a successful start
    /// and its stop (it locks a mutex the stop destroys); isolated to the session, the read cannot overlap `stop`,
    /// which leaves the running state before the core tears down.
    public func estimatedRoundTrip() -> (rtt: Duration, variance: Duration)? {
        guard case .running = state, let reading = roundTrip() else { return nil }
        return (.milliseconds(reading.rtt), .milliseconds(reading.variance))
    }

    private static let coreRoundTrip: @Sendable () -> (rtt: UInt32, variance: UInt32)? = {
        var rtt: UInt32 = 0
        var variance: UInt32 = 0
        return LiGetEstimatedRttInfo(&rtt, &variance) ? (rtt, variance) : nil
    }

    private func finish(_ context: CoreContext) {
        state = .stopped
        CoreBridge.release(context)
        continuation.finish()
        let waiters = stopWaiters
        stopWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}
