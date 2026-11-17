import Foundation
import Metal
import Testing

@testable import IDWTKit

// MARK: Layout

@Suite struct PyramidLayoutTests {
    @Test func alignsAndPads() {
        let hd = PyramidLayout(width: 1920, height: 1080, chroma: .yuv420)
        #expect(hd.alignedWidth == 1920)
        #expect(hd.alignedHeight == 1088)
        let uhd = PyramidLayout(width: 3840, height: 2160, chroma: .yuv420)
        #expect(uhd.alignedHeight == 2176)
        let tiny = PyramidLayout(width: 34, height: 30, chroma: .yuv420)
        #expect(tiny.alignedWidth == 128 && tiny.alignedHeight == 128)  // the minimum image size
    }

    @Test func bandSizesHalveWithEveryLevel() {
        let layout = PyramidLayout(width: 1920, height: 1080, chroma: .yuv420)
        #expect(layout.bandSize(level: 0) == (960, 544))
        #expect(layout.bandSize(level: 4) == (60, 34))
    }

    @Test func chromaOf420SkipsTheFinestLevel() {
        let layout = PyramidLayout(width: 1920, height: 1080, chroma: .yuv420)
        #expect(layout.levels(of: 0) == 0...4)
        #expect(layout.levels(of: 1) == 1...4)
        #expect(layout.planeSize(of: 1) == (960, 540))
        let full = PyramidLayout(width: 1920, height: 1080, chroma: .yuv444)
        #expect(full.levels(of: 2) == 0...4)
        #expect(full.planeSize(of: 2) == (1920, 1080))
    }

    @Test func passesRunCoarsestFirstAndEndInPlanes() {
        let passes = PyramidLayout(width: 1920, height: 1080, chroma: .yuv420).passes()
        #expect(passes.count == 13)  // four levels of three components and the luma level 0
        #expect(passes.first?.level == 4)
        #expect(passes.map(\.level) == passes.map(\.level).sorted(by: >))
        #expect(passes.filter(\.writesPlane).map(\.component).sorted() == [0, 1, 2])
        #expect(passes.last == PyramidLayout.Pass(component: 0, level: 0, writesPlane: true, groupsAlongRows: 34, groupsAlongColumns: 60))
        #expect(PyramidLayout(width: 1920, height: 1080, chroma: .yuv444).passes().count == 15)
    }

    @Test func threadgroupsCoverTheBandImage() {
        for pass in PyramidLayout(width: 3840, height: 2160, chroma: .yuv444).passes() {
            let size = PyramidLayout(width: 3840, height: 2160, chroma: .yuv444).bandSize(level: pass.level)
            #expect(pass.groupsAlongRows * 16 >= size.height && (pass.groupsAlongRows - 1) * 16 < size.height)
            #expect(pass.groupsAlongColumns * 16 >= size.width && (pass.groupsAlongColumns - 1) * 16 < size.width)
        }
    }

    @Test func precisionOneKeepsTheCoarseLevelsInThirtyTwoBits() {
        #expect(IDWTDecoder.pixelFormat(level: 0, precision: .float) == .r16Float)
        #expect(IDWTDecoder.pixelFormat(level: 1, precision: .float) == .r16Float)
        #expect(IDWTDecoder.pixelFormat(level: 2, precision: .float) == .r32Float)
        #expect(IDWTDecoder.pixelFormat(level: 4, precision: .half) == .r16Float)
    }
}

// MARK: CPU reference

@Suite struct ReferenceTests {
    @Test func oneDimensionalTransformIsInvertible() {
        let signal = (0..<64).map { sin(Double($0) * 0.3) + Double($0 % 5) * 0.1 }
        let restored = CDF97.inverse(CDF97.forward(signal))
        for (a, b) in zip(signal, restored) { #expect(abs(a - b) < 1e-12) }
    }

    @Test func aConstantSignalHasNoHighPass() {
        let transformed = CDF97.forward([Double](repeating: 0.25, count: 32))
        for index in stride(from: 1, to: 32, by: 2) { #expect(abs(transformed[index]) < 1e-12) }
        for index in stride(from: 0, to: 32, by: 2) { #expect(abs(transformed[index] - 0.25) < 1e-12) }
    }

    @Test func pyramidRoundTrips() {
        let image = Plane(width: 128, height: 96) { x, y in 0.5 + 0.3 * sin(Double(x) * 0.11) * cos(Double(y) * 0.07) }
        let restored = Wavelet2D.inversePyramid(Wavelet2D.forwardPyramid(image, levelCount: 5))
        #expect(restored.width == 128 && restored.height == 96)
        for (a, b) in zip(image.values, restored.values) { #expect(abs(a - b) < 1e-10) }
    }
}

// MARK: GPU against the reference

private func testImage(width: Int, height: Int, phase: Double) -> Plane {
    Plane(width: width, height: height) { x, y in
        let smooth = 0.5 + 0.3 * sin(Double(x) * 0.07 + phase) * cos(Double(y) * 0.05)
        let edge = (x / 16 + y / 16) % 2 == 0 ? 0.08 : -0.08
        return min(max(smooth + edge, 0), 1)
    }
}

private func psnr(_ a: Plane, _ b: Plane) -> Double {
    let error = zip(a.values, b.values).reduce(0.0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Double(a.values.count)
    return error == 0 ? .infinity : -10 * log10(error)
}

private let hasDevice = MTLCreateSystemDefaultDevice() != nil

@Suite(.enabled(if: hasDevice, "needs a Metal device")) struct KernelTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let width: Int
        let height: Int
        let chroma: Chroma
        let math: MathPrecision
        var testDescription: String { "\(width)x\(height) \(chroma.rawValue) \(math.rawValue)" }
    }

    static let cases: [Case] = [
        Case(width: 192, height: 128, chroma: .yuv420, math: .float),
        Case(width: 192, height: 128, chroma: .yuv444, math: .float),
        Case(width: 200, height: 136, chroma: .yuv420, math: .float),  // not a multiple of 32: padding and cropping
        Case(width: 200, height: 136, chroma: .yuv444, math: .half),
        Case(width: 416, height: 270, chroma: .yuv420, math: .float),  // the apron crosses threadgroups on every level
        Case(width: 256, height: 160, chroma: .yuv420, math: .half),
    ]

    /// Decodes the pyramid of a test image on the GPU and checks it against the CPU transform of the same
    /// (16-bit-rounded) coefficients and against the original picture.
    @Test(arguments: cases) func decodesLikeTheReference(_ test: Case) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let layout = PyramidLayout(width: test.width, height: test.height, chroma: test.chroma)
        let decoder = try IDWTDecoder(device: device, layout: layout, precision: test.math, tenBitPlanes: true)

        var originals: [Plane] = []
        for component in 0..<PyramidLayout.components {
            let size = layout.planeSize(of: component)
            let original = testImage(width: size.width, height: size.height, phase: Double(component))
            originals.append(original)

            // PyroWave pads to the aligned size by repeating the edge, removes the DC level and transforms.
            let alignedWidth = test.chroma == .yuv420 && component != 0 ? layout.alignedWidth / 2 : layout.alignedWidth
            let alignedHeight = test.chroma == .yuv420 && component != 0 ? layout.alignedHeight / 2 : layout.alignedHeight
            var padded = original.padded(width: alignedWidth, height: alignedHeight)
            padded.values = padded.values.map { $0 - 0.5 }
            let levelRange = layout.levels(of: component)
            var pyramid = Wavelet2D.forwardPyramid(padded, levelCount: levelRange.count)

            // What the GPU sees: coefficients rounded to the storage format.
            for index in pyramid.indices {
                let level = levelRange.lowerBound + index
                let layers = pyramid[index].layers
                let layerRange = level == PyramidLayout.levels - 1 ? 0..<4 : 1..<4
                var rounded = layers
                for layer in layerRange {
                    rounded[layer] = try decoder.upload(layers[layer], component: component, level: level, layer: layer, queue: queue)
                }
                pyramid[index] = Bands(ll: rounded[0], hl: rounded[1], lh: rounded[2], hh: rounded[3])
            }

            try decoder.runOnce(queue: queue)
            let gpu = try decoder.readPlane(component, queue: queue)

            let reference = Wavelet2D.inversePyramid(pyramid)
                .cropped(width: size.width, height: size.height)
            let expected = Plane(width: size.width, height: size.height, values: reference.values.map { min(max($0 + 0.5, 0), 1) })

            // fp16 storage of the intermediate levels limits the float-math result to about 76 dB, half math to about 65 dB.
            let worst = zip(gpu.values, expected.values).map { abs($0 - $1) }.max() ?? 0
            let floor = test.math == .float ? 70.0 : 60.0
            #expect(worst < 0.006, "component \(component): largest difference to the reference \(worst)")
            #expect(psnr(gpu, expected) > floor, "component \(component): PSNR to the reference \(psnr(gpu, expected))")
            #expect(psnr(gpu, original) > floor - 2, "component \(component): PSNR to the original \(psnr(gpu, original))")
            // The other components are transformed again on the next iteration, which is harmless.
        }
    }

    @Test func aZeroPyramidDecodesToMidGray() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let layout = PyramidLayout(width: 160, height: 128, chroma: .yuv444)
        let decoder = try IDWTDecoder(device: device, layout: layout, precision: .float, tenBitPlanes: true)
        // New private textures are not guaranteed to be zero: upload zeros everywhere.
        for component in 0..<PyramidLayout.components {
            for level in layout.levels(of: component) {
                let size = layout.bandSize(level: level)
                let zero = Plane(width: size.width, height: size.height, values: [Double](repeating: 0, count: size.width * size.height))
                for layer in 0..<4 { try decoder.upload(zero, component: component, level: level, layer: layer, queue: queue) }
            }
        }
        try decoder.runOnce(queue: queue)
        for component in 0..<PyramidLayout.components {
            let plane = try decoder.readPlane(component, queue: queue)
            for value in plane.values { #expect(abs(value - 0.5) < 1.0 / 65535 + 1e-9) }
        }
    }
}
