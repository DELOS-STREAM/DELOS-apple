import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox

/// A decoded picture, handed from VideoToolbox's thread to the renderer.
struct DecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Seconds from submitting the compressed frame to VideoToolbox until the picture came back.
    let decodeSeconds: Double
}

/// Decodes the stream's frames with a `VTDecompressionSession`: hardware where the device has it, in the real-time
/// mode, asynchronously, one frame at a time in the order they arrive (the host sends no B-frames). The session
/// outputs Metal-compatible, IOSurface-backed two-plane 4:2:0 buffers (``ColorConversion/pixelFormats``) that the
/// renderer draws without a copy.
///
/// `decode` is called from the core's video thread only; `flush` and `invalidate` may come from any thread.
final class VideoDecoder: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case noFormat
        case session(OSStatus)
    }

    /// Called on VideoToolbox's thread for each decoded picture, in order.
    private let onFrame: @Sendable (DecodedFrame) -> Void
    /// Called when a frame could not be decoded or the session broke; the next key frame starts decoding again.
    private let onFailure: @Sendable (OSStatus) -> Void

    private struct Session {
        let session: VTDecompressionSession
        let format: CMVideoFormatDescription
    }

    private nonisolated(unsafe) var current: Session?
    private let lock = NSLock()

    init(onFrame: @escaping @Sendable (DecodedFrame) -> Void, onFailure: @escaping @Sendable (OSStatus) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    deinit {
        if let current { VTDecompressionSessionInvalidate(current.session) }
    }

    /// Submits one compressed frame. Returns false when VideoToolbox rejected it (no session, or a failed decode call),
    /// after which the caller needs a key frame.
    func decode(_ sample: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return false }
        let session: VTDecompressionSession
        do {
            lock.lock()
            defer { lock.unlock() }
            session = try sessionLocked(for: format)
        } catch {
            onFailure(OSStatus(kVTInvalidSessionErr))
            return false
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let onFrame = onFrame, onFailure = onFailure
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: &info
        ) { status, flags, image, _, _ in
            guard status == noErr, let image, !flags.contains(.frameDropped) else {
                onFailure(status == noErr ? OSStatus(kVTVideoDecoderBadDataErr) : status)
                return
            }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            onFrame(DecodedFrame(pixelBuffer: image, decodeSeconds: seconds))
        }
        if status != noErr {
            // The session is gone (the app was in the background) or the data is bad: the next frame builds a new one
            invalidate()
            onFailure(status)
            return false
        }
        return true
    }

    /// Blocks until every frame submitted so far came back (tests; a stream never waits).
    func finishFrames() {
        lock.lock()
        let session = current?.session
        lock.unlock()
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
    }

    func invalidate() {
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        if let old { VTDecompressionSessionInvalidate(old.session) }
    }

    private func sessionLocked(for format: CMVideoFormatDescription) throws(Failure) -> VTDecompressionSession {
        if let current {
            if current.format == format || VTDecompressionSessionCanAcceptFormatDescription(current.session, formatDescription: format) {
                return current.session
            }
            VTDecompressionSessionInvalidate(current.session)
            self.current = nil
        }
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: ColorConversion.pixelFormats,
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
        current = Session(session: session, format: format)
        return session
    }
}
