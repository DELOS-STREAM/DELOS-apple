import CoreMedia
import DelosCore
import Foundation

/// Turns the host's frames into sample buffers for the display layer. It keeps the format description of the
/// current stream and replaces it whenever a frame carries new parameter sets (each IDR frame carries them; a
/// resolution change brings different ones).
///
/// Each frame is parsed once, in place, and copied once: into the sample's own block, as VideoToolbox decodes it
/// (length-prefixed NAL units without the parameter sets for H.264 and HEVC, the OBUs unchanged for AV1). A key frame
/// whose parameter sets are the ones of the current format keeps that format without building it again.
public struct VideoSamples: Sendable {
    public enum Failure: Error, Equatable {
        /// No key frame with parameter sets has arrived yet: ask the host for one.
        case needsKeyFrame
        case coreMedia(OSStatus)
    }

    public let codec: VideoCodec
    public private(set) var format: CMVideoFormatDescription?
    /// The parameter sets (H.264, HEVC) or the sequence header OBU (AV1) `format` was made from.
    private var formatSource: [[UInt8]] = []
    /// The NAL units of the frame in progress; the array is kept so its storage serves the next frame.
    private var units: [Range<Int>] = []
    /// What the host said about its display and content; the format description carries it.
    private var hdr: HDRMetadata?

    public init(codec: VideoCodec) {
        self.codec = codec
    }

    /// A sample buffer for one frame, marked to be shown as soon as it is decoded (the stream is paced by the host,
    /// not by timestamps). `keyFrame`: the host marked the frame as an IDR / key frame. `hostTimeUs`: the host's time of
    /// the frame (`DECODE_UNIT.presentationTimeUs`, from its first captured frame), carried as the presentation time
    /// stamp to the decoded picture (``DecodedFrame/sourceTime``, phase lock); nil leaves the sample untimed. `frame` is
    /// read during the call only.
    public mutating func sample(for frame: UnsafeRawBufferPointer, keyFrame: Bool, hostTimeUs: UInt64? = nil) throws -> CMSampleBuffer {
        let size: Int
        if codec == .av1 {
            if keyFrame || format == nil, let header = try? AV1.sequenceHeader(in: frame) {
                updateFormat([frame[header]])
            }
            size = frame.count
        } else {
            units.removeAll(keepingCapacity: true)
            AnnexB.forEachUnit(in: frame) { units.append($0) }
            if keyFrame || format == nil, let sets = AnnexB.parameterSets(units, in: frame, codec: codec) {
                updateFormat(sets.map { frame[$0] })
            }
            size = AnnexB.lengthPrefixedCount(units, in: frame, codec: codec)
        }
        guard let format else { throw Failure.needsKeyFrame }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw Failure.coreMedia(status) }
        var contiguous = 0
        var pointer: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: nil, dataPointerOut: &pointer)
        guard status == noErr, let pointer, contiguous == size else { throw Failure.coreMedia(status) }
        let destination = UnsafeMutableRawBufferPointer(start: pointer, count: size)
        if codec == .av1 {
            destination.copyMemory(from: frame)
        } else {
            AnnexB.writeLengthPrefixed(units, from: frame, codec: codec, into: destination)
        }

        var sample: CMSampleBuffer?
        var sampleSize = size
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: hostTimeUs.map { CMTime(value: Int64($0), timescale: 1_000_000) } ?? .invalid,
            decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: hostTimeUs == nil ? 0 : 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
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

    /// The HDR metadata the next frames' format carries (nil: none). A change builds the format again from the same
    /// parameter sets, so the renderers see the new description with the next frame.
    public mutating func setHDRMetadata(_ metadata: HDRMetadata?) {
        guard metadata != hdr else { return }
        hdr = metadata
        guard format != nil else { return }
        if let rebuilt = build(formatSource) { format = rebuilt }
    }

    private func build(_ source: [[UInt8]]) -> CMVideoFormatDescription? {
        codec == .av1
            ? try? VideoFormat.av1(Data(source[0]), hdr: hdr)
            : try? VideoFormat.description(codec: codec, parameterSets: source, hdr: hdr)
    }

    /// Builds the format from parameter sets that differ from the current format's; the same ones keep it. Sets that
    /// make no format leave the current one, as before the first key frame.
    private mutating func updateFormat(_ sets: [Slice<UnsafeRawBufferPointer>]) {
        if format != nil, sets.count == formatSource.count,
           zip(sets, formatSource).allSatisfy({ $0.elementsEqual($1) }) {
            return
        }
        let source = sets.map { [UInt8]($0) }
        guard let fresh = build(source) else { return }
        format = fresh
        formatSource = source
    }
}
