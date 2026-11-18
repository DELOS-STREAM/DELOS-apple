import DelosCore
import DelosMedia
import Testing
@testable import DelosData

/// The Display tab's rows reach the renderer: scale mode, upscaler, VRR, reduce refresh rate, enforce display mode.
@Suite struct StreamSettingsVideoTests {
    @Test func theDefaultsAreAndroids() {
        let options = StreamSettings().videoRenderOptions(
            displayWidth: 2796, displayHeight: 1290, decodable: [.h264, .hevc], displaySupportsHDR: false)
        #expect(options.scaleMode == .fit)
        #expect(options.upscaler == UpscalerSettings(enabled: false, mode: .standard, sharpness: 50, supersamplingLevel: 1))
        #expect(options.vrr == .auto && !options.reduceRefreshRate && !options.enforceDisplayMode && !options.hdr)
        #expect(options.frameRate == 60)
    }

    @Test func theStoredValuesAreRead() {
        var settings = StreamSettings(resolution: StreamResolution(width: 1920, height: 1080), fps: 120)
        settings.set(.videoScaleMode, .text("fill"))
        settings.set(.upscaler, .bool(true))
        settings.set(.upscalerMode, .text("temporal-quality"))
        settings.set(.upscalerSharpness, .int(80))
        settings.set(.upscalerSupersampling, .text("2"))
        settings.set(.vrr, .text("on"))
        settings.set(.reduceRefreshRate, .bool(true))
        settings.set(.enforceDisplayMode, .bool(true))
        let options = settings.videoRenderOptions(displayWidth: 2796, displayHeight: 1290, decodable: [.h264], displaySupportsHDR: true)
        #expect(options.scaleMode == .fill)
        #expect(options.upscaler == UpscalerSettings(enabled: true, mode: .temporalQuality, sharpness: 80, supersamplingLevel: 2))
        #expect(options.vrr == .on && options.reduceRefreshRate && options.enforceDisplayMode)
        #expect(options.streamWidth == 1920 && options.streamHeight == 1080 && options.frameRate == 120)
    }

    @Test func hdrNeedsAnHDRDisplayAndA10BitFormat() {
        var settings = StreamSettings()
        settings.hdr = true
        let main10: VideoFormats = [.h264, .hevc, .hevcMain10]
        #expect(settings.videoRenderOptions(displayWidth: 1920, displayHeight: 1080, decodable: main10, displaySupportsHDR: true).hdr)
        #expect(!settings.videoRenderOptions(displayWidth: 1920, displayHeight: 1080, decodable: main10, displaySupportsHDR: false).hdr)
        #expect(!settings.videoRenderOptions(displayWidth: 1920, displayHeight: 1080, decodable: [.h264], displaySupportsHDR: true).hdr)
    }
}
