import Foundation
import Metal
import QuartzCore

public struct TimingOptions: Sendable {
    public var frames = 300
    public var warmup = 60
    /// Submit one frame every 1/`pacedHz` seconds, the way a stream does, instead of back to back. `nil`: back to back.
    public var pacedHz: Double?
    /// A concurrent encoder with a texture barrier per level (PyroWave's Vulkan pattern) instead of a serial one.
    public var concurrent = false
    /// Write the coefficient images every frame before the transform (see `IDWTShaders`).
    public var withFill = false
    /// Skip the inverse transform: time the coefficient writes alone.
    public var fillOnly = false

    public init() {}
}

public struct TimingSummary: Sendable {
    public let samples: [Double]
    public var minimum: Double { samples.min() ?? 0 }
    public var maximum: Double { samples.max() ?? 0 }
    public var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
    public var median: Double { percentile(0.5) }

    public init(samples: [Double]) { self.samples = samples.sorted() }

    /// Nearest-rank percentile, `fraction` in 0...1.
    public func percentile(_ fraction: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let rank = Int((fraction * Double(samples.count)).rounded(.up)) - 1
        return samples[min(max(rank, 0), samples.count - 1)]
    }
}

public struct TimingResult: Sendable {
    /// Milliseconds the GPU spent on one frame's command buffer (`gpuEndTime - gpuStartTime`).
    public let gpu: TimingSummary
    /// Milliseconds from `commit()` to the end of the GPU work: what a decoder pays before it may present.
    public let commitToDone: TimingSummary
    /// Milliseconds the CPU needed to encode one frame.
    public let encode: TimingSummary
    /// Milliseconds per frame over the whole measured run, from the start of its first frame on the GPU to the end of
    /// its last: the throughput of a queue that is never empty (only meaningful back to back).
    public let throughput: Double
}

public enum Benchmark {
    /// Times `frames` frames after `warmup` unmeasured ones.
    public static func run(_ decoder: IDWTDecoder, options: TimingOptions) throws -> TimingResult {
        guard let queue = decoder.device.makeCommandQueue(maxCommandBufferCount: 2048) else {
            throw IDWTError.missing("command queue")
        }
        // Coefficients to transform. The kernel's cost does not depend on their values.
        guard let seedCommands = queue.makeCommandBuffer(), let seedEncoder = seedCommands.makeComputeCommandEncoder() else {
            throw IDWTError.missing("compute encoder")
        }
        decoder.encodeFill(on: seedEncoder, seed: 1)
        seedEncoder.endEncoding()
        seedCommands.commit()
        seedCommands.waitUntilCompleted()

        let total = options.warmup + options.frames
        var buffers: [any MTLCommandBuffer] = []
        var submitted: [Double] = []
        var encodeMilliseconds: [Double] = []
        buffers.reserveCapacity(total)
        let period = options.pacedHz.map { 1 / $0 }
        let start = CACurrentMediaTime()

        for index in 0..<total {
            if let period {
                let target = start + Double(index) * period
                while CACurrentMediaTime() < target - 0.002 { usleep(500) }
                while CACurrentMediaTime() < target {}
            }
            let encodeStart = CACurrentMediaTime()
            guard let commands = queue.makeCommandBuffer(),
                let encoder = commands.makeComputeCommandEncoder(dispatchType: options.concurrent ? .concurrent : .serial)
            else { throw IDWTError.missing("compute encoder") }
            if options.withFill || options.fillOnly {
                decoder.encodeFill(on: encoder, seed: UInt32(truncatingIfNeeded: index))
                if options.concurrent && !options.fillOnly { encoder.memoryBarrier(scope: .textures) }
            }
            if !options.fillOnly {
                decoder.encodeIDWT(on: encoder, barrierBetweenLevels: options.concurrent)
            }
            encoder.endEncoding()
            let commitTime = CACurrentMediaTime()
            commands.commit()
            buffers.append(commands)
            submitted.append(commitTime)
            if index >= options.warmup { encodeMilliseconds.append((commitTime - encodeStart) * 1000) }
        }
        buffers.last?.waitUntilCompleted()

        var gpu: [Double] = []
        var latency: [Double] = []
        for (index, commands) in buffers.enumerated() where index >= options.warmup {
            if let error = commands.error { throw error }
            gpu.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            latency.append((commands.gpuEndTime - submitted[index]) * 1000)
        }
        let measured = buffers[options.warmup...]
        let span = (measured.last?.gpuEndTime ?? 0) - (measured.first?.gpuStartTime ?? 0)
        return TimingResult(
            gpu: TimingSummary(samples: gpu), commitToDone: TimingSummary(samples: latency),
            encode: TimingSummary(samples: encodeMilliseconds), throughput: span * 1000 / Double(measured.count))
    }
}
