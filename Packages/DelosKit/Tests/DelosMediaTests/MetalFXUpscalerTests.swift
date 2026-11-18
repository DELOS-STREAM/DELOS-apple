import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import Testing
@testable import DelosMedia

/// MetalFX Spatial and Temporal: the scaler sizes, the fallback without MetalFX, the motion vectors and reactive mask made
/// from decoded video, the temporal scaler's settings, and both scalers running on this Mac's GPU.
@Suite struct MetalFXUpscalerTests {
    // MARK: Sizes and modes

    @Test func theScalerOutputEnlargesTheStreamByOneFactor() {
        let any: ClosedRange<Float> = 1...Float.greatestFiniteMagnitude
        // 1080p into 1440p: 4/3 on both axes
        #expect(MetalUpscaler.scalerOutput(input: (1920, 1080), target: (2560, 1440), scales: any)! == (2560, 1440))
        // A wider picture (Stretch): the smaller factor, the aspect ratio kept; the presentation stretches the rest
        #expect(MetalUpscaler.scalerOutput(input: (1920, 1080), target: (3840, 1600), scales: any)! == (2844, 1600))
        // The temporal scaler's largest factor caps it
        #expect(MetalUpscaler.scalerOutput(input: (1280, 720), target: (3840, 2160), scales: 1...2)! == (2560, 1440))
        // MetalFX only enlarges: a stream as large as the picture or larger, or a factor below the scaler's smallest, has none
        #expect(MetalUpscaler.scalerOutput(input: (1920, 1080), target: (1920, 1080), scales: any) == nil)
        #expect(MetalUpscaler.scalerOutput(input: (3840, 2160), target: (1920, 1080), scales: any) == nil)
        #expect(MetalUpscaler.scalerOutput(input: (1920, 1080), target: (2400, 1350), scales: 1.5...3) == nil)
        #expect(MetalUpscaler.scalerOutput(input: (0, 0), target: (100, 100), scales: any) == nil)
    }

    @Test func withoutMetalFXEveryModeFallsBackToSharpenOnly() {
        #expect(MetalFXSupport.none.effectiveMode(.spatial) == .sharpen)
        #expect(MetalFXSupport.none.effectiveMode(.temporal) == .sharpen)
        #expect(MetalFXSupport.none.effectiveMode(.sharpen) == .sharpen)
        let spatialOnly = MetalFXSupport(spatial: true, temporal: false, temporalScale: 1...1)
        #expect(spatialOnly.effectiveMode(.spatial) == .spatial && spatialOnly.effectiveMode(.temporal) == .sharpen)
        #expect(MetalFXSupport.probe(nil) == .none)
    }

    @Test func aVideoFrameHasNoJitterAndMotionInInputPixels() {
        let frame = TemporalFrame(inputWidth: 1920, inputHeight: 1080, reset: false)
        #expect(frame.jitter == .zero)
        #expect(frame.motionVectorScale == SIMD2(1, 1))
        #expect(!frame.depthReversed)
        #expect(MetalFXScaler.depth == 0.5)
    }

    @Test func theHistoryStartsAgainAfterAGapAnOutOfOrderFrameOrAnHDRChange() {
        #expect(VideoMotion.startsAgain(valid: false, previous: 1, timestamp: 1.016, hdrChanged: false))
        #expect(!VideoMotion.startsAgain(valid: true, previous: 1, timestamp: 1.016, hdrChanged: false))
        #expect(VideoMotion.startsAgain(valid: true, previous: 1, timestamp: 1.06, hdrChanged: false))
        #expect(VideoMotion.startsAgain(valid: true, previous: 1, timestamp: 1, hdrChanged: false))
        #expect(VideoMotion.startsAgain(valid: true, previous: 1, timestamp: 1.016, hdrChanged: true))
    }

    // MARK: Motion of decoded video

    /// Runs the motion passes for `first` then `second` (1/60 s apart) and returns the second frame's motion vectors and
    /// reactive mask, row by row.
    private func motion(
        _ first: ReferenceImage, then second: ReferenceImage
    ) throws -> (motion: [SIMD2<Float>], mask: [Float], width: Int, height: Int) {
        let drawer = try UpscalerGPU.drawer()
        let motion = try #require(VideoMotion(cache: drawer.cache, width: first.width, height: first.height, usage: []))
        for (index, picture) in [first, second].enumerated() {
            let command = try #require(drawer.queue.makeCommandBuffer())
            let texture = try picture.texture(drawer.device)
            let reset = try #require(motion.render(
                source: texture, timestamp: 1 + Double(index) / 60, hdr: false, commandBuffer: command) as Bool?)
            #expect(reset == (index == 0))
            command.commit()
            command.waitUntilCompleted()
        }
        let vectors: [Float16] = try readBack(motion.motion, drawer: drawer, channels: 2)
        let mask: [Float16] = try readBack(motion.reactiveMask, drawer: drawer, channels: 1)
        let pairs = stride(from: 0, to: vectors.count, by: 2).map { SIMD2(Float(vectors[$0]), Float(vectors[$0 + 1])) }
        return (pairs, mask.map(Float.init), first.width, first.height)
    }

    /// A private texture's half floats, copied into a shared one.
    private func readBack(_ texture: any MTLTexture, drawer: MetalFrameDrawer, channels: Int) throws -> [Float16] {
        let description = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
        description.storageMode = .shared
        let shared = try #require(drawer.device.makeTexture(descriptor: description))
        let command = try #require(drawer.queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        var values = [Float16](repeating: 0, count: texture.width * texture.height * channels)
        shared.getBytes(
            &values, bytesPerRow: texture.width * channels * 2, from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0)
        return values
    }

    /// A smooth, non-repeating scene with detail at every scale (a stripe pattern would alias in the pyramid's coarse
    /// levels, as a repeating texture in a game does).
    private static func scene(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let fx = Float(x), fy = Float(y)
        let value = 0.5 + 0.2 * sin(fx * 0.13 + 0.7 * sin(fy * 0.05)) + 0.2 * cos(fy * 0.11 + 0.5 * sin(fx * 0.07))
            + 0.08 * sin(fx * 0.41 + fy * 0.29)
        return SIMD4(value, value * 0.9 + 0.05, 1 - value, 1)
    }

    @Test func theFlowGivesMetalFXsMotionVectors() throws {
        // The picture moves 3 pixels right and 2 down: every pixel was 3 left and 2 up before, (-3, -2) in MetalFX's
        // convention (motion vector scale 1)
        let before = ReferenceImage(width: 128, height: 96) { x, y in Self.scene(x, y) }.quantized
        let after = ReferenceImage(width: 128, height: 96) { x, y in Self.scene(x - 3, y - 2) }.quantized
        let result = try motion(before, then: after)
        var inner: [SIMD2<Float>] = [], mask: [Float] = []
        for y in 16..<(result.height - 16) {
            for x in 16..<(result.width - 16) {
                inner.append(result.motion[y * result.width + x])
                mask.append(result.mask[y * result.width + x])
            }
        }
        // Nine pixels in ten within a tenth of a pixel; a consistent flow leaves most of the history usable
        for (values, expected) in [(inner.map(\.x).sorted(), Float(-3)), (inner.map(\.y).sorted(), -2)] {
            #expect(abs(values[values.count / 10] - expected) < 0.1 && abs(values[values.count * 9 / 10] - expected) < 0.1)
        }
        #expect(mask.reduce(0, +) / Float(mask.count) < 0.3)
    }

    @Test func aStillPictureKeepsTheHistoryAndACutDropsIt() throws {
        let picture = ReferenceImage(width: 128, height: 96) { x, y in Self.scene(x, y) }.quantized
        let still = try motion(picture, then: picture)
        #expect(still.motion.allSatisfy { abs($0.x) < 0.5 && abs($0.y) < 0.5 })
        #expect(still.mask.reduce(0, +) / Float(still.mask.count) < 0.25)
        // A cut: every pixel ignores the history
        let inverted = ReferenceImage(width: 128, height: 96) { x, y in
            let p = picture.texel(x, y)
            return SIMD4(1 - p.x, 1 - p.y, 1 - p.z, 1)
        }
        let cut = try motion(picture, then: inverted)
        #expect(cut.mask.allSatisfy { $0 > 0.99 })
    }

    // MARK: MetalFX on this GPU

    #if canImport(MetalFX)
    @Test(.enabled(if: MetalFXSupport.system.temporal)) func theTemporalScalerTakesTheVideoSettings() throws {
        let drawer = try UpscalerGPU.drawer()
        let key = MetalFXScaler.Key(
            mode: .temporal, inputWidth: 128, inputHeight: 72, outputWidth: 256, outputHeight: 144, format: .rgba8Unorm)
        let description = MetalFXScaler.temporalDescriptor(key)
        #expect(description.depthTextureFormat == .depth32Float && description.motionTextureFormat == .rg16Float)
        #expect(description.isReactiveMaskTextureEnabled && description.reactiveMaskTextureFormat == .r16Float)
        #expect(!description.isAutoExposureEnabled && !description.isInputContentPropertiesEnabled)
        let scaler = try #require(description.makeTemporalScaler(device: drawer.device))
        MetalFXScaler.configure(scaler, TemporalFrame(inputWidth: 128, inputHeight: 72, reset: true))
        #expect(scaler.jitterOffsetX == 0 && scaler.jitterOffsetY == 0)
        #expect(scaler.motionVectorScaleX == 1 && scaler.motionVectorScaleY == 1)
        #expect(!scaler.isDepthReversed && scaler.reset)
        #expect(scaler.inputContentWidth == 128 && scaler.inputContentHeight == 72)
    }
    #endif

    @Test(.enabled(if: MetalFXSupport.system.spatial && MetalFXSupport.system.temporal))
    func bothScalersUpscaleOnThisGPU() throws {
        let drawer = try UpscalerGPU.drawer()
        let picture = ReferenceImage.pattern(width: 128, height: 72)
        let flat = ReferenceImage.uniform(SIMD4(0.3, 0.6, 0.2, 1), width: 128, height: 72)
        let bilinear = ReferenceImage(width: 256, height: 144) { x, y in picture.sample((Float(x) + 0.5) / 256, (Float(y) + 0.5) / 144) }
        for mode in [UpscalerMode.spatial, .temporal] {
            // 8-bit SDR and the half floats of 10-bit streams
            for format in [MTLPixelFormat.rgba8Unorm, .rgba16Float] {
                let upscaler = MetalUpscaler(cache: drawer.cache, support: .system)
                for (image, reference) in [(flat, ReferenceImage.uniform(SIMD4(0.3, 0.6, 0.2, 1), width: 256, height: 144)), (picture, bilinear)] {
                    let source = try sourceTexture(image, format: format, drawer: drawer)
                    var output = ReferenceImage(width: 1, height: 1) { _, _ in .zero }
                    for frame in 0..<3 {
                        let command = try #require(drawer.queue.makeCommandBuffer())
                        let made = try #require(upscaler.upscale(
                            source: source, mode: mode, presentation: (256, 144), supersamplingLevel: 1,
                            frameTime: 1 + Double(frame) / 60, hdr: format == .rgba16Float, commandBuffer: command))
                        #expect(made.texture.width == 256 && made.texture.height == 144 && made.sharpenAtPresentation)
                        #expect(made.dimensions.internalWidth == 256 && !made.dimensions.isSupersampling)
                        let readable = try UpscalerGPU.target(drawer.device, width: 256, height: 144)
                        #expect(upscaler.present(
                            made, sharpness: 0, into: readable, viewport: nil, crop: MetalPipelineCache.wholePicture,
                            commandBuffer: command))
                        command.commit()
                        command.waitUntilCompleted()
                        #expect(command.status == .completed && command.error == nil)
                        output = UpscalerGPU.read(readable)
                    }
                    #expect(output.pixels.allSatisfy { p in (0..<3).allSatisfy { p[$0] >= 0 && p[$0] <= 1 && !p[$0].isNaN } })
                    // A reconstruction of the same picture, not a different one
                    #expect(UpscalerGPU.meanDifference(output, reference) < 0.05, "\(mode) \(format.rawValue)")
                }
            }
        }
    }

    /// A camera pan over a band-limited scene with the noise of a compressed stream: each frame is the scene averaged over
    /// its pixels (`scale` pixels per scene unit), shifted by `offset` scene units, with ±`noise` per channel.
    private static func panFrame(
        width: Int, height: Int, scale: Float, offset: SIMD2<Float>, noise: Float, seed: UInt32
    ) -> ReferenceImage {
        var state = seed
        func random() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24) - 0.5
        }
        let samples = 4
        return ReferenceImage(width: width, height: height) { i, j in
            var sum: Float = 0
            for a in 0..<samples {
                for b in 0..<samples {
                    let x = (Float(i) + (Float(a) + 0.5) / Float(samples)) / scale + offset.x
                    let y = (Float(j) + (Float(b) + 0.5) / Float(samples)) / scale + offset.y
                    sum += 0.5 + 0.2 * sin(x * 0.9 + 0.7 * sin(y * 0.05)) + 0.2 * cos(y * 0.8 + 0.5 * sin(x * 0.07))
                        + 0.08 * sin(x * 1.9 + y * 1.3)
                }
            }
            let v = sum / Float(samples * samples)
            return SIMD4(v + random() * noise, v * 0.8 + 0.1 + random() * noise, 1 - v + random() * noise, 1)
        }
    }

    /// The mean absolute RGB difference of two pictures inside a border (the scalers treat the edges differently).
    private static func innerError(_ a: ReferenceImage, _ b: ReferenceImage, border: Int) -> Float {
        var sum: Float = 0, count: Float = 0
        for y in border..<(a.height - border) {
            for x in border..<(a.width - border) {
                let p = a.pixels[y * a.width + x], q = b.pixels[y * a.width + x]
                sum += (abs(p.x - q.x) + abs(p.y - q.y) + abs(p.z - q.z)) / 3
                count += 1
            }
        }
        return sum / count
    }

    @Test(.enabled(if: MetalFXSupport.system.spatial && MetalFXSupport.system.temporal))
    func theTemporalScalerUsesItsHistoryOnAMovingPicture() throws {
        // The whole temporal path (motion, reactive mask, MTLFXTemporalScaler) on a pan of 0.37 × 0.23 pixels a frame,
        // compared with the scene at the output size: its first frame has no history, the following ones accumulate
        let drawer = try UpscalerGPU.drawer()
        let (width, height, frames) = (160, 90, 10)
        let step = SIMD2<Float>(0.37, 0.23)
        var temporalErrors: [Float] = [], spatialDifferences: [Float] = [], masks: [Float] = []
        let temporal = MetalUpscaler(cache: drawer.cache, support: .system)
        let spatial = MetalUpscaler(cache: drawer.cache, support: .system)
        for frame in 0..<frames {
            let offset = step * Float(frame)
            let input = Self.panFrame(width: width, height: height, scale: 1, offset: offset, noise: 0.06, seed: UInt32(frame + 1))
                .quantized
            let truth = Self.panFrame(width: width * 2, height: height * 2, scale: 2, offset: offset, noise: 0, seed: 0)
            let source = try input.texture(drawer.device)
            var outputs: [ReferenceImage] = []
            for (upscaler, mode) in [(temporal, UpscalerMode.temporal), (spatial, .spatial)] {
                let command = try #require(drawer.queue.makeCommandBuffer())
                let made = try #require(upscaler.upscale(
                    source: source, mode: mode, presentation: (width * 2, height * 2), supersamplingLevel: 1,
                    frameTime: 1 + Double(frame) / 60, hdr: false, commandBuffer: command))
                let readable = try UpscalerGPU.target(drawer.device, width: width * 2, height: height * 2)
                #expect(upscaler.present(
                    made, sharpness: 0, into: readable, viewport: nil, crop: MetalPipelineCache.wholePicture, commandBuffer: command))
                command.commit()
                command.waitUntilCompleted()
                outputs.append(UpscalerGPU.read(readable))
            }
            let motion = try #require(temporal.motion)
            let mask: [Float16] = try readBack(motion.reactiveMask, drawer: drawer, channels: 1)
            masks.append(mask.map(Float.init).reduce(0, +) / Float(mask.count))
            temporalErrors.append(Self.innerError(outputs[0], truth, border: 16))
            spatialDifferences.append(Self.innerError(outputs[0], outputs[1], border: 16))
        }
        // MetalFX may use the history at most pixels: the reactive mask stays low after the first frame
        #expect(masks.dropFirst().allSatisfy { $0 < 0.35 }, "\(masks)")
        // The temporal result is its own, not MetalFX Spatial's
        #expect(spatialDifferences.dropFirst().allSatisfy { $0 > 0.003 }, "\(spatialDifferences)")
        // The accumulated history brings it closer to the scene than the first frame, which had none
        let accumulated = temporalErrors[3...].reduce(0, +) / Float(temporalErrors.count - 3)
        #expect(accumulated < temporalErrors[0] * 0.92, "\(temporalErrors)")
    }

    /// `image` as the scalers' colour input (``MetalUpscaler/sourceUsage``) in `format`.
    private func sourceTexture(_ image: ReferenceImage, format: MTLPixelFormat, drawer: MetalFrameDrawer) throws -> any MTLTexture {
        let plain = try image.texture(drawer.device)
        let source = try #require(drawer.cache.texture(format, width: image.width, height: image.height, usage: MetalUpscaler.sourceUsage))
        let command = try #require(drawer.queue.makeCommandBuffer())
        #expect(drawer.cache.draw(
            "casFragment", into: source, textures: [plain], uniforms: CASUniforms(sampled: (image.width, image.height), strength: 0),
            commandBuffer: command))
        command.commit()
        command.waitUntilCompleted()
        return source
    }
}
