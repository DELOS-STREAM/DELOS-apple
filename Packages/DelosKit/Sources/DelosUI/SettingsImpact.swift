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
    /// The stored value of the codec (`auto`, `forceav1`, `forceh265`, `neverh265`).
    var codec: String
    var hdr: Bool
    /// The stored value of the frame pacing (`latency`, `balanced`, `cap-fps`, `smoothness`, `warp`, `warp2`).
    var pacing: String

    init(height: Int, fps: Double, bitrateMbps: Int, codec: String, hdr: Bool, pacing: String) {
        self.height = max(height, 1)
        self.fps = max(fps, 1)
        self.bitrateMbps = bitrateMbps
        self.codec = codec
        self.hdr = hdr
        self.pacing = pacing
    }

    /// The Mbps the host would be asked for with this codec, resolution and frame rate, if the table knows it: Moonlight's 60 FPS
    /// table (20 / 40 / 80 Mbps at 1080p / 1440p / 4K, doubled for HEVC and AV1, tripled for H.264, capped at 150), a judgment
    /// constant. Nil off 60 FPS and for a resolution the table lacks.
    var recommendedMbps: Int? {
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

/// The impact of the stream setting [id] for the settings in effect, or nil for a setting without chips (`impact` of DELOS for
/// Android; the upscaler and PyroWave rows have no counterpart here). Levels are qualitative estimates that follow the help texts
/// and docs/STREAM_QUALITY.md of DELOS for Android.
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
        return SettingImpact(gpu: .low, latency: low ? .medium : .low, network: low ? .low : .medium)
    case StreamSettingsForm.bitrate:
        return SettingImpact(gpu: .none, latency: c.bitrateMbps >= 150 ? .medium : .low, network: networkLevel(c.bitrateMbps))
    case StreamSettingsForm.codec:
        switch c.codec {
        case "neverh265": return SettingImpact(gpu: .low, latency: .low, network: .medium)
        default: return SettingImpact(gpu: .low, latency: .low, network: .low)
        }
    case StreamSettingsForm.hdr:
        return c.hdr ? SettingImpact(gpu: .low, latency: .none, network: .low) : .quiet
    case StreamSettingsForm.framePacing:
        switch c.pacing {
        case "balanced", "cap-fps": return SettingImpact(gpu: .low, latency: .medium, network: .none)
        case "smoothness": return SettingImpact(gpu: .low, latency: .high, network: .none)
        case "warp": return SettingImpact(gpu: .medium, latency: .low, network: .medium)
        case "warp2": return SettingImpact(gpu: .high, latency: .low, network: .high)
        default: return SettingImpact(gpu: .low, latency: .low, network: .none)
        }
    default:
        return nil
    }
}

/// Low below 50 Mbps, Medium below 150, else High (the 4K60 knee of the link sits at 100 to 160).
private func networkLevel(_ mbps: Int) -> ImpactLevel { mbps < 50 ? .low : mbps < 150 ? .medium : .high }

extension StreamSettingsForm {
    /// What the stream settings in effect cost, for the impact chips.
    var impactContext: ImpactContext {
        ImpactContext(
            height: effectiveResolution.height, fps: Double(settings.fps), bitrateMbps: effectiveBitrate / 1000,
            codec: settings.codec.rawValue, hdr: settings.hdr, pacing: settings.framePacing.rawValue)
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
