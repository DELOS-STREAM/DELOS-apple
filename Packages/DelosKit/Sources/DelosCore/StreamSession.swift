// One stream: connects the C core to a host, reports its progress and feeds the sinks.
import CDelosCommon

/// One connection to a host's stream.
///
/// A session runs once: `start` connects, `stop` (or the host ending the stream) disconnects, and `events` finishes.
/// The C core supports one connection per process, so `start` fails with `StreamError.anotherSessionActive` while
/// another session is starting or running. After a `.terminated` event the session stops itself.
public actor StreamSession {
    /// The core's reports in order; finishes when the session has stopped.
    public nonisolated let events: AsyncStream<StreamEvent>

    private let continuation: AsyncStream<StreamEvent>.Continuation
    private let videoSink: (any VideoDecodeUnitSink)?
    private let audioSink: (any AudioSampleSink)?

    private enum State {
        case idle
        case starting
        case running(CoreContext)
        case stopped
    }

    private var state = State.idle
    private var stopRequested = false

    /// Sinks left out receive nothing; the core discards their data.
    public init(videoSink: (any VideoDecodeUnitSink)? = nil, audioSink: (any AudioSampleSink)? = nil) {
        (events, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        self.videoSink = videoSink
        self.audioSink = audioSink
    }

    /// Connects to the host and returns once the stream runs (all stages done).
    ///
    /// The host must have launched or resumed the app first; `configuration.remoteInputKey` must be the key of that
    /// request. Cancelling the calling task interrupts the connection attempt.
    public func start(server: ServerInformation, configuration: StreamConfiguration) async throws(StreamError) {
        guard case .idle = state else { throw .alreadyStarted }
        let context = CoreContext(
            events: continuation, video: videoSink, audio: audioSink,
            onTermination: { [weak self] in
                Task { await self?.stop() }
            })
        guard CoreBridge.claim(context) else { throw .anotherSessionActive }
        state = .starting

        let videoCapabilities = videoSink?.capabilities ?? []
        let audioCapabilities = audioSink?.capabilities ?? []
        let code = await withTaskCancellationHandler {
            await runOnCoreThread("DELOS core start") {
                server.withCValue { info in
                    var config = configuration.cValue
                    var listener = CoreBridge.listenerCallbacks()
                    var video = CoreBridge.videoCallbacks(capabilities: videoCapabilities)
                    var audio = CoreBridge.audioCallbacks(capabilities: audioCapabilities)
                    return LiStartConnection(&info, &config, &listener, &video, &audio, nil, 0, nil, 0)
                }
            }
        } onCancel: {
            LiInterruptConnection()
        }

        let cancelled = stopRequested || Task.isCancelled
        if code == 0 {
            state = .running(context)
            if cancelled {
                await stop()
                throw .cancelled
            }
            return
        }

        // A failed LiStartConnection has already undone its stages.
        finish(context)
        if cancelled { throw .cancelled }
        if let failure = context.failedStage.withLock({ $0 }) {
            throw .stageFailed(failure.stage, errorCode: failure.errorCode)
        }
        throw .rejected(code: code)
    }

    /// Disconnects and finishes `events`. During `start` it interrupts the attempt, and `start` throws
    /// `StreamError.cancelled`.
    public func stop() async {
        switch state {
        case .idle:
            state = .stopped
            continuation.finish()
        case .starting:
            stopRequested = true
            LiInterruptConnection()
        case .running(let context):
            state = .stopped
            await runOnCoreThread("DELOS core stop") { LiStopConnection() }
            finish(context)
        case .stopped:
            break
        }
    }

    private func finish(_ context: CoreContext) {
        state = .stopped
        CoreBridge.release(context)
        continuation.finish()
    }
}
