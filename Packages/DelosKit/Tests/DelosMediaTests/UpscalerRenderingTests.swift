import CoreMedia
import Foundation
import Metal
import Synchronization
import Testing
@testable import DelosMedia

/// The upscaler's CAS pass against its CPU reference, its geometry, and the pipeline's upscaler states. MetalFX itself:
/// MetalFXUpscalerTests.
@Suite struct UpscalerRenderingTests {
    let picture = ReferenceImage.pattern(width: 48, height: 32)

    @Test func sharpenOnlyIsCASOnTheFiveSampleCross() throws {
        for sharpness: Float in [0, 0.5, 1] {
            let gpu = try UpscalerGPU.run(
                "casFragment", source: picture, width: picture.width, height: picture.height,
                uniforms: CASUniforms(sampled: (48, 32), strength: sharpness))
            #expect(UpscalerGPU.difference(gpu, UpscalerReference.sharpenOnly(picture, sharpness: sharpness)) < 2e-3)
        }
    }

    @Test func sharpenOnlyLeavesFlatAreasAlone() throws {
        let flat = ReferenceImage.uniform(SIMD4(0.4, 0.5, 0.6, 1), width: 16, height: 16)
        let gpu = try UpscalerGPU.run(
            "casFragment", source: flat, width: 16, height: 16, uniforms: CASUniforms(sampled: (16, 16), strength: 1))
        #expect(UpscalerGPU.difference(gpu, flat) < 1e-3)
    }

    @Test func thePresentationWithoutSharpnessIsThePlainPicture() throws {
        // Twice the size: CAS at 0 is a bilinear sample of the scaler's output
        let gpu = try UpscalerGPU.run(
            "casFragment", source: picture, width: 96, height: 64, uniforms: CASUniforms(sampled: (48, 32), strength: 0))
        let bilinear = ReferenceImage(width: 96, height: 64) { x, y in picture.sample((Float(x) + 0.5) / 96, (Float(y) + 0.5) / 64) }
        #expect(UpscalerGPU.difference(gpu, bilinear) < 3e-3)
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

    @Test func topAlignmentPutsFitAtTheTopAndCutsFillAtTheBottom() {
        let fit = PictureGeometry.make(video: (1920, 1080), target: (2000, 1500), mode: .fit, topAligned: true)
        #expect(fit.viewport.originY == 0 && fit.viewport.height == 1125)
        // A picture taller than the target: Fill shows its top
        let fill = PictureGeometry.make(video: (1080, 1920), target: (2000, 1500), mode: .fill, topAligned: true)
        #expect(fill.crop.y == 0 && fill.crop.w < 1)
        #expect(PictureGeometry.make(video: (1080, 1920), target: (2000, 1500), mode: .fill).crop.y > 0)
        let stretch = PictureGeometry.make(video: (1920, 1080), target: (2000, 1500), mode: .stretch, topAligned: true)
        #expect(stretch.viewport.originY == 0 && stretch.viewport.height == 1500)
    }

    @Test func theScaleModesDrawTheFixtureWhereTheyShould() throws {
        // The 64 × 64 fixture into a 128 × 64 target: Fit leaves black bars left and right, Stretch and Fill cover it
        for (mode, barred) in [(VideoScaleMode.fit, true), (.stretch, false), (.fill, false)] {
            let clock = VirtualClock()
            let pipeline = try #require(MetalPipeline(pacing: .phaseLock, fps: 60, options: VideoRenderOptions(scaleMode: mode), clock: clock.reading))
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

    @Test(.enabled(if: MetalFXSupport.system.spatial)) func theUpscalerStartsRunsAndStops() throws {
        let clock = VirtualClock()
        let options = VideoRenderOptions(upscaler: UpscalerSettings(enabled: true, mode: .spatial))
        let pipeline = try #require(MetalPipeline(pacing: .phaseLock, fps: 60, options: options, clock: clock.reading))
        defer { pipeline.invalidate() }
        pipeline.useOffscreenSize(width: 128, height: 128)
        #expect(pipeline.upscalerStatus == .starting)
        var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
        clock.set(1)
        #expect(pipeline.enqueue(try stream.sample(0)))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 1.02, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.spatial))
        #expect(!pipeline.isSupersampling)
        var counters = pipeline.counters()
        #expect(counters.upscale == UpscalerSizes(mode: .spatial, internalWidth: 128, internalHeight: 128, presentationWidth: 128, presentationHeight: 128))
        #expect(counters.upscalingMilliseconds != nil)

        // Sharpen only keeps the stream's size; the picture is drawn again at the next refresh without a new frame
        pipeline.setUpscaler(UpscalerSettings(enabled: true, mode: .sharpen, sharpness: 80))
        clock.set(1.03)
        pipeline.tick(RefreshTick(presentation: 1.04, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.spatial))
        clock.set(1.05)
        #expect(pipeline.enqueue(try stream.sample(1)))
        pipeline.waitForDecodes()
        pipeline.tick(RefreshTick(presentation: 1.06, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .on(.sharpen))
        // The GPU times arrive in the command buffers' completion handlers
        Thread.sleep(forTimeInterval: 0.3)
        counters = pipeline.counters()
        #expect(counters.upscale == UpscalerSizes(mode: .sharpen, internalWidth: 64, internalHeight: 64, presentationWidth: 128, presentationHeight: 128))
        #expect(counters.sharpen?.prepareName == "conversion")
        #expect(counters.sharpen?.gpuTimed == true)

        pipeline.setUpscaler(UpscalerSettings(enabled: false, mode: .sharpen))
        #expect(pipeline.upscalerStatus == .stopping)
        // Switching off redraws the last picture plainly
        pipeline.tick(RefreshTick(presentation: 1.08, refresh: 1.0 / 60, drawable: nil))
        #expect(pipeline.upscalerStatus == .off)
        #expect(pipeline.counters().upscale == nil)
    }

    @Test(.enabled(if: MetalFXSupport.system.temporal)) func aStreamThatMatchesTheViewIsSupersampled() throws {
        let clock = VirtualClock()
        let options = VideoRenderOptions(upscaler: UpscalerSettings(enabled: true, mode: .temporal, supersamplingLevel: 2))
        let pipeline = try #require(MetalPipeline(pacing: .phaseLock, fps: 60, options: options, clock: clock.reading))
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
        #expect(pipeline.counters().upscale?.isSupersampling == true)
        #expect(pipeline.counters().upscale?.internalWidth == 128)
    }

    @Test func withoutMetalFXEveryModeRunsAsSharpenOnlyAndReportsUnavailable() throws {
        for mode in [UpscalerMode.spatial, .temporal] {
            let clock = VirtualClock()
            let options = VideoRenderOptions(upscaler: UpscalerSettings(enabled: true, mode: mode, supersamplingLevel: 2))
            let pipeline = try #require(MetalPipeline(pacing: .phaseLock, fps: 60, options: options, clock: clock.reading, metalFX: MetalFXSupport.none))
            defer { pipeline.invalidate() }
            pipeline.useOffscreenSize(width: 128, height: 128)
            var stream = try ReplayStream(fixture: "frames.h264", codec: .h264)
            clock.set(1)
            #expect(pipeline.enqueue(try stream.sample(0)))
            pipeline.waitForDecodes()
            pipeline.tick(RefreshTick(presentation: 1.02, refresh: 1.0 / 60, drawable: nil))
            #expect(pipeline.upscalerStatus == .unavailable)
            #expect(!pipeline.isSupersampling)
            #expect(pipeline.counters().upscale == UpscalerSizes(mode: .sharpen, internalWidth: 64, internalHeight: 64, presentationWidth: 128, presentationHeight: 128))
            // Sharpen only itself is no fallback
            pipeline.setUpscaler(UpscalerSettings(enabled: true, mode: .sharpen))
            clock.set(1.05)
            #expect(pipeline.enqueue(try stream.sample(1)))
            pipeline.waitForDecodes()
            pipeline.tick(RefreshTick(presentation: 1.06, refresh: 1.0 / 60, drawable: nil))
            #expect(pipeline.upscalerStatus == .on(.sharpen))
        }
    }

    @Test func theDisplayLayerReportsARequestedUpscalerAsUnavailable() async {
        let layer = await DisplayLayerRenderer(pacing: .phaseLock, fps: 60)
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
