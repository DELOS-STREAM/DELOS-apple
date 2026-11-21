import CoreVideo
import Foundation
import Metal
import Testing
@testable import DelosMedia

/// Neural (VideoToolbox's low-latency super resolution): the factor a stream gets, the pictures it does not take, the sizes
/// it plans, the fallback to MetalFX Spatial, and a real enlargement on this Mac where the system has the scaler.
@Suite struct NeuralScalerTests {
    @Test func theFactorIsTheLargestOfferedUpToTheEnlargement() {
        // 720p on a 2752-wide iPad picture: 1.5 is all 1280 × 720 is offered, MetalFX Spatial does the rest
        #expect(NeuralUpscaling.factor(needed: 2.15, offered: [1.5]) == 1.5)
        #expect(NeuralUpscaling.factor(needed: 2, offered: [1.5, 2]) == 2)
        #expect(NeuralUpscaling.factor(needed: 3, offered: [1.5, 2, 4]) == 2)
        // A smaller enlargement than every factor: the smallest, the presentation reduces the rest
        #expect(NeuralUpscaling.factor(needed: 1.2, offered: [1.5, 2]) == 1.5)
        // No enlargement, or a stream outside the limits
        #expect(NeuralUpscaling.factor(needed: 1, offered: [1.5, 2]) == nil)
        #expect(NeuralUpscaling.factor(needed: 2, offered: []) == nil)
    }

    @Test func tenBitFullRangeAndOversizedPicturesGoThroughMetalFXSpatial() {
        let offered: (Int, Int) -> [Float] = { width, _ in width <= 1280 ? [1.5] : [] }
        let hdr = NeuralUpscaling.plan(
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 1280, height: 720, target: (1920, 1080),
            factors: offered)
        #expect(hdr == .failure(.format))
        let fullRange = NeuralUpscaling.plan(
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, width: 1280, height: 720, target: (1920, 1080),
            factors: offered)
        #expect(fullRange == .failure(.format))
        let large = NeuralUpscaling.plan(
            pixelFormat: NeuralUpscaling.pixelFormat, width: 1920, height: 1080, target: (2752, 1548), factors: offered)
        #expect(large == .failure(.size))
        let taken = NeuralUpscaling.plan(
            pixelFormat: NeuralUpscaling.pixelFormat, width: 1280, height: 720, target: (1920, 1080), factors: offered)
        #expect(taken == .success(1.5))
    }

    @Test func neuralIsStoredAndStandsInAsSpatialWithoutTheScaler() {
        #expect(UpscalerMode(value: "neural") == .neural)
        #expect(UpscalerMode.allCases.last == .neural)
        let metalFXOnly = MetalFXSupport(spatial: true, temporal: true, temporalScale: 1...2)
        #expect(metalFXOnly.effectiveMode(.neural) == .spatial)
        #expect(MetalFXSupport.none.effectiveMode(.neural) == .sharpen)
        let all = MetalFXSupport(spatial: true, temporal: true, temporalScale: 1...2, neural: true)
        #expect(all.effectiveMode(.neural) == .neural)
    }

    @Test func theSizesAreTheNeuralPictureThenMetalFXSpatialToThePicture() {
        let support = MetalFXSupport(spatial: true, temporal: true, temporalScale: 1...2, neural: true)
        // 720p on an iPad Pro 13 panel (2752 × 2064, Fit): 1.5× to 1080p, then Spatial to the picture's 2752 × 1548
        let ipad = UpscalerSizes.plan(
            stream: (1280, 720), view: (2752, 2064), scaleMode: .fit, mode: .neural, supersamplingLevel: 1,
            support: support, neuralFactors: { _, _ in [1.5] })
        #expect(ipad == UpscalerSizes(
            mode: .neural, internalWidth: 2752, internalHeight: 1548, presentationWidth: 2752, presentationHeight: 1548))
        // Without MetalFX Spatial the neural picture is the internal size; the presentation enlarges it
        var noSpatial = support
        noSpatial.spatial = false
        let alone = UpscalerSizes.plan(
            stream: (1280, 720), view: (2752, 2064), scaleMode: .fit, mode: .neural, supersamplingLevel: 1,
            support: noSpatial, neuralFactors: { _, _ in [1.5] })
        #expect(alone.mode == .neural && alone.internalWidth == 1920 && alone.internalHeight == 1080)
        // A stream it does not take plans as MetalFX Spatial
        let large = UpscalerSizes.plan(
            stream: (1920, 1080), view: (2752, 2064), scaleMode: .fit, mode: .neural, supersamplingLevel: 1,
            support: support, neuralFactors: { _, _ in [] })
        #expect(large.mode == .spatial && large.internalWidth == 2752)
    }

    /// Draws `buffer` through the upscaler in Neural until its session is ready (or `seconds` pass) and returns the last
    /// drawing's report and the target.
    private func drawNeural(
        _ buffer: CVPixelBuffer, drawer: MetalFrameDrawer, target: any MTLTexture, seconds: Double
    ) throws -> UpscaleReport? {
        let conversion = try #require(ColorConversion(pixelBuffer: buffer))
        let settings = UpscalerSettings(enabled: true, mode: .neural, sharpness: 0)
        let end = Date().addingTimeInterval(seconds)
        var sequence = 0
        repeat {
            let command = try #require(drawer.queue.makeCommandBuffer())
            let drawn = drawer.draw(
                buffer, conversion: conversion, into: target, commandBuffer: command,
                upscale: UpscaleRequest(settings: settings, sequence: sequence, frameTime: Double(sequence) / 60))
            #expect(drawn)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            if drawer.lastReport?.mode == .neural { return drawer.lastReport }
            sequence += 1
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < end
        return drawer.lastReport
    }

    @Test(.enabled(if: NeuralUpscaling.isSupported))
    func anSDRPictureIsEnlargedByTheNeuralScalerOnceItsSessionIsReady() throws {
        let drawer = try UpscalerGPU.drawer()
        // 16-pixel stripes in two greys: a picture the scaler must keep, not a flat one it could return black for
        let buffer = try PixelBuffers.make(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            luma: { x, _ in x % 32 < 16 ? 80 : 180 }, chroma: { _, _ in (128, 128) })
        let target = try UpscalerGPU.target(drawer.device, width: 1280, height: 720)
        let report = try #require(try drawNeural(buffer, drawer: drawer, target: target, seconds: 10))
        #expect(report.mode == .neural)
        #expect(!report.fellBack)
        #expect(report.dimensions.internalWidth == 1280 && report.dimensions.internalHeight == 720)
        let picture = UpscalerGPU.read(target)
        // Both stripe levels survive (limited range: 80 is 0.29, 180 is 0.75): dark and bright pixels across the middle row
        let row = (0..<picture.width).map { picture.texel($0, picture.height / 2).x }
        let low = row.min() ?? 1, high = row.max() ?? 0
        #expect(low < 0.35 && high > 0.6, "middle row from \(low) to \(high)")
    }

    @Test(.enabled(if: NeuralUpscaling.isSupported))
    func aTenBitPictureStaysOnMetalFXSpatialWithoutReportingTheUpscalerUnavailable() throws {
        let drawer = try UpscalerGPU.drawer()
        let buffer = try PixelBuffers.make(
            width: 640, height: 360, format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            luma: { x, _ in x % 4 < 2 ? 200 : 700 }, chroma: { _, _ in (512, 512) })
        let target = try UpscalerGPU.target(drawer.device, width: 1280, height: 720)
        let report = try #require(try drawNeural(buffer, drawer: drawer, target: target, seconds: 0.2))
        #expect(report.mode == .spatial)
        #expect(!report.fellBack)
    }
}
