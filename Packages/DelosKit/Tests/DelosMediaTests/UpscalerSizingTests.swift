@testable import DelosMedia
import Testing

/// The sizes the upscaler plans for a stream on a display (``UpscalerSizes/plan``): upscaling when the stream is smaller
/// than the picture, supersampling only for a stream at the picture's size whose 4/3 or 2× size fits the limits, MetalFX's
/// output in the stream's aspect ratio up to the temporal scaler's largest factor.
@Suite struct UpscalerSizingTests {
    private let both = MetalFXSupport.scalers(spatial: true, temporal: true, temporalScale: 1...3)

    private func plan(
        _ stream: (Int, Int), on view: (Int, Int), _ mode: UpscalerMode = .spatial, level: Int = 1,
        scaleMode: VideoScaleMode = .fit, support: MetalFXSupport? = nil
    ) -> UpscalerSizes {
        UpscalerSizes.plan(
            stream: stream, view: view, scaleMode: scaleMode, mode: mode, supersamplingLevel: level, support: support ?? both)
    }

    @Test func aFourByThreeStreamFillsThe13InchIPad() {
        // The 13" iPad Pro (2752 × 2064): the automatic 1440 × 1080 is enlarged to the whole panel
        let s = plan((1440, 1080), on: (2752, 2064), .temporal)
        #expect(s == UpscalerSizes(mode: .temporal, internalWidth: 2752, internalHeight: 2064, presentationWidth: 2752, presentationHeight: 2064))
        #expect(!s.isSupersampling && s.enlarges(width: 1440, height: 1080))
    }

    @Test func the13InchIPadsOwnResolutionIsTooLargeToSupersample() {
        // 4/3 of 2752 × 2064 is 3668 × 2752, over 3840 × 2160 pixels; 2× is larger still: drawn at its own size
        let wanted = UpscalerSizes.supersampledSize(presentation: (2752, 2064), level: 1)
        #expect(wanted.width == 3668 && wanted.height == 2752)
        for level in 1...2 {
            let s = plan((2752, 2064), on: (2752, 2064), level: level)
            #expect(!s.isSupersampling && !s.enlarges(width: 2752, height: 2064))
            #expect(s.internalWidth == 2752 && s.internalHeight == 2064)
        }
        #expect(UpscalerSizes.isNativeInput(stream: (2752, 2064), view: (2752, 2064), scaleMode: .fit))
    }

    @Test func the11InchIPadSupersamplesAt133Only() {
        let one = plan((2420, 1668), on: (2420, 1668), level: 1)
        #expect(one.isSupersampling && one.internalWidth == 3226 && one.internalHeight == 2224)
        // 4840 × 3336 does not fit
        #expect(!plan((2420, 1668), on: (2420, 1668), level: 2).isSupersampling)
    }

    @Test func aTVsOwnResolutionSupersamplesAtBothLevels() {
        #expect(plan((1920, 1080), on: (1920, 1080), level: 1).internalWidth == 2560)
        let two = plan((1920, 1080), on: (1920, 1080), .temporal, level: 2)
        #expect(two.isSupersampling && two.internalWidth == 3840 && two.internalHeight == 2160)
        // A 4K panel's own resolution is too large for either level
        #expect(!plan((3840, 2160), on: (3840, 2160), level: 1).isSupersampling)
    }

    @Test func aWideStreamOnAFourByThreePanel() {
        // Fit: the picture is 16:9 inside the panel; Stretch: MetalFX keeps the stream's shape, the presentation stretches it
        let fit = plan((1920, 1080), on: (2752, 2064))
        #expect(fit.internalWidth == 2752 && fit.internalHeight == 1548 && fit.presentationHeight == 1548)
        let stretch = plan((1920, 1080), on: (2752, 2064), scaleMode: .stretch)
        #expect(stretch.internalWidth == 2752 && stretch.internalHeight == 1548)
        #expect(stretch.presentationWidth == 2752 && stretch.presentationHeight == 2064)
        // A stream larger than the picture is not enlarged
        let large = plan((3840, 2160), on: (2752, 2064))
        #expect(!large.enlarges(width: 3840, height: 2160) && large.presentationWidth == 2752)
    }

    @Test func theTemporalScalerStopsAtItsLargestFactor() {
        let capped = MetalFXSupport.scalers(spatial: true, temporal: true, temporalScale: 1...2)
        let s = plan((1280, 720), on: (3840, 2160), .temporal, support: capped)
        #expect(s.internalWidth == 2560 && s.internalHeight == 1440 && s.presentationWidth == 3840)
        // The spatial scaler has no such limit
        #expect(plan((1280, 720), on: (3840, 2160), support: capped).internalWidth == 3840)
    }

    @Test func withoutMetalFXSharpenOnlyKeepsTheStreamsSize() {
        let s = plan((1440, 1080), on: (2752, 2064), .temporal, support: MetalFXSupport.none)
        #expect(s == UpscalerSizes(mode: .sharpen, internalWidth: 1440, internalHeight: 1080, presentationWidth: 2752, presentationHeight: 2064))
        #expect(!s.enlarges(width: 1440, height: 1080))
    }
}
