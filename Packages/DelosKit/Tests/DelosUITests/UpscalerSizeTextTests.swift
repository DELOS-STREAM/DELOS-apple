import DelosData
import DelosMedia
import Foundation
import Testing
@testable import DelosUI

/// The resolution list and the upscaler's sizes as Settings, the stream menu and the statistics panel show them on the
/// 13" iPad Pro (2752 × 2064, 4:3), the 11" iPad Pro (2420 × 1668) and a 16:9 1080p TV (the iPhone's list:
/// `StreamSettingsTests`).
@MainActor
@Suite struct UpscalerSizeTextTests {
    private let iPad13 = StreamDevice(pixelWidth: 2064, pixelHeight: 2752, maxFramesPerSecond: 120, decodable: [.h264, .hevc])
    private let iPad11 = StreamDevice(pixelWidth: 1668, pixelHeight: 2420, maxFramesPerSecond: 120, decodable: [.h264, .hevc])
    private let tv = StreamDevice(pixelWidth: 1920, pixelHeight: 1080, maxFramesPerSecond: 60, decodable: [.h264, .hevc])

    private func upscaled(_ resolution: StreamResolution? = nil, mode: String = "standard", level: String = "1") -> StreamSettings {
        var settings = StreamSettings(resolution: resolution)
        settings.set(.upscaler, .bool(true))
        settings.set(.upscalerMode, .text(mode))
        settings.set(.upscalerSupersampling, .text(level))
        return settings
    }

    private func help(_ id: String, _ settings: StreamSettings, on device: StreamDevice) -> String {
        StreamSettingsForm(settings: settings, device: device).catalogRow(id)?.help ?? ""
    }

    // MARK: The resolution list

    @Test func theIPadOffersFourByThreeStreams() {
        let labels = StreamSettingsForm(settings: StreamSettings(), device: iPad13).resolutionOptions.map(\.label)
        // Automatic is the display scaled into 1920 × 1080: a 1080-line 4:3 stream
        #expect(labels.first == L("settings_screen_dot_join", L("videoformat_auto"), "1440x1080"))
        for (preset, size) in [("resolution_720p", "960x720"), ("resolution_1080p", "1440x1080"),
                               ("resolution_1440p", "1920x1440"), ("resolution_4k", "2880x2160")] {
            #expect(labels.contains(L("settings_screen_dot_join", L(preset), size)))
        }
        // The 16:9 presets and the display's own resolution stay
        #expect(labels.contains(L("resolution_1080p")) && labels.contains(L("settings_resolution_native", "2752x2064")))
        #expect(labels.count == 1 + 6 + 4 + 1)
        // A 16:9 display has no presets of its own
        #expect(StreamSettingsForm(settings: StreamSettings(), device: tv).resolutionOptions.count == 1 + 6)
    }

    @Test func aDisplayAspectPresetCanBeChosen() throws {
        var form = StreamSettingsForm(settings: StreamSettings(), device: iPad11)
        let index = try #require(form.resolutionOptions.firstIndex { $0.value == StreamResolution(width: 1566, height: 1080) })
        form.pick("list_resolution", option: index)
        #expect(form.settings.resolution == StreamResolution(width: 1566, height: 1080))
        #expect(form.catalogRow("list_resolution")?.value
            == .choice(label: L("settings_screen_dot_join", L("resolution_1080p"), "1566x1080"),
                       options: form.resolutionOptions.map(\.label), selected: index))
    }

    // MARK: Settings

    @Test func theResolutionHelpSaysWhatTheUpscalerMakesOfTheStream() {
        let note = L("help_note_upscaler_upscales", "1440 × 1080", "2752 × 2064")
        #expect(help("list_resolution", upscaled(), on: iPad13).contains(note))
        #expect(help("checkbox_sgsr", upscaled(), on: iPad13).contains(note))
        #expect(help("list_sgsr_quality", upscaled(mode: "temporal"), on: iPad13).contains(note))
        // Without the upscaler the resolution help has no note
        #expect(!help("list_resolution", StreamSettings(), on: iPad13).contains(note))
        // A 16:9 stream on the 4:3 panel fills its width
        let wide = upscaled(StreamResolution(width: 1920, height: 1080))
        #expect(help("list_resolution", wide, on: iPad13).contains(L("help_note_upscaler_upscales", "1920 × 1080", "2752 × 1548")))
        // The display's own resolution is not enlarged; supersampling it at 4/3 is over the limit
        let native = upscaled(StreamResolution(width: 2752, height: 2064))
        #expect(help("list_resolution", native, on: iPad13).contains(L("help_note_upscaler_unscaled", "2752 × 2064", "2752 × 2064")))
        // A TV's own 1080p is supersampled
        #expect(help("list_resolution", upscaled(StreamResolution(width: 1920, height: 1080)), on: tv)
            .contains(L("help_note_upscaler_supersamples", "1920 × 1080", "2560 × 1440", "1920 × 1080")))
        // Without MetalFX Sharpen only runs and says so instead
        var noMetalFX = iPad13
        noMetalFX.metalFX = MetalFXSupport.none
        #expect(!help("list_resolution", upscaled(), on: noMetalFX).contains(note))
    }

    @Test func theSupersamplingLevelsNameThisDisplaysSizes() {
        let short1 = L("sgsr_supersampling_level_1_short"), short2 = L("sgsr_supersampling_level_2_short")
        // 11" iPad Pro: 1.33× of its own 2420 × 1668 fits, 2× does not
        let native11 = upscaled(StreamResolution(width: 2420, height: 1668))
        let row = StreamSettingsForm(settings: native11, device: iPad11).catalogRow("list_sgsr_supersampling_level")
        let first = L("settings_screen_dot_join", short1, "3226 × 2224")
        #expect(row?.value == .choice(label: first, options: [first, short2], selected: 0))
        #expect(row?.help.contains(L("help_supersampling_renders", "2420 × 1668", "3226 × 2224")) == true)
        #expect(help("list_sgsr_supersampling_level", upscaled(StreamResolution(width: 2420, height: 1668), level: "2"), on: iPad11)
            .contains(L("help_supersampling_too_large", "4840 × 3336", "3840 × 2160")))
        // 13" iPad Pro: neither level fits; a stream below the display's size is not supersampled at all
        let row13 = StreamSettingsForm(settings: upscaled(), device: iPad13).catalogRow("list_sgsr_supersampling_level")
        #expect(row13?.value == .choice(label: short1, options: [short1, short2], selected: 0))
        #expect(row13?.help.contains(L("help_supersampling_too_large", "3668 × 2752", "3840 × 2160")) == true)
        #expect(row13?.help.contains(L("help_note_supersampling_needs_native", "2752 × 2064")) == true)
        // A 1080p TV: both levels, the sizes of the old fixed labels
        let tvRow = StreamSettingsForm(settings: upscaled(), device: tv).catalogRow("list_sgsr_supersampling_level")
        #expect(tvRow?.value == .choice(
            label: L("settings_screen_dot_join", short1, "2560 × 1440"),
            options: [L("settings_screen_dot_join", short1, "2560 × 1440"), L("settings_screen_dot_join", short2, "3840 × 2160")],
            selected: 0))
    }

    @Test func theSupersamplingImpactFollowsWhetherItHappens() {
        // Not at the display's size, or over the limit: the level does nothing, its chips dim
        let form13 = StreamSettingsForm(settings: upscaled(StreamResolution(width: 2752, height: 2064)), device: iPad13)
        #expect(form13.catalogRow("list_sgsr_supersampling_level")?.impact == .quiet)
        let form11 = StreamSettingsForm(settings: upscaled(StreamResolution(width: 2420, height: 1668)), device: iPad11)
        #expect(form11.catalogRow("list_sgsr_supersampling_level")?.impact == SettingImpact(gpu: .low, latency: .low, network: .none))
        // MetalFX Temporal filling the 13" panel reconstructs more than 2560 × 1440 pixels
        let temporal = StreamSettingsForm(settings: upscaled(mode: "temporal"), device: iPad13)
        #expect(temporal.catalogRow("list_sgsr_quality")?.impact == SettingImpact(gpu: .high, latency: .medium, network: .none))
    }

    // MARK: The stream menu and the statistics

    @Test func theMenuKeepsSupersamplingWhereALevelFits() {
        func upscaler(_ stream: StreamResolution, on device: StreamDevice, level: Int) -> RendererUpscaler {
            var options = VideoRenderOptions()
            options.upscaler = UpscalerSettings(enabled: true, mode: .spatial, supersamplingLevel: level)
            let plan = UpscalerSizePlan(
                stream: stream, displayWidth: device.pixelWidth, displayHeight: device.pixelHeight, scaleMode: .fit,
                support: device.metalFX)
            return RendererUpscaler(renderer: RendererChoice.layer.makeRenderer(pacing: .latency, fps: 60, options: options), sizePlan: plan)
        }
        // A 2× that does not fit on the 11" iPad still offers the 1.33× that does
        #expect(upscaler(StreamResolution(width: 2420, height: 1668), on: iPad11, level: 2).supersamplingMode)
        // The 13" iPad's own resolution fits neither level, a smaller stream is upscaled
        #expect(!upscaler(StreamResolution(width: 2752, height: 2064), on: iPad13, level: 1).supersamplingMode)
        #expect(!upscaler(StreamResolution(width: 1440, height: 1080), on: iPad13, level: 1).supersamplingMode)
        #expect(NoUpscaler().sizePlan == nil)
    }

    @Test func theStatisticsLineShowsTheStreamAndTheUpscalersSizes() {
        func line(_ w: Int, _ h: Int, _ s: UpscalerSizes) -> String { UpscalerSizeText.statistics(streamWidth: w, streamHeight: h, sizes: s) }
        let up = UpscalerSizes(mode: .spatial, internalWidth: 2752, internalHeight: 2064, presentationWidth: 2752, presentationHeight: 2064)
        #expect(line(1440, 1080, up) == "Upscaled: 1440 × 1080 → 2752 × 2064")
        let stretched = UpscalerSizes(mode: .temporal, internalWidth: 2752, internalHeight: 1548, presentationWidth: 2752, presentationHeight: 2064)
        #expect(line(1920, 1080, stretched) == "Upscaled: 1920 × 1080 → 2752 × 1548 → 2752 × 2064")
        let ss = UpscalerSizes(mode: .spatial, internalWidth: 2560, internalHeight: 1440, presentationWidth: 1920, presentationHeight: 1080)
        #expect(line(1920, 1080, ss) == "Supersampled: 1920 × 1080 → 2560 × 1440 → 1920 × 1080")
        let sharpen = UpscalerSizes(mode: .sharpen, internalWidth: 1920, internalHeight: 1080, presentationWidth: 2752, presentationHeight: 1548)
        #expect(line(1920, 1080, sharpen) == "Sharpen only: 1920 × 1080")
        let direct = UpscalerSizes(mode: .spatial, internalWidth: 2752, internalHeight: 1548, presentationWidth: 2752, presentationHeight: 1548)
        #expect(line(3840, 2160, direct) == "Not upscaled: 3840 × 2160 → 2752 × 1548")
    }
}
