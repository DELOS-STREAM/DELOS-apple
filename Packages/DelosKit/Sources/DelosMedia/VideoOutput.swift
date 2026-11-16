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

    public init(renderer: any VideoRenderer, supportedFormats: VideoFormats) {
        self.renderer = renderer
        self.supportedFormats = supportedFormats
    }

    // The renderer shows each frame as it arrives; reference frame invalidation is not supported yet
    public var capabilities: VideoDecoderCapabilities { [.directSubmit] }

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
        let name: String
        switch codec {
        case .h264: name = "H.264"
        case .hevc: name = "HEVC"
        case .av1: name = "AV1"
        }
        statistics.configure(width: width, height: height, codec: name, renderer: renderer.name)
        renderer.flush()
        return true
    }

    public func start() {}
    public func stop() {}

    public func cleanup() {
        samples = nil
        frame = []
        renderer.flush()
    }

    public func submit(_ unit: borrowing DecodeUnit) -> DecodeResult {
        guard samples != nil else { return .ok }
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
        let sample = frame.withUnsafeBytes { try? samples!.sample(for: $0, keyFrame: keyFrame) }
        guard let sample else { return .needIDRFrame }
        return renderer.enqueue(sample) ? .ok : .needIDRFrame
    }
}
