import CoreMedia
import Foundation
import Metal
import Synchronization
import Testing
@testable import DelosMedia

/// The upscaler's shaders against their CPU references, its geometry, and the pipeline's upscaler states.
@Suite struct UpscalerRenderingTests {
    let picture = ReferenceImage.pattern(width: 48, height: 32)

    @Test func sharpenOnlyIsAndroidsCASOnTheFiveSampleCross() throws {
        for sharpness: Float in [0, 0.5, 1] {
            let gpu = try UpscalerGPU.run(
                "sharpenOnlyFragment", source: picture, width: picture.width, height: picture.height,
                uniforms: UpscaleUniforms(sampled: (48, 32), stream: (48, 32), strength: sharpness, enabled: true))
            #expect(UpscalerGPU.difference(gpu, UpscalerReference.sharpenOnly(picture, sharpness: sharpness)) < 2e-3)
        }
    }

    @Test func sharpenOnlyLeavesFlatAreasAlone() throws {
        let flat = ReferenceImage.uniform(SIMD4(0.4, 0.5, 0.6, 1), width: 16, height: 16)
        let gpu = try UpscalerGPU.run(
            "sharpenOnlyFragment", source: flat, width: 16, height: 16,
            uniforms: UpscaleUniforms(sampled: (16, 16), stream: (16, 16), strength: 1, enabled: true))
        #expect(UpscalerGPU.difference(gpu, flat) < 1e-3)
    }

    @Test func theSpatialPresentationSharpensWithinItsBound() throws {
        for strength: Float in [0, 0.5, 1] {
            let gpu = try UpscalerGPU.run(
                "supersamplePresentFragment", source: picture, width: picture.width, height: picture.height,
                uniforms: UpscaleUniforms(sampled: (48, 32), stream: (48, 32), strength: strength, enabled: true))
            #expect(UpscalerGPU.difference(gpu, UpscalerReference.supersamplePresent(picture, strength: strength)) < 2e-3)
        }
    }

    @Test func sgsr1StandardMatchesTheReferenceAtTwiceTheSize() throws {
        let gpu = try UpscalerGPU.run(
            "sgsr1Fragment", source: picture, width: 96, height: 64,
            uniforms: UpscaleUniforms(sampled: (48, 32), stream: (48, 32), strength: 0, enabled: true))
        let reference = UpscalerReference.sgsr1(picture, width: 96, height: 64)
        // The GPU's float rounding may tip a pixel across the edge threshold: at most one in a thousand, and never by more
        // than the shader's clamp of 23/255
        #expect(UpscalerGPU.mismatches(gpu, reference, above: 5e-3) <= gpu.pixels.count / 1000)
        #expect(UpscalerGPU.difference(gpu, reference) <= 23.0 / 255.0 + 1e-3)
        // The reconstruction does something: it is not the plain bilinear picture
        let bilinear = ReferenceImage(width: 96, height: 64) { x, y in picture.sample((Float(x) + 0.5) / 96, (Float(y) + 0.5) / 64) }
        #expect(UpscalerGPU.difference(gpu, bilinear) > 0.02)
    }

    @Test func sgsr1HighKeepsAFlatPictureAndStaysInRange() throws {
        let flat = ReferenceImage.uniform(SIMD4(0.3, 0.6, 0.2, 1), width: 24, height: 16)
        let flatOut = try UpscalerGPU.run(
            "sgsr1HighFragment", source: flat, width: 48, height: 32,
            uniforms: UpscaleUniforms(sampled: (24, 16), stream: (24, 16), strength: 0, enabled: true))
        #expect(UpscalerGPU.difference(flatOut, ReferenceImage.uniform(SIMD4(0.3, 0.6, 0.2, 1), width: 48, height: 32)) < 1e-3)
        let out = try UpscalerGPU.run(
            "sgsr1HighFragment", source: picture, width: 96, height: 64,
            uniforms: UpscaleUniforms(sampled: (48, 32), stream: (48, 32), strength: 0, enabled: true))
        #expect(out.pixels.allSatisfy { p in (0..<3).allSatisfy { p[$0] >= 0 && p[$0] <= 1 && !p[$0].isNaN } })
    }

    @Test func sgsr2StartsItsHistoryWithTheClampedLanczosUpsample() throws {
        let drawer = try UpscalerGPU.drawer()
        let source = try picture.texture(drawer.device)
        let temporal = try #require(TemporalReconstruction(cache: drawer.cache, width: 48, height: 32))
        var outputs: [ReferenceImage] = []
        for frame in 0..<3 {
            let command = try #require(drawer.queue.makeCommandBuffer())
            let history = try #require(temporal.render(
                source: source, output: (96, 64), timestamp: Double(frame) / 60, hdr: false, quality: frame == 2, reuseFlow: false,
                commandBuffer: command))
            let readable = try UpscalerGPU.target(drawer.device, width: 96, height: 64)
            // The history is half floats: copied through a plain presentation into a readable target
            #expect(drawer.cache.draw(
                "supersamplePresentFragment", into: readable, textures: [history],
                uniforms: UpscaleUniforms(sampled: (96, 64), stream: (48, 32), strength: 0, enabled: true), commandBuffer: command))
            command.commit()
            command.waitUntilCompleted()
            outputs.append(UpscalerGPU.read(readable))
        }
        #expect(UpscalerGPU.difference(outputs[0], UpscalerReference.temporalReset(picture, width: 96, height: 64)) < 3e-3)
        // A still picture stays nearly still: the history clipped to the neighbourhood's box blends back in, in both modes
        #expect(UpscalerGPU.meanDifference(outputs[1], outputs[0]) < 1e-2)
        #expect(UpscalerGPU.meanDifference(outputs[2], outputs[0]) < 1e-2)
        #expect(outputs.allSatisfy { $0.pixels.allSatisfy { p in (0..<3).allSatisfy { p[$0] >= 0 && p[$0] <= 1 } } })
    }

    @Test func aGapLongerThanFiftyMillisecondsStartsTheHistoryAgain() throws {
        let drawer = try UpscalerGPU.drawer()
        let bright = try ReferenceImage.uniform(SIMD4(0.9, 0.9, 0.9, 1), width: 16, height: 16).texture(drawer.device)
        let dark = try ReferenceImage.uniform(SIMD4(0.1, 0.1, 0.1, 1), width: 16, height: 16).texture(drawer.device)
        let temporal = try #require(TemporalReconstruction(cache: drawer.cache, width: 16, height: 16))
        func render(_ source: any MTLTexture, at time: Double) throws -> ReferenceImage {
            let command = try #require(drawer.queue.makeCommandBuffer())
            let history = try #require(temporal.render(
                source: source, output: (32, 32), timestamp: time, hdr: false, quality: false, reuseFlow: false, commandBuffer: command))
            let readable = try UpscalerGPU.target(drawer.device, width: 32, height: 32)
            _ = drawer.cache.draw(
                "supersamplePresentFragment", into: readable, textures: [history],
                uniforms: UpscaleUniforms(sampled: (32, 32), stream: (16, 16), strength: 0, enabled: true), commandBuffer: command)
            command.commit()
            command.waitUntilCompleted()
            return UpscalerGPU.read(readable)
        }
        _ = try render(bright, at: 1)
        // After a gap the old picture is not blended in at all
        let after = try render(dark, at: 1.2)
        #expect(UpscalerGPU.difference(after, ReferenceImage.uniform(SIMD4(0.1, 0.1, 0.1, 1), width: 32, height: 32)) < 2e-3)
    }

    // MARK: Geometry

    @Test func fitFillAndStretchPlaceThePicture() {
        let fit = PictureGeometry.make(video: (1920, 1080), target: (2000, 1500), mode: .fit)
        #expect(fit.viewport.width == 2000 && fit.viewport.height == 1125 && fit.viewport.originY == 188)
        #expect(fit.crop == SIMD4(0, 0, 1, 1))
        #expect(fit.presentationWidth == 2000 && fit.presentationHeight == 1125)

        let stretch = PictureGeometry.make(video: (1920, 1080), target: (2000, 1500), mode: .stretch)
        #expect(stretch.viewport.width == 2000 && stretch.viewport.height == 1500 && stretch.crop == SIMD4(0, 0, 1, 1))

        // Fill covers the target: the picture is 2667 × 1500 and its middle 2000 columns are shown
        let fill = PictureGeometry.make(video: (1920, 1080), target: (2000, 1500), mode: .fill)
        #expect(fill.viewport.width == 2000 && fill.viewport.height == 1500)
        #expect(fill.presentationWidth == 2667 && fill.presentationHeight == 1500)
        #expect(abs(fill.crop.z - 2000.0 / 2667.0) < 1e-6 && fill.crop.w == 1)
        #expect(abs(fill.crop.x - (1 - 2000.0 / 2667.0) / 2) < 1e-6 && fill.crop.y == 0)
    }

    @Test func theScaleModesDrawTheFixtureWhereTheyShould() throws {
        // The 64 × 64 fixture into a 128 × 64 target: Fit leaves black bars left and right, Stretch and Fill cover it
        for (mode, barred) in [(VideoScaleMode.fit, true), (.stretch, false), (.fill, false)] {
            let clock = VirtualClock()
            let pipeline = try #require(MetalPipeline(pacing: .latency, fps: 60, options: VideoRenderOptions(scaleMode: mode), clock: clock.reading))
            defer { pipeline.invalidate() }
            pipeline.useOffscreenSize(width: 128, height: 64)
            var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
            clock.set(1)
            #expect(pipeline.enqueue(try stream.sample(0)))
            pipeline.waitForDecodes()
            pipeline.tick(RefreshTick(presentation: 1.02, refresh: 1.0 / 60, drawable: nil))
            let pixels = try #require(pipeline.offscreenPixels())
            #expect(pixels.width == 128)
            let corner = Array(pixels.bytes[0..<3])
            #expect((corner == [0, 0, 0]) == barred)
        }
    }

    // MARK: The pipeline's upscaler

    @Test func theUpscalerStartsRunsAndStops() throws {
        let clock = VirtualClock()
        let options = VideoRenderOptions(upscaler: UpscalerSettings(enabled: true, mode: .standard))
        let pipeline = try #require(MetalPipeline(pacing: .latency, fps: 60, options: options, clock: clock.reading))
        defer { pipeline.invalidate() }
        pipeline.useOffscreenSize(width: 128, height: 128)
        #expect(pipeline.upscalerStatus == .starting)
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        clock.set(1)
        #expect(pipeline.enqueue(try stream.sample(0)))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 1.02, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.standard))
        #expect(!pipeline.isSupersampling)
        var counters = pipeline.counters()
        #expect(counters.scaleDescription == "Upscaled to: 128 × 128")
        #expect(counters.upscalingMilliseconds != nil)

        // Sharpen only keeps the stream's size; the picture is drawn again at the next refresh without a new frame
        pipeline.setUpscaler(UpscalerSettings(enabled: true, mode: .sharpen, sharpness: 80))
        clock.set(1.03)
        pipeline.tick(RefreshTick(presentation: 1.04, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.standard))
        clock.set(1.05)
        #expect(pipeline.enqueue(try stream.sample(1)))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 1.06, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.sharpen))
        // The GPU times arrive in the command buffers' completion handlers
        Thread.sleep(forTimeInterval: 0.3)
        counters = pipeline.counters()
        #expect(counters.scaleDescription == "Sharpen only: 64 × 64")
        #expect(counters.sharpen?.prepareName == "conversion")
        #expect(counters.sharpen?.gpuTimed == true)

        pipeline.setUpscaler(UpscalerSettings(enabled: false, mode: .sharpen))
        #expect(pipeline.upscalerStatus == .stopping)
        // Switching off redraws the last picture plainly
        pipeline.tick(RefreshTick(presentation: 1.08, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .off)
        #expect(pipeline.counters().scaleDescription == nil)
    }

    @Test func aStreamThatMatchesTheViewIsSupersampled() throws {
        let clock = VirtualClock()
        let options = VideoRenderOptions(upscaler: UpscalerSettings(enabled: true, mode: .temporal, supersamplingLevel: 2))
        let pipeline = try #require(MetalPipeline(pacing: .latency, fps: 60, options: options, clock: clock.reading))
        defer { pipeline.invalidate() }
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        for frame in 0..<2 {
            clock.set(1 + Double(frame) / 60)
            #expect(pipeline.enqueue(try stream.sample(frame)))
            pipeline.waitForDecodes()
            pipeline.tick(RefreshTick(presentation: 1.01 + Double(frame) / 60, refresh: 1.0 / 60, drawable: nil))
        }
        #expect(pipeline.upscalerStatus == .on(.temporal))
        #expect(pipeline.isSupersampling)
        #expect(pipeline.counters().scaleDescription == "Supersampled to: 128 × 128")
    }

    @Test func theDisplayLayerReportsARequestedUpscalerAsUnavailable() async {
        let layer = await DisplayLayerRenderer(pacing: .latency, fps: 60)
        #expect(layer.upscalerStatus == .off)
        layer.setUpscaler(UpscalerSettings(enabled: true))
        #expect(layer.upscalerStatus == .unavailable)
    }

    @Test func theDisplayLayerTakesTheScaleModesGravity() {
        #expect(DisplayLayerRenderer.gravity(.fit) == .resizeAspect)
        #expect(DisplayLayerRenderer.gravity(.fill) == .resizeAspectFill)
        #expect(DisplayLayerRenderer.gravity(.stretch) == .resize)
    }
}
