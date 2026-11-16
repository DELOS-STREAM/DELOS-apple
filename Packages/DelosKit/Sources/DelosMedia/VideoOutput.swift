import DelosCore
import Foundation

/// Receives the core's video frames and shows them with a ``VideoRenderer``. The core calls it on its video thread,
/// one call at a time, so its state needs no lock.
public final class VideoOutput: VideoDecodeUnitSink, @unchecked Sendable {
    public let renderer: any VideoRenderer
    /// The formats this device can decode, for the stream configuration.
    public let supportedFormats: VideoFormats
    public let statistics = VideoStatistics()
    private var samples: VideoSamples?

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
        statistics.configure(width: width, height: height, codec: name)
        renderer.flush()
        return true
    }

    public func start() {}
    public func stop() {}

    public func cleanup() {
        samples = nil
        renderer.flush()
    }

    public func submit(_ unit: borrowing DecodeUnit) -> DecodeResult {
        guard samples != nil else { return .ok }
        statistics.record(
            frameNumber: UInt32(truncatingIfNeeded: unit.frameNumber), bytes: unit.fullLength,
            hostLatencyTenths: unit.hostProcessingLatencyTenthsOfMs, hdr: unit.hdrActive)
        var frame = Data(capacity: unit.fullLength)
        unit.forEachBuffer { _, bytes in frame.append(contentsOf: bytes) }
        guard let sample = try? samples!.sample(for: frame, keyFrame: unit.isIDRFrame) else { return .needIDRFrame }
        return renderer.enqueue(sample) ? .ok : .needIDRFrame
    }
}
