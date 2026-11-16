// The bridge between the C core's callbacks and Swift.
//
// The core keeps its connection in global state and supports one connection per process, and its callbacks are plain
// C function pointers without a context argument. So the bridge keeps one global `CoreContext`: the session that
// starts the core claims it, the callbacks read it under a lock, and the session releases it after the core has
// stopped. The callbacks run on the core's threads; they only yield events to an `AsyncStream` and call the
// `Sendable` sinks.
import CDelosCommon
import Foundation
import Synchronization
import os

/// What the C callbacks of one session need.
final class CoreContext: Sendable {
    let events: AsyncStream<StreamEvent>.Continuation
    let video: (any VideoDecodeUnitSink)?
    let audio: (any AudioSampleSink)?
    /// Called on a core thread after the core reported the end of a running stream.
    let onTermination: @Sendable () -> Void
    /// The last stage the core reported as failed, for the error of `start`.
    let failedStage = Mutex<(stage: StreamStage, errorCode: Int32)?>(nil)
    private let interruption = Atomic<Bool>(false)

    init(
        events: AsyncStream<StreamEvent>.Continuation,
        video: (any VideoDecodeUnitSink)?,
        audio: (any AudioSampleSink)?,
        onTermination: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.video = video
        self.audio = audio
        self.onTermination = onTermination
    }

    /// The session asked the core to stop while it starts.
    var interruptRequested: Bool { interruption.load(ordering: .sequentiallyConsistent) }

    /// Interrupts the start. `LiStartConnection` clears the core's interrupted flag before its first stage, so a stop
    /// that comes before that would be lost: the flag set here makes the start thread skip the core when it has not
    /// called it yet, and the first stage report interrupts again (`listenerCallbacks`).
    func interrupt() {
        interruption.store(true, ordering: .sequentiallyConsistent)
        LiInterruptConnection()
    }
}

enum CoreBridge {
    private static let active = Mutex<CoreContext?>(nil)
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "core")

    /// Makes `context` the one the callbacks use; false while another session holds the core.
    static func claim(_ context: CoreContext) -> Bool {
        installLogSink
        return active.withLock { current in
            guard current == nil else { return false }
            current = context
            return true
        }
    }

    /// Detaches `context` from the callbacks if it is the active one.
    static func release(_ context: CoreContext) {
        active.withLock { current in
            if current === context { current = nil }
        }
    }

    static var current: CoreContext? { active.withLock { $0 } }

    private static func emit(_ event: StreamEvent) {
        current?.events.yield(event)
    }

    /// Set once, before the first connection; the core logs only during connections.
    private static let installLogSink: Void = DelosCommonSetLogSink { message in
        guard let message else { return }
        CoreBridge.logger.debug("\(String(cString: message), privacy: .public)")
    }

    // MARK: - C callback tables

    static func listenerCallbacks() -> CONNECTION_LISTENER_CALLBACKS {
        var callbacks = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&callbacks)
        callbacks.stageStarting = { stage in
            let context = CoreBridge.current
            // The core reports its first stage after it has cleared its interrupted flag: a stop that came while the
            // start thread was entering the core is made again here.
            if context?.interruptRequested == true { LiInterruptConnection() }
            guard let stage = StreamStage(rawValue: stage) else { return }
            context?.events.yield(.stageStarting(stage))
        }
        callbacks.stageComplete = { stage in
            guard let stage = StreamStage(rawValue: stage) else { return }
            CoreBridge.emit(.stageComplete(stage))
        }
        callbacks.stageFailed = { stage, errorCode in
            guard let stage = StreamStage(rawValue: stage), let context = CoreBridge.current else { return }
            context.failedStage.withLock { $0 = (stage, errorCode) }
            context.events.yield(.stageFailed(stage, errorCode: errorCode))
        }
        callbacks.connectionStarted = {
            CoreBridge.emit(.connectionStarted)
        }
        callbacks.connectionTerminated = { errorCode in
            guard let context = CoreBridge.current else { return }
            context.events.yield(.terminated(StreamTermination(errorCode: errorCode)))
            context.events.finish()
            context.onTermination()
        }
        callbacks.logMessage = DelosCommonLogForwarder()
        callbacks.rumble = { controller, low, high in
            CoreBridge.emit(.rumble(controller: controller, lowFrequency: low, highFrequency: high))
        }
        callbacks.connectionStatusUpdate = { status in
            CoreBridge.emit(.connectionStatus(status == CONN_STATUS_POOR ? .poor : .okay))
        }
        callbacks.setHdrMode = { enabled in
            CoreBridge.emit(.hdrMode(enabled: enabled))
        }
        callbacks.rumbleTriggers = { controller, left, right in
            CoreBridge.emit(.triggerRumble(controller: controller, left: left, right: right))
        }
        callbacks.setMotionEventState = { controller, motionType, reportRateHz in
            CoreBridge.emit(
                .motionEventState(controller: controller, motionType: motionType, reportRateHz: reportRateHz))
        }
        callbacks.setControllerLED = { controller, red, green, blue in
            CoreBridge.emit(.controllerLED(controller: controller, red: red, green: green, blue: blue))
        }
        callbacks.setAdaptiveTriggers = { controller, eventFlags, typeLeft, typeRight, left, right in
            let size = Int(DS_EFFECT_PAYLOAD_SIZE)
            let leftPayload = left.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
            let rightPayload = right.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
            CoreBridge.emit(
                .adaptiveTriggers(
                    controller: controller, eventFlags: eventFlags, typeLeft: typeLeft, typeRight: typeRight,
                    left: leftPayload, right: rightPayload))
        }
        return callbacks
    }

    static func videoCallbacks(capabilities: VideoDecoderCapabilities) -> DECODER_RENDERER_CALLBACKS {
        var callbacks = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&callbacks)
        callbacks.setup = { format, width, height, frameRate, _, _ in
            guard let sink = CoreBridge.current?.video else { return 0 }
            let accepted = sink.setup(
                format: VideoFormats(rawValue: format), width: Int(width), height: Int(height),
                frameRate: Int(frameRate))
            return accepted ? 0 : -1
        }
        callbacks.start = { CoreBridge.current?.video?.start() }
        callbacks.stop = { CoreBridge.current?.video?.stop() }
        callbacks.cleanup = { CoreBridge.current?.video?.cleanup() }
        callbacks.submitDecodeUnit = { unit in
            guard let unit, let sink = CoreBridge.current?.video else { return DR_OK }
            return sink.submit(DecodeUnit(unit)).cValue
        }
        callbacks.capabilities = capabilities.rawValue
        return callbacks
    }

    static func audioCallbacks(capabilities: AudioRendererCapabilities) -> AUDIO_RENDERER_CALLBACKS {
        var callbacks = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&callbacks)
        callbacks.`init` = { audioConfiguration, opusConfiguration, _, _ in
            guard let sink = CoreBridge.current?.audio else { return 0 }
            guard let layout = AudioConfiguration(rawValue: audioConfiguration), let opusConfiguration else {
                return -1
            }
            let accepted = sink.setup(
                configuration: layout, opus: OpusMultistreamConfiguration(opusConfiguration.pointee))
            return accepted ? 0 : -1
        }
        callbacks.start = { CoreBridge.current?.audio?.start() }
        callbacks.stop = { CoreBridge.current?.audio?.stop() }
        callbacks.cleanup = { CoreBridge.current?.audio?.cleanup() }
        callbacks.decodeAndPlaySample = { data, length in
            guard let sink = CoreBridge.current?.audio else { return }
            if let data, length > 0 {
                sink.decodeAndPlay(UnsafeRawBufferPointer(start: data, count: Int(length)))
            } else {
                sink.decodeAndPlay(nil)
            }
        }
        callbacks.capabilities = capabilities.rawValue
        return callbacks
    }
}

/// Runs a blocking call of the core on its own thread, so it does not hold a thread of Swift's cooperative pool.
func runOnCoreThread<Result: Sendable>(
    _ name: String, _ body: @escaping @Sendable () -> Result
) async -> Result {
    await withCheckedContinuation { continuation in
        let thread = Thread { continuation.resume(returning: body()) }
        thread.name = name
        thread.start()
    }
}
