import DelosData
import DelosMedia
import SwiftUI

/// A cost bucket, never a measurement (`ImpactLevel` of DELOS for Android). `none` is dimmed in the UI; the other three fill
/// one, two or three bars.
enum ImpactLevel: Int, Sendable {
    case none, low, medium, high
}

/// What a setting's current value costs, on three axes: the GPU time, the end-to-end latency and the network bandwidth
/// (`SettingImpact`, issue #40 of DELOS for Android).
struct SettingImpact: Equatable, Sendable {
    var gpu: ImpactLevel
    var latency: ImpactLevel
    var network: ImpactLevel

    var levels: [ImpactLevel] { [gpu, latency, network] }

    static let quiet = SettingImpact(gpu: .none, latency: .none, network: .none)
}

/// The values the impact depends on (`ImpactContext`): the stream settings in effect.
struct ImpactContext: Equatable {
    var height: Int
    var fps: Double
    var bitrateMbps: Int
    /// The stored value of the codec (`auto`, `forceav1`, `forceh265`, `neverh265`, `pyrowave`).
    var codec: String
    var hdr: Bool
    /// The stored value of the frame pacing (`latency`, `balanced`, `cap-fps`, `smoothness`, `warp`, `warp2`).
    var pacing: String
    /// The upscaler (`checkbox_sgsr`), its mode (`list_sgsr_quality`) and sharpness.
    var upscaler = false
    var mode = "standard"
    var sharpness = 50
    /// The next stream is supersampled on this display, and at 2× (the planned sizes, ``UpscalerSizePlan``): the level
    /// row does nothing otherwise.
    var supersampling = false
    var twoTimes = false
    /// The upscaler reconstructs more pixels than 2560 × 1440, the output of the 1.33× level from 1080p.
    var largeOutput = false
    /// PyroWave's recommended bitrate in kbps for these settings, nil without PyroWave.
    var pyroKbps: Int?

    init(height: Int, fps: Double, bitrateMbps: Int, codec: String, hdr: Bool, pacing: String) {
        self.height = max(height, 1)
        self.fps = max(fps, 1)
        self.bitrateMbps = bitrateMbps
        self.codec = codec
        self.hdr = hdr
        self.pacing = pacing
    }

    var pyro: Bool { codec == VideoCodec.pyroWave.rawValue }
    var periodMs: Double { 1000 / fps }
    var temporal: Bool { mode == "temporal" }

    /// The upscaler pass in ms for the current mode, nil where there is no measurement (the MetalFX scalers).
    var upscalerMs: Double? {
        guard upscaler, mode == "sharpen" else { return nil }
        return ImpactTiming.sharpen
    }

    /// The Mbps the host would be asked for with this codec, resolution and frame rate, if the table knows it: PyroWave's
    /// recommendation, else Moonlight's 60 FPS table (20 / 40 / 80 Mbps at 1080p / 1440p / 4K, doubled for HEVC and AV1,
    /// tripled for H.264, capped at 150), a judgment constant. Nil off 60 FPS and for a resolution the table lacks.
    var recommendedMbps: Int? {
        if pyro { return pyroKbps.map { $0 / 1000 } }
        guard Int(fps) == 60 else { return nil }
        let base: Int
        switch height {
        case ...720: return nil
        case ...1080: base = 20
        case ...1440: base = 40
        default: base = 80
        }
        return min(150, base * (codec == "neverh265" ? 3 : 2))
    }
}

/// The measured cost of the sharpen (CAS) pass at 1080p on a phone GPU, used as a budget estimate. The MetalFX scalers have
/// no measurement yet: their chips are qualitative (``temporalImpact(_:)``).
enum ImpactTiming {
    static let sharpen = 0.31
}

/// The impact of the stream setting [id] for the settings in effect, or nil for a setting without chips (`impact` of DELOS for
/// Android), and nil while the row does not apply (PyroWave chroma without PyroWave, the supersampling with Sharpen only).
/// The upscaler rows are quiet while the upscaler is off. Levels are qualitative estimates that follow the help texts and
/// docs/STREAM_QUALITY.md of DELOS for Android.
func settingImpact(id: String, context c: ImpactContext) -> SettingImpact? {
    switch id {
    case StreamSettingsForm.resolution:
        let big = c.height >= 2160
        let network: ImpactLevel
        if let recommended = c.recommendedMbps {
            network = networkLevel(recommended)
        } else {
            network = c.height <= 720 ? .low : .medium
        }
        return SettingImpact(gpu: big ? .medium : .low, latency: big ? .medium : .low, network: network)
    case StreamSettingsForm.frameRate:
        let low = c.fps <= 60
        let gpu: ImpactLevel = if let ms = c.upscalerMs { gpuLevel(ms, c.periodMs) } else if c.pyro { low ? .medium : .high } else { .low }
        return SettingImpact(gpu: gpu, latency: low ? .medium : .low, network: c.pyro ? .high : low ? .low : .medium)
    case StreamSettingsForm.bitrate:
        return SettingImpact(gpu: .none, latency: c.bitrateMbps >= 150 ? .medium : .low, network: networkLevel(c.bitrateMbps))
    case StreamSettingsForm.codec:
        switch c.codec {
        case "neverh265": return SettingImpact(gpu: .low, latency: .low, network: .medium)
        case "pyrowave": return SettingImpact(gpu: .high, latency: .low, network: .high)
        default: return SettingImpact(gpu: .low, latency: .low, network: .low)
        }
    case StreamSettingsForm.hdr:
        return c.hdr ? SettingImpact(gpu: .low, latency: .none, network: c.pyro ? .high : .low) : .quiet
    case StreamSettingsForm.framePacing:
        switch c.pacing {
        case "balanced", "cap-fps": return SettingImpact(gpu: .low, latency: .medium, network: .none)
        case "smoothness": return SettingImpact(gpu: .low, latency: .high, network: .none)
        case "warp": return SettingImpact(gpu: .medium, latency: .low, network: .medium)
        case "warp2": return SettingImpact(gpu: .high, latency: .low, network: .high)
        default: return SettingImpact(gpu: .low, latency: .low, network: .none)
        }
    case SettingKey.upscaler.rawValue, SettingKey.upscalerMode.rawValue:
        return c.upscaler ? upscalerMode(c) : .quiet
    case SettingKey.upscalerSharpness.rawValue:
        return !c.upscaler || c.sharpness == 0 ? .quiet : SettingImpact(gpu: .low, latency: .low, network: .none)
    case SettingKey.upscalerSupersampling.rawValue:
        guard c.upscaler else { return .quiet }
        guard c.mode != "sharpen" else { return nil }
        // A stream that is not at the display's size, or a level over the upscaler's limit, is not supersampled
        guard c.supersampling else { return .quiet }
        return c.temporal ? temporalImpact(c) : SettingImpact(gpu: c.twoTimes ? .medium : .low, latency: .low, network: .none)
    default:
        return nil
    }
}

/// Low below 50 Mbps, Medium below 150, else High (the 4K60 knee of the link sits at 100 to 160).
private func networkLevel(_ mbps: Int) -> ImpactLevel { mbps < 50 ? .low : mbps < 150 ? .medium : .high }

/// A pass's share of the frame period: below 35 % Low, below 70 % Medium, else High.
private func gpuLevel(_ ms: Double, _ periodMs: Double) -> ImpactLevel {
    let share = ms / periodMs
    return share < 0.35 ? .low : share < 0.70 ? .medium : .high
}

/// The upscaler mode row, and the on/off row while the upscaler is on.
private func upscalerMode(_ c: ImpactContext) -> SettingImpact {
    switch c.mode {
    case "sharpen", "standard": SettingImpact(gpu: .low, latency: .low, network: .none)
    default: temporalImpact(c)
    }
}

/// MetalFX Temporal: the video's optical flow and the temporal scaler, unmeasured, so a qualitative Medium GPU cost, High
/// at 2× supersampling, for an output larger than 2560 × 1440 or above 60 FPS (more pixels, or a shorter frame period);
/// the GPU work sits in each frame's path (latency Medium).
private func temporalImpact(_ c: ImpactContext) -> SettingImpact {
    SettingImpact(gpu: c.twoTimes || c.largeOutput || c.fps > 60 ? .high : .medium, latency: .medium, network: .none)
}

extension StreamSettingsForm {
    /// What the stream settings in effect cost, for the impact chips.
    var impactContext: ImpactContext {
        var c = ImpactContext(
            height: effectiveResolution.height, fps: Double(settings.fps), bitrateMbps: effectiveBitrate / 1000,
            codec: settings.codec.rawValue, hdr: settings.hdr, pacing: settings.framePacing.rawValue)
        c.upscaler = settings.bool(.upscaler)
        c.mode = settings.text(.upscalerMode)
        c.sharpness = settings.int(.upscalerSharpness)
        let sizes = upscalerSizes
        c.supersampling = sizes.isSupersampling
        c.twoTimes = sizes.isSupersampling && settings.upscalerSettings.supersamplingLevel >= 2
        c.largeOutput = sizes.internalWidth * sizes.internalHeight > 2560 * 1440
        c.pyroKbps = settings.pyroWaveRecommendedKbps(displayResolution: device.defaultResolution)
        return c
    }
}

/// The three impact axes in the order the chips and the legend show them: name, glyph (`IMPACT_AXES`).
enum ImpactAxes {
    static var all: [(name: String, glyph: String)] {
        [(L("impact_axis_gpu"), Symbols.gpu), (L("impact_axis_latency"), Symbols.timer), (L("impact_axis_network"), Symbols.wifi)]
    }

    static func levelWord(_ level: ImpactLevel) -> String {
        switch level {
        case .none: L("impact_level_none")
        case .low: L("impact_level_low")
        case .medium: L("impact_level_medium")
        case .high: L("impact_level_high")
        }
    }

    /// The accessibility description of a row's chips: "GPU low, Latency low, Network medium".
    static func description(_ impact: SettingImpact) -> String {
        let axes = zip(all, impact.levels).map { L("impact_axis_level", $0.0.name, levelWord($0.1)) }
        return L("impact_axes_joined", axes[0], axes[1], axes[2])
    }
}

extension ImpactLevel {
    /// Low is the palette's secondary color, Medium its main color and High the app's warm red (the low-battery red).
    func color(_ colors: DelosColors) -> RGBA {
        switch self {
        case .none: colors.text3
        case .low: colors.accent2
        case .medium: colors.accent
        case .high: ImpactRed.value
        }
    }
}

enum ImpactRed {
    static let value = RGBA(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
}

/// Three tiny chips on their own line above a row's title (`ImpactChips`, issue #40): a glyph for GPU, latency and network, each
/// with a 3-step bar indicator filled to the level. A level of none dims its chip.
struct ImpactChips: View {
    let impact: SettingImpact
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(26)) {
            ForEach(Array(ImpactAxes.all.enumerated()), id: \.offset) { index, axis in
                ImpactChip(glyph: axis.glyph, level: impact.levels[index], glyphColor: focused ? colors.text2 : colors.text3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ImpactAxes.description(impact))
    }
}

/// One glyph with its bars: the level fills 1, 2 or 3 of them.
struct ImpactChip: View {
    let glyph: String
    let level: ImpactLevel
    let glyphColor: RGBA
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let fill = level.color(colors)
        HStack(spacing: stage.px(5)) {
            SymbolView(symbol: glyph, size: 25, color: glyphColor)
            HStack(alignment: .bottom, spacing: stage.px(3)) {
                ForEach(1...3, id: \.self) { step in
                    RoundedRectangle(cornerRadius: stage.px(2))
                        .fill(step <= level.rawValue ? fill.color : colors.text3.opacity(0.3).color)
                        .frame(width: stage.px(6), height: stage.px(Double(9 + (step - 1) * 6)))
                }
            }
            .frame(width: stage.px(24), height: stage.px(21), alignment: .bottomLeading)
        }
        .opacity(level == .none ? 0.4 : 1)
    }
}

/// The legend of the chips, shown under the help text while a row with chips is focused: the three glyphs and what the bars mean
/// (`ImpactLegend`). [sentence] false leaves out the explanation (the compact dock sets it apart, ``ImpactLegendSentence``).
struct ImpactLegend: View {
    var sentence = true
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(alignment: .leading, spacing: stage.px(6)) {
            HStack(spacing: stage.px(20)) {
                ForEach(Array(ImpactAxes.all.enumerated()), id: \.offset) { _, axis in
                    HStack(spacing: stage.px(6)) {
                        SymbolView(symbol: axis.glyph, size: 22, color: colors.text2)
                        Text(axis.name)
                            .font(DelosFonts.figtree(stage.tpx(18)))
                            .foregroundStyle(colors.text3.color)
                            .lineLimit(1)
                    }
                }
            }
            if sentence { ImpactLegendSentence() }
        }
    }
}

/// What the bars of the chips mean, in one sentence.
struct ImpactLegendSentence: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(L("impact_legend"))
            .font(DelosFonts.figtree(stage.tpx(18)))
            .foregroundStyle(colors.text3.color)
    }
}
