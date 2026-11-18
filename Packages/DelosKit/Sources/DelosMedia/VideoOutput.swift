import DelosCore
import Foundation

/// Receives the core's video frames and shows them with a ``VideoRenderer``. The core calls it on its video thread,
/// one call at a time, so its state needs no lock. It runs on the core's receive thread (direct submit), so a frame
/// costs one copy out of the core's buffers into storage kept from frame to frame, and one into the sample's block.
public final class VideoOutput: VideoDecodeUnitSink, @unchecked Sendable {
    public let renderer: any VideoRenderer
    /// The formats this device can decode, for the stream configuration.
    public let supportedFormats: VideoFormats
    public let statistics = VideoStatistics()
    private var samples: VideoSamples?
    /// The frame being submitted, joined from the core's buffers, which are valid only during the call.
    private var frame: [UInt8] = []
    /// Where the HDR metadata of the host comes from while its HDR mode is on: the core.
    private let hdrMetadata: @Sendable () -> HDRMetadata?
    private var hdrActive = false
    /// The receive thread runs at the interactive quality of service from the stream's first frame on.
    private var threadRaised = false

    public init(
        renderer: any VideoRenderer, supportedFormats: VideoFormats,
        hdrMetadata: @escaping @Sendable () -> HDRMetadata? = HDRMetadata.current
    ) {
        self.renderer = renderer
        self.supportedFormats = supportedFormats
        self.hdrMetadata = hdrMetadata
    }

    /// Direct submit only. Reference frame invalidation (HEVC/AV1) stays off until it is verified against a real PC: with
    /// it advertised, an AV1 stream to the owner's PC failed in the RTSP handshake (2026-11-18).
    public var capabilities: VideoDecoderCapabilities { [.directSubmit] }

    /// Raises the calling thread (the core's receive thread, which submits the frames) to the user-interactive quality of
    /// service: Android raises its stream threads (`latency_threads.c`, from the receive thread's first frame). Apple has no
    /// core placement or performance hint session for apps; the quality of service is the scheduler's input.
    static func raiseCurrentThread() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
    }

    /// The codec of a format the host chose.
    public static func codec(for format: VideoFormats) -> VideoCodec? {
        if !format.isDisjoint(with: .allH264) { return .h264 }
        if !format.isDisjoint(with: .allHEVC) { return .hevc }
        if !format.isDisjoint(with: .allAV1) { return .av1 }
        return nil
    }

    public func setup(format: VideoFormats, width: Int, height: Int, frameRate: Int) -> Bool {
        guard let codec = Self.codec(for: format) else { return false }
        samples = VideoSamples(codec: codec)
        threadRaised = false
        let name: String
        switch codec {
        case .h264: name = "H.264"
        case .hevc: name = "HEVC"
        case .av1: name = "AV1"
        }
        statistics.configure(width: width, height: height, codec: name, renderer: renderer.name)
        renderer.flush()
        renderer.setHDR(!format.isDisjoint(with: .tenBit))
        return true
    }

    private func updateHDR(_ active: Bool) {
        guard active || hdrActive else { return }
        hdrActive = active
        samples?.setHDRMetadata(active ? hdrMetadata() : nil)
    }

    public func start() {}
    public func stop() {}

    public func cleanup() {
        renderer.setHDR(false)
        hdrActive = false
        samples = nil
        frame = []
        renderer.flush()
    }

    public func submit(_ unit: borrowing DecodeUnit) -> DecodeResult {
        guard samples != nil else { return .ok }
        if !threadRaised {
            Self.raiseCurrentThread()
            threadRaised = true
        }
        statistics.record(
            frameNumber: UInt32(truncatingIfNeeded: unit.frameNumber), bytes: unit.fullLength,
            hostLatencyTenths: unit.hostProcessingLatencyTenthsOfMs, hdr: unit.hdrActive)
        frame.removeAll(keepingCapacity: true)
        frame.reserveCapacity(unit.fullLength)
        unit.forEachBuffer { _, bytes in
            frame.append(contentsOf: UnsafeBufferPointer(
                start: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), count: bytes.count))
        }
        let keyFrame = unit.isIDRFrame
        // Each key frame is where the picture's description may change: the host's HDR mode and metadata are read then
        if keyFrame { updateHDR(unit.hdrActive) }
        let sample = frame.withUnsafeBytes { try? samples!.sample(for: $0, keyFrame: keyFrame) }
        guard let sample else { return .needIDRFrame }
        return renderer.enqueue(sample) ? .ok : .needIDRFrame
    }
}
