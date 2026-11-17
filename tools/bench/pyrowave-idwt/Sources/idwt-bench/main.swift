// A micro-benchmark for issue #13: the inverse wavelet transform of PyroWave on the GPU of this Mac.
//
//   swift run -c release idwt-bench                       # 1080p, 4:2:0, float math, serial encoder
//   swift run -c release idwt-bench --matrix              # sizes x chroma x math x encoder, as a Markdown table
//   swift run -c release idwt-bench --size 4k --paced-hz 120 --with-fill
//
// Options: --size 1080p|4k|WxH  --chroma 420|444  --math half|float  --frames N  --warmup N  --paced-hz HZ
//          --concurrent  --with-fill  --fill-only  --bits 8|10  --matrix
// The numbers are GPU milliseconds of one frame's command buffer. It does not decode a bit stream: see docs/PYROWAVE_APPLE.md.
import Foundation
import IDWTKit
import Metal

struct Arguments {
    var size = (width: 1920, height: 1080)
    var chroma = Chroma.yuv420
    var math = MathPrecision.float
    var tenBit = false
    var matrix = false
    var timing = TimingOptions()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("idwt-bench: \(message)\n".utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Arguments {
    var result = Arguments()
    var iterator = arguments.makeIterator()
    func value(_ flag: String) -> String {
        guard let next = iterator.next() else { fail("\(flag) needs a value") }
        return next
    }
    while let flag = iterator.next() {
        switch flag {
        case "--size":
            switch value(flag) {
            case "1080p": result.size = (1920, 1080)
            case "4k": result.size = (3840, 2160)
            case let other:
                let parts = other.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2 else { fail("--size takes 1080p, 4k or WxH") }
                result.size = (parts[0], parts[1])
            }
        case "--chroma":
            guard let chroma = Chroma(rawValue: value(flag)) else { fail("--chroma takes 420 or 444") }
            result.chroma = chroma
        case "--math":
            guard let math = MathPrecision(rawValue: value(flag)) else { fail("--math takes half or float") }
            result.math = math
        case "--bits":
            switch value(flag) {
            case "8": result.tenBit = false
            case "10": result.tenBit = true
            default: fail("--bits takes 8 or 10")
            }
        case "--frames":
            guard let frames = Int(value(flag)), frames > 0 else { fail("--frames takes a positive number") }
            result.timing.frames = frames
        case "--warmup":
            guard let warmup = Int(value(flag)), warmup >= 0 else { fail("--warmup takes a number") }
            result.timing.warmup = warmup
        case "--paced-hz":
            guard let hz = Double(value(flag)), hz > 0 else { fail("--paced-hz takes a positive number") }
            result.timing.pacedHz = hz
        case "--concurrent": result.timing.concurrent = true
        case "--with-fill": result.timing.withFill = true
        case "--fill-only": result.timing.fillOnly = true
        case "--matrix": result.matrix = true
        default: fail("unknown option \(flag)")
        }
    }
    return result
}

func milliseconds(_ value: Double) -> String { String(format: "%.3f", value) }

func measure(_ device: any MTLDevice, _ arguments: Arguments) throws -> TimingResult {
    let layout = PyramidLayout(width: arguments.size.width, height: arguments.size.height, chroma: arguments.chroma)
    let decoder = try IDWTDecoder(device: device, layout: layout, precision: arguments.math, tenBitPlanes: arguments.tenBit)
    return try Benchmark.run(decoder, options: arguments.timing)
}

guard let device = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
let arguments = parse(Array(CommandLine.arguments.dropFirst()))

print("device: \(device.name), unified memory: \(device.hasUnifiedMemory), "
    + "max threadgroup memory: \(device.maxThreadgroupMemoryLength) B")

do {
    if arguments.matrix {
        var base = arguments
        print("")
        print("| Size | Chroma | Math | Encoder | Passes | Median ms | p95 ms | Max ms | Throughput ms |")
        print("|---|---|---|---|---|---|---|---|---|")
        for size in [(1920, 1080), (3840, 2160)] {
            for chroma in Chroma.allCases {
                for math in MathPrecision.allCases {
                    for concurrent in [false, true] {
                        base.size = size
                        base.chroma = chroma
                        base.math = math
                        base.timing.concurrent = concurrent
                        let layout = PyramidLayout(width: size.0, height: size.1, chroma: chroma)
                        let result = try measure(device, base)
                        let gpu = result.gpu
                        print("| \(size.0)x\(size.1) | \(chroma.rawValue) | \(math.rawValue) | "
                            + "\(concurrent ? "concurrent + barriers" : "serial") | \(layout.passes().count) | "
                            + "\(milliseconds(gpu.median)) | \(milliseconds(gpu.percentile(0.95))) | "
                            + "\(milliseconds(gpu.maximum)) | \(milliseconds(result.throughput)) |")
                    }
                }
            }
        }
    } else {
        let layout = PyramidLayout(width: arguments.size.width, height: arguments.size.height, chroma: arguments.chroma)
        let what = arguments.timing.fillOnly ? "coefficient writes only" : (arguments.timing.withFill ? "writes + inverse transform" : "inverse transform")
        print("\(layout.width)x\(layout.height) (aligned \(layout.alignedWidth)x\(layout.alignedHeight)), "
            + "\(arguments.chroma.rawValue), \(arguments.math.rawValue) math, \(arguments.tenBit ? 10 : 8)-bit planes, "
            + "\(arguments.timing.concurrent ? "concurrent encoder with barriers" : "serial encoder"), "
            + "\(arguments.timing.pacedHz.map { "paced at \($0) Hz" } ?? "back to back"), \(what)")
        let result = try measure(device, arguments)
        func line(_ name: String, _ summary: TimingSummary) {
            print("\(name): median \(milliseconds(summary.median)), mean \(milliseconds(summary.mean)), "
                + "p95 \(milliseconds(summary.percentile(0.95))), p99 \(milliseconds(summary.percentile(0.99))), "
                + "min \(milliseconds(summary.minimum)), max \(milliseconds(summary.maximum))")
        }
        line("GPU ms per frame      ", result.gpu)
        if arguments.timing.pacedHz != nil { line("commit to done ms      ", result.commitToDone) }
        line("CPU encode ms         ", result.encode)
        if arguments.timing.pacedHz == nil { print("throughput ms per frame : \(milliseconds(result.throughput)) (first frame start to last frame end)") }
        let budget = 1000 / (arguments.timing.pacedHz ?? 120)
        print("share of a \(milliseconds(budget)) ms frame at the median: "
            + String(format: "%.1f %%", 100 * result.gpu.median / budget))
    }
} catch {
    fail("\(error)")
}
