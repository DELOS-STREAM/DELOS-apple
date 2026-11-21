import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import Synchronization
#if !targetEnvironment(simulator)
import VideoToolbox
#endif

/// VideoToolbox's low-latency super resolution (`VTLowLatencySuperResolutionScaler`, iOS, iPadOS, tvOS and macOS 26): a
/// machine-learning scaler for real-time video that enlarges one decoded picture by a fixed factor. It reads and writes only
/// 8-bit 4:2:0 video-range pictures (`420v`) and takes a stream up to a size per factor (on the Mac it was measured on:
/// 1280 pixels a side at 1.5×, 960 at 2×, 480 at 4×). The simulators' SDKs do not have it.
public enum NeuralUpscaling {
    /// The pixel format it reads and writes.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// Whether this system runs it.
    static let isSupported: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 26, tvOS 26, macOS 26, *) else { return false }
        return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        #endif
    }()

    /// The factors it offers for a stream of `width` × `height`, smallest first: none outside its limits or without it.
    public static func factors(width: Int, height: Int) -> [Float] {
        #if targetEnvironment(simulator)
        return []
        #else
        guard isSupported, #available(iOS 26, tvOS 26, macOS 26, *) else { return [] }
        return VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(frameWidth: width, frameHeight: height).sorted()
        #endif
    }

    /// The factor for a stream that the upscaler's internal size enlarges by `needed`: the largest offered factor up to it
    /// (MetalFX Spatial enlarges the rest), else the smallest (the presentation reduces the rest). Nil when nothing is
    /// offered or the internal size does not enlarge the stream.
    static func factor(needed: Float, offered: [Float]) -> Float? {
        guard needed > 1, let smallest = offered.min() else { return nil }
        return offered.filter { $0 <= needed + 0.001 }.max() ?? smallest
    }

    /// The size a stream of `width` × `height` has after enlarging it by `factor`.
    static func output(width: Int, height: Int, factor: Float) -> (width: Int, height: Int) {
        (Int((Float(width) * factor).rounded()), Int((Float(height) * factor).rounded()))
    }

    /// Why a picture does not go through it; nil when it does.
    enum Ineligible: String, Error, Sendable {
        /// Not 8-bit video range: 10-bit (HDR) or full-range pictures.
        case format
        /// The stream is larger than every factor takes, or the picture does not enlarge it.
        case size
    }

    /// The factor for a picture of `pixelFormat` and `width` × `height` on an internal size of `target`, or why there is none.
    static func plan(
        pixelFormat: OSType, width: Int, height: Int, target: (width: Int, height: Int),
        factors: (Int, Int) -> [Float] = NeuralUpscaling.factors
    ) -> Result<Float, Ineligible> {
        guard pixelFormat == Self.pixelFormat else { return .failure(.format) }
        guard width > 0, height > 0 else { return .failure(.size) }
        let needed = min(Float(target.width) / Float(width), Float(target.height) / Float(height))
        guard let factor = factor(needed: needed, offered: factors(width, height)) else {
            return .failure(.size)
        }
        return .success(factor)
    }
}

/// The neural scaler of one stream: a session for the stream's size and factor and the pool of the pictures it writes. The
/// session starts on a queue of its own, because loading the model can take longer than a second (Apple's header says not to
/// block a rendering thread with it); until it is ready ``prepare(_:)`` is false and the frame goes through MetalFX Spatial.
/// Used from the drawing thread; the session's start meets it behind a lock.
final class NeuralScaler: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        var width: Int
        var height: Int
        var factor: Float
    }

    private enum Slot {
        case starting(Key)
        /// The session, kept as `AnyObject` because its type exists only from OS 26.
        case ready(Key, AnyObject)
        case failed(Key)

        var key: Key {
            switch self {
            case .starting(let key), .ready(let key, _), .failed(let key): key
            }
        }
    }

    private let lock = NSLock()
    private var slot: Slot?
    /// Orders a drawing's conversion after the neural pass in the command buffer before it.
    private var event: (any MTLEvent)?
    private var signalled: UInt64 = 0
    /// Reasons already written to the log for this stream (one line each).
    private struct Note: Hashable {
        var reason: String
        var width: Int
        var height: Int
    }
    private var noted: Set<Note> = []
    private static let starter = DispatchQueue(label: "io.github.meitoncz.delos.neural", qos: .userInitiated)

    /// Whether the session for `key` is ready; starts it when there is none for `key` (a failed one is not tried again).
    func prepare(_ key: Key) -> Bool {
        let current = lock.withLock { slot }
        if case .ready(let readyKey, _)? = current, readyKey == key { return true }
        if current?.key != key { start(key) }
        return false
    }

    /// Encodes the enlargement of `pixelBuffer` into `commandBuffer` with the ready session of `key`
    /// (``prepare(_:)``) and returns the picture it writes; nil when there is no such session or no output picture.
    func encode(_ pixelBuffer: CVPixelBuffer, key: Key, commandBuffer: any MTLCommandBuffer) -> CVPixelBuffer? {
        guard case .ready(let readyKey, let session)? = lock.withLock({ slot }), readyKey == key else { return nil }
        #if targetEnvironment(simulator)
        return nil
        #else
        guard #available(iOS 26, tvOS 26, macOS 26, *), let session = session as? NeuralSession else { return nil }
        return session.encode(pixelBuffer, commandBuffer: commandBuffer)
        #endif
    }

    /// Makes `next` wait for the end of `pass` (the neural pass, committed first) and records `pass`'s time from its commit
    /// to its completion as StreamPerf's `nn`. Call right before committing `pass`.
    func order(_ pass: any MTLCommandBuffer, before next: any MTLCommandBuffer) -> Bool {
        if event == nil { event = pass.device.makeEvent() }
        guard let event else { return false }
        signalled += 1
        pass.encodeSignalEvent(event, value: signalled)
        next.encodeWaitForEvent(event, value: signalled)
        let committed = CACurrentMediaTime()
        pass.addCompletedHandler { buffer in
            guard buffer.status == .completed else { return }
            StreamPerf.standard?.neural(seconds: CACurrentMediaTime() - committed)
        }
        return true
    }

    /// Writes `reason` once per stream to the StreamPerf log (debug builds).
    func note(_ reason: String, width: Int, height: Int) {
        guard noted.insert(Note(reason: reason, width: width, height: height)).inserted else { return }
        StreamPerf.standard?.note("neural fallback=\(reason) \(width)x\(height)")
    }

    /// The stream ended or the upscaler went off: the session goes (the drawings still in flight keep it until they finish).
    func release() {
        lock.withLock { slot = nil }
        noted.removeAll()
    }

    private func start(_ key: Key) {
        lock.withLock { slot = .starting(key) }
        Self.starter.async { [weak self] in
            guard let self, self.lock.withLock({
                if case .starting(let requested)? = self.slot { return requested == key }
                return false
            }) else { return }
            let began = CACurrentMediaTime()
            #if targetEnvironment(simulator)
            let session: AnyObject? = nil
            #else
            let session: AnyObject? = if #available(iOS 26, tvOS 26, macOS 26, *) { NeuralSession(key) } else { nil }
            #endif
            let milliseconds = Int(((CACurrentMediaTime() - began) * 1000).rounded())
            // A newer request (another size, or a release) replaced this one while it started: it is dropped
            let stored = self.lock.withLock { () -> Bool in
                guard case .starting(let startingKey)? = self.slot, startingKey == key else { return false }
                self.slot = session.map { .ready(key, $0) } ?? .failed(key)
                return true
            }
            guard stored else { return }
            let size = "\(key.width)x\(key.height) x\(key.factor)"
            StreamPerf.standard?.note(
                session == nil ? "neural session \(size) failed" : "neural session \(size) start=\(milliseconds)ms")
        }
    }
}

#if !targetEnvironment(simulator)
/// One `VTFrameProcessor` session of the low-latency super resolution, the pool of its output pictures, and a pool of input
/// pictures in its layout. The scaler needs the layout of `sourcePixelBufferAttributes`: rows of padding below a height
/// that is not a multiple of 16 (`ExtendedPixelsBottom`, 8 for 360 rows on the Mac it was tried on), and fails without
/// it. A decoded picture without that padding is copied into one with it by a blit in the same command buffer.
@available(iOS 26, tvOS 26, macOS 26, *)
private final class NeuralSession {
    let processor = VTFrameProcessor()
    let pool: CVPixelBufferPool
    let inputPool: CVPixelBufferPool
    /// The padding the scaler's input needs, right and below.
    let padding: (right: Int, bottom: Int)
    private var textureCache: CVMetalTextureCache?
    private var frame: Int64 = 0
    private var encodes = 0

    init?(_ key: NeuralScaler.Key) {
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: key.width, frameHeight: key.height, scaleFactor: key.factor)
        var output = configuration.destinationPixelBufferAttributes
        output[kCVPixelBufferMetalCompatibilityKey as String] = true
        var input = configuration.sourcePixelBufferAttributes
        input[kCVPixelBufferMetalCompatibilityKey as String] = true
        padding = (input[kCVPixelBufferExtendedPixelsRightKey as String] as? Int ?? 0,
                   input[kCVPixelBufferExtendedPixelsBottomKey as String] as? Int ?? 0)
        var pool: CVPixelBufferPool?, inputPool: CVPixelBufferPool?
        guard (try? processor.startSession(configuration: configuration)) != nil,
              CVPixelBufferPoolCreate(nil, nil, output as CFDictionary, &pool) == kCVReturnSuccess, let pool,
              CVPixelBufferPoolCreate(nil, nil, input as CFDictionary, &inputPool) == kCVReturnSuccess, let inputPool
        else { return nil }
        self.pool = pool
        self.inputPool = inputPool
    }

    deinit { processor.endSession() }

    func encode(_ decoded: CVPixelBuffer, commandBuffer: any MTLCommandBuffer) -> CVPixelBuffer? {
        encodes += 1
        defer {
            if encodes % 60 == 0, let textureCache { CVMetalTextureCacheFlush(textureCache, 0) }
        }
        guard let source = input(decoded, commandBuffer: commandBuffer) else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess, let output else { return nil }
        // The output carries the source's colour description (matrix, primaries, transfer)
        CVBufferPropagateAttachments(decoded, output)
        frame += 1
        let time = CMTime(value: frame, timescale: 1)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source, presentationTimeStamp: time),
              let outputFrame = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time)
        else { return nil }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: outputFrame)
        processor.process(with: commandBuffer, parameters: parameters)
        // The session and the pictures must outlive the work in the command buffer
        nonisolated(unsafe) let held = (self, decoded, source, output, parameters)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(held) {} }
        return output
    }

    /// `decoded` when it has the scaler's padding, else a copy of its planes into a padded picture, blitted in `commandBuffer`.
    private func input(_ decoded: CVPixelBuffer, commandBuffer: any MTLCommandBuffer) -> CVPixelBuffer? {
        var left = 0, right = 0, top = 0, bottom = 0
        CVPixelBufferGetExtendedPixels(decoded, &left, &right, &top, &bottom)
        if right >= padding.right && bottom >= padding.bottom { return decoded }
        if textureCache == nil {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, commandBuffer.device, nil, &textureCache)
        }
        var copy: CVPixelBuffer?
        guard let textureCache, CVPixelBufferPoolCreatePixelBuffer(nil, inputPool, &copy) == kCVReturnSuccess, let copy,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return nil }
        defer { blit.endEncoding() }
        var held: [CVMetalTexture] = []
        for (plane, format) in [(0, MTLPixelFormat.r8Unorm), (1, MTLPixelFormat.rg8Unorm)] {
            let width = CVPixelBufferGetWidthOfPlane(decoded, plane), height = CVPixelBufferGetHeightOfPlane(decoded, plane)
            var from: CVMetalTexture?, to: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, decoded, nil, format, width, height, plane, &from) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, textureCache, copy, nil, format, width, height, plane, &to) == kCVReturnSuccess,
                  let from, let to, let source = CVMetalTextureGetTexture(from), let target = CVMetalTextureGetTexture(to)
            else { return nil }
            blit.copy(
                from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: width, height: height, depth: 1), to: target, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            held += [from, to]
        }
        nonisolated(unsafe) let textures = held
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(textures) {} }
        return copy
    }
}
#endif
