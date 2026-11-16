import CoreMedia
import Foundation

/// Turns the host's frames into sample buffers for the display layer. It keeps the format description of the
/// current stream and replaces it whenever a frame carries new parameter sets (each IDR frame does; a resolution
/// change brings different ones).
public struct VideoSamples: Sendable {
    public enum Failure: Error, Equatable {
        /// No key frame with parameter sets has arrived yet: ask the host for one.
        case needsKeyFrame
        case coreMedia(OSStatus)
    }

    public let codec: VideoCodec
    public private(set) var format: CMVideoFormatDescription?

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    /// A sample buffer for one frame, marked to be shown as soon as it is decoded (the stream is paced by the host,
    /// not by timestamps). `keyFrame`: the host marked the frame as an IDR / key frame.
    public mutating func sample(for frame: Data, keyFrame: Bool) throws -> CMSampleBuffer {
        if keyFrame || format == nil, let fresh = try? VideoFormat.description(codec: codec, frame: frame) {
            if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: fresh) }) ?? true { format = fresh }
        }
        guard let format else { throw Failure.needsKeyFrame }
        let data = VideoFormat.sampleData(codec: codec, frame: frame)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.coreMedia(status) }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        guard status == noErr else { throw Failure.coreMedia(status) }
        var sample: CMSampleBuffer?
        var size = data.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw Failure.coreMedia(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !keyFrame {
                CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
