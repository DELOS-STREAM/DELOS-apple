import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// HDR metadata as picture attachments; immutable CoreFoundation data, safe to hand to VideoToolbox's thread.
struct HDRAttachments: @unchecked Sendable {
    let items: [(key: CFString, value: CFData)]
}

/// A decoded picture, handed from VideoToolbox's thread to the renderer.
struct DecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Seconds from submitting the compressed frame to VideoToolbox until the picture came back.
    let decodeSeconds: Double
}

/// Decodes the stream's frames with a `VTDecompressionSession`: hardware where the device has it, in the real-time
/// mode, one frame at a time in the order they arrive (the host sends no B-frames). The session outputs Metal-compatible,
/// IOSurface-backed two-plane 4:2:0 buffers (``ColorConversion/pixelFormats``) that the renderer draws without a copy:
/// 8-bit for an 8-bit stream and 10-bit (P010) for a 10-bit one, so HDR keeps its depth. A stream that changes its depth
/// gets a new session.
///
/// The core's receive thread only hands a frame over: the decoding runs on the decoder's own thread, as Android's
/// `MediaCodec` decodes apart from the thread that queues its input. Decoding on the receive thread held it for the
/// whole decode (1.5 to 7 ms a 1080p frame on an M6 Mac), while the next frame's packets waited in the socket.
/// `checkbox_async_decode` decides how that thread calls VideoToolbox: asynchronously
/// (`kVTDecodeFrame_EnableAsynchronousDecompression`; frames come back in decode order on VideoToolbox's thread) or one
/// frame after the other. Frames still waiting when the decoder falls ``maximumPending`` behind are discarded and the
/// stream asks for a key frame.
///
/// `decode` is called from the core's video thread only; `discardPending` and `invalidate` may come from any thread.
final class VideoDecoder: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noFormat
        case session(OSStatus)
    }

    /// Frames handed over and not yet decoded beyond which the decoder is behind for good: a quarter of a second at
    /// 120 fps. A new session's first pictures take up to 50 ms, and a stream that stalled arrives in a burst: both are
    /// caught up within it (the receive socket absorbed them before, while the receive thread decoded).
    static let maximumPending = 30

    /// Called for each decoded picture, in order: on VideoToolbox's thread when asynchronous, else on the decoder's.
    private let onFrame: @Sendable (DecodedFrame) -> Void
    /// Called when a frame could not be decoded or the session broke; the next key frame starts decoding again.
    private let onFailure: @Sendable (OSStatus) -> Void
    /// `kVTDecodeFrame_EnableAsynchronousDecompression`: VideoToolbox returns the picture after the call.
    private let asynchronous: Bool
    /// Debug builds: the frames waiting for the decoder's thread go into the throughput line.
    private let perf: StreamPerf?

    private struct Session {
        let session: VTDecompressionSession
        let format: CMVideoFormatDescription
        let tenBit: Bool
    }

    /// A frame on its way to the decoder's thread.
    private struct Pending: @unchecked Sendable {
        let sample: CMSampleBuffer
        let generation: Int
    }

    /// Touched on the decoder's thread, and under `lock` from elsewhere.
    private nonisolated(unsafe) var current: Session?
    private let lock = NSLock()
    /// Frames handed over and not yet given to VideoToolbox, and the generation whose frames are still wanted.
    private let pending = Mutex((count: 0, generation: 0))
    private let queue = DispatchQueue(label: "io.github.meitoncz.delos.video-decode", qos: .userInteractive)
    private let onQueue = DispatchSpecificKey<Bool>()

    init(
        asynchronous: Bool = true, perf: StreamPerf? = nil, onFrame: @escaping @Sendable (DecodedFrame) -> Void,
        onFailure: @escaping @Sendable (OSStatus) -> Void
    ) {
        self.asynchronous = asynchronous
        self.perf = perf
        self.onFrame = onFrame
        self.onFailure = onFailure
        queue.setSpecific(key: onQueue, value: true)
    }

    deinit {
        if let current { VTDecompressionSessionInvalidate(current.session) }
    }

    /// Hands one compressed frame to the decoder's thread. Returns false when it cannot be decoded (no format) or the
    /// decoder fell too far behind, after which the caller needs a key frame.
    func decode(_ sample: CMSampleBuffer) -> Bool {
        guard CMSampleBufferGetFormatDescription(sample) != nil else { return false }
        let handed = pending.withLock { p -> (generation: Int, waiting: Int)? in
            guard p.count < Self.maximumPending else {
                // Behind for good: what waits is dropped and decoding starts again at a key frame
                p.generation += 1
                p.count = 0
                return nil
            }
            p.count += 1
            return (p.generation, p.count)
        }
        guard let handed else {
            onFailure(OSStatus(kVTVideoDecoderMalfunctionErr))
            return false
        }
        perf?.decodeWaiting(handed.waiting)
        let frame = Pending(sample: sample, generation: handed.generation)
        queue.async { [self] in
            let wanted = pending.withLock { p -> Bool in
                guard p.generation == frame.generation else { return false }
                p.count -= 1
                return true
            }
            if wanted { decodeNow(frame.sample) }
        }
        return true
    }

    /// Drops the frames that wait for the decoder's thread (a flush: the stream continues from a key frame).
    func discardPending() {
        pending.withLock { p in
            p.generation += 1
            p.count = 0
        }
    }

    private func decodeNow(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let session: VTDecompressionSession
        do {
            lock.lock()
            defer { lock.unlock() }
            session = try sessionLocked(for: format)
        } catch {
            onFailure(OSStatus(kVTInvalidSessionErr))
            return
        }
        let hdr = Self.hdrAttachments(of: format)
        let started = DispatchTime.now().uptimeNanoseconds
        let onFrame = onFrame, onFailure = onFailure
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: asynchronous ? [._EnableAsynchronousDecompression] : [], infoFlagsOut: &info
        ) { status, flags, image, _, _ in
            guard status == noErr, let image, !flags.contains(.frameDropped) else {
                onFailure(status == noErr ? OSStatus(kVTVideoDecoderBadDataErr) : status)
                return
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            Self.attach(hdr, to: image)
            onFrame(DecodedFrame(pixelBuffer: image, decodeSeconds: seconds))
        }
        if status != noErr {
            // The session is gone (the app was in the background) or the data is bad: the next frame builds a new one
            invalidateSession()
            onFailure(status)
        }
    }

    /// Runs `body` on the decoder's thread and waits for it (at once when already there).
    private func onDecoderThread<T>(_ body: () throws -> T) rethrows -> T {
        DispatchQueue.getSpecific(key: onQueue) == true ? try body() : try queue.sync(execute: body)
    }

    /// Blocks until every frame handed over so far came back (tests; a stream never waits).
    func finishFrames() {
        onDecoderThread {}
        lock.lock()
        let session = current?.session
        lock.unlock()
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    /// Whether the current session outputs 10-bit pictures; nil without a session (tests).
    var sessionDepth: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return current?.tenBit
    }

    /// Makes the session for `format` without a frame (tests).
    func prepare(for format: CMVideoFormatDescription) throws {
        try onDecoderThread {
            lock.lock()
            defer { lock.unlock() }
            _ = try sessionLocked(for: format)
        }
    }

    /// Drops the waiting frames and the session.
    func invalidate() {
        discardPending()
        onDecoderThread { invalidateSession() }
    }

    private func invalidateSession() {
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        guard let old else { return }
        // Frames still decoding come back first (or fail), so none arrives from a session that is gone
        if asynchronous { VTDecompressionSessionWaitForAsynchronousFrames(old.session) }
        VTDecompressionSessionInvalidate(old.session)
    }

    private func sessionLocked(for format: CMVideoFormatDescription) throws(Failure) -> VTDecompressionSession {
        let tenBit = VideoFormat.bitDepth(of: format) > 8
        if let current {
            if current.tenBit == tenBit,
               current.format == format || VTDecompressionSessionCanAcceptFormatDescription(current.session, formatDescription: format) {
                return current.session
            }
            VTDecompressionSessionInvalidate(current.session)
            self.current = nil
        }
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Self.outputFormats(tenBit: tenBit),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { throw .session(status) }
        // The stream is live: output as soon as a picture is ready, and no more buffering than the decoder needs
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        current = Session(session: session, format: format, tenBit: tenBit)
        return session
    }

    /// The pixel formats the session outputs: the 10-bit ones for a 10-bit stream, else the 8-bit ones.
    static func outputFormats(tenBit: Bool) -> [OSType] {
        tenBit
            ? [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
            : [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    }

    /// The HDR metadata of a format description, as the attachments of a picture.
    static func hdrAttachments(of format: CMFormatDescription) -> HDRAttachments {
        HDRAttachments(items: [(kCVImageBufferMasteringDisplayColorVolumeKey, kCMFormatDescriptionExtension_MasteringDisplayColorVolume),
         (kCVImageBufferContentLightLevelInfoKey, kCMFormatDescriptionExtension_ContentLightLevelInfo)].compactMap { key, extensionKey in
            (CMFormatDescriptionGetExtension(format, extensionKey: extensionKey) as? Data).map { (key, $0 as CFData) }
        })
    }

    /// Puts the metadata on a picture VideoToolbox did not already describe with it, for the renderer.
    static func attach(_ attachments: HDRAttachments, to image: CVPixelBuffer) {
        for (key, value) in attachments.items where CVBufferCopyAttachment(image, key, nil) == nil {
            CVBufferSetAttachment(image, key, value, .shouldPropagate)
        }
    }
}
