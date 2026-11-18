import Foundation
import Metal
import Synchronization

/// The GPU's time in each part of one drawing, in seconds; nil where the part did not run.
struct GPUPassTimes: Sendable, Equatable {
    private var seconds = SIMD8<Double>(repeating: 0)
    private var ran = 0

    subscript(pass: GPUPass) -> Double? {
        ran & (1 << pass.rawValue) != 0 ? seconds[pass.rawValue] : nil
    }

    /// The passes' times together.
    var total: Double {
        var total = 0.0
        for index in 0..<8 { total += seconds[index] }
        return total
    }

    mutating func add(_ pass: GPUPass, seconds time: Double) {
        seconds[pass.rawValue] += time
        ran |= 1 << pass.rawValue
    }
}

/// Times the passes of a drawing apart with the GPU's timestamp counter (``StreamPerf``'s breakdown; debug builds). The
/// pipeline cache shows it each pass descriptor before the encoder is made (``GPUPassObserver``), and it attaches two
/// samples of a counter sample buffer: the start and the end of a render pass's fragment stage (where a full-screen
/// pass spends much of its time on a tile-based GPU) or of a compute pass's encoder. Vertex work and other unsampled
/// stages are not included. MetalFX encodes its own passes without a descriptor.
///
/// These are elapsed GPU timestamps, not active shader time. The residual command-buffer time cannot be attributed
/// solely to MetalFX or the compositor.
///
/// ``begin()``, the observer's calls and ``end()`` come from the thread that draws; ``times(of:)`` from the command
/// buffer's completion handler.
final class GPUPassTimer: GPUPassObserver, @unchecked Sendable {
    /// The samples of one drawing.
    struct Drawing: Sendable {
        fileprivate var first: Int
        /// The passes in the order they were encoded, three bits each.
        fileprivate var passes: UInt64
        fileprivate var count: Int
    }

    /// Passes of one drawing that are timed (two samples each); further ones are not.
    static let passesPerDrawing = 8
    /// Drawings whose samples are kept apart: more than are ever in flight.
    static let drawings = 8

    private let device: any MTLDevice
    private let buffer: any MTLCounterSampleBuffer
    private var slot = 0
    private var current: Drawing?
    /// Two readings of the CPU's and the GPU's clocks, far enough apart: the GPU's timestamp unit in seconds.
    private let scale: Mutex<(cpu: MTLTimestamp, gpu: MTLTimestamp, secondsPerTick: Double?)>

    /// Nil when the GPU has no timestamp counter it can sample at a pass's boundaries (the simulators).
    init?(device: any MTLDevice) {
        guard device.supportsCounterSampling(.atStageBoundary),
              let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else { return nil }
        let description = MTLCounterSampleBufferDescriptor()
        description.counterSet = set
        description.storageMode = .shared
        description.sampleCount = Self.drawings * Self.passesPerDrawing * 2
        guard let buffer = try? device.makeCounterSampleBuffer(descriptor: description) else { return nil }
        self.device = device
        self.buffer = buffer
        let clocks = device.sampleTimestamps()
        scale = Mutex((clocks.cpu, clocks.gpu, nil))
    }

    /// A drawing starts: its passes are timed from here to ``end()``.
    func begin() {
        current = Drawing(first: slot * Self.passesPerDrawing * 2, passes: 0, count: 0)
        slot = (slot + 1) % Self.drawings
    }

    /// The drawing's samples, to read once its command buffers have completed.
    func end() -> Drawing? {
        defer { current = nil }
        return current
    }

    func willEncode(_ pass: GPUPass, render: MTLRenderPassDescriptor) {
        guard let index = take(pass), let attachment = render.sampleBufferAttachments[0] else { return }
        attachment.sampleBuffer = buffer
        attachment.startOfVertexSampleIndex = MTLCounterDontSample
        attachment.endOfVertexSampleIndex = MTLCounterDontSample
        attachment.startOfFragmentSampleIndex = index
        attachment.endOfFragmentSampleIndex = index + 1
    }

    func willEncode(_ pass: GPUPass, compute: MTLComputePassDescriptor) {
        guard let index = take(pass), let attachment = compute.sampleBufferAttachments[0] else { return }
        attachment.sampleBuffer = buffer
        attachment.startOfEncoderSampleIndex = index
        attachment.endOfEncoderSampleIndex = index + 1
    }

    /// The index of the pass's first sample; nil outside a drawing or beyond its samples.
    private func take(_ pass: GPUPass) -> Int? {
        guard var drawing = current, drawing.count < Self.passesPerDrawing else { return nil }
        defer {
            drawing.passes |= UInt64(pass.rawValue) << UInt64(3 * drawing.count)
            drawing.count += 1
            current = drawing
        }
        return drawing.first + 2 * drawing.count
    }

    /// The time of each pass of `drawing`; nil when the samples cannot be read.
    func times(of drawing: Drawing) -> GPUPassTimes? {
        guard drawing.count > 0,
              let data = try? buffer.resolveCounterRange(drawing.first..<(drawing.first + 2 * drawing.count)) else { return nil }
        let secondsPerTick = unit()
        var times = GPUPassTimes()
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: MTLCounterResultTimestamp.self)
            for index in 0..<min(drawing.count, samples.count / 2) {
                let start = samples[2 * index].timestamp, end = samples[2 * index + 1].timestamp
                guard start != MTLCounterErrorValue, end != MTLCounterErrorValue, end >= start,
                      let pass = GPUPass(rawValue: Int(drawing.passes >> UInt64(3 * index)) & 7) else { continue }
                times.add(pass, seconds: Double(end - start) * secondsPerTick)
            }
        }
        return times
    }

    /// Seconds per unit of the GPU's timestamps: nanoseconds until the two clocks have run long enough to measure it.
    private func unit() -> Double {
        scale.withLock { reading in
            if let known = reading.secondsPerTick { return known }
            let (cpu, gpu) = device.sampleTimestamps()
            guard cpu > reading.cpu, gpu > reading.gpu else { return 1e-9 }
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let cpuSeconds = Double(cpu - reading.cpu) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
            let measured = cpuSeconds / Double(gpu - reading.gpu)
            // A tenth of a second apart measures the unit to well under a percent
            if cpuSeconds > 0.1 { reading.secondsPerTick = measured }
            return measured
        }
    }
}
