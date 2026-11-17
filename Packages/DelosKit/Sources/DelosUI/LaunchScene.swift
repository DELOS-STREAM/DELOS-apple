import CoreGraphics
import DelosData
import DelosMedia
import Foundation
import Observation
import SwiftUI

/// Runs the launch scene's ``LaunchTimeline`` on the system's clock while the loader is up: it ticks every 16 ms to move
/// the phases and the connection line, and says when the scene is over. What changes every frame (the ring, the
/// opening, the tunnel) is read by the drawing from ``timeline`` and is not observed.
@MainActor
@Observable
final class LaunchDirector {
    /// The scene is up (it ends when its exit is done, or the stream stops).
    private(set) var isActive = true
    /// The connection line told now.
    private(set) var line: String?
    @ObservationIgnored private(set) var timeline: LaunchTimeline
    @ObservationIgnored let run = LaunchTunnelRun()
    /// When the scene began on the scene's clock.
    @ObservationIgnored let start = LaunchDirector.now()
    @ObservationIgnored private var lastLine: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Draws the picture's arrival when the exit begins (``LaunchTimeline/arrivalSeconds(since:)``).
    @ObservationIgnored private let renderer: (any VideoRenderer)?

    /// Seconds on the clock the scene runs on.
    nonisolated static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    init(line: String?, reducedMotion: Bool, renderer: (any VideoRenderer)? = nil) {
        timeline = LaunchTimeline(now: Self.now(), line: line, reducedMotion: reducedMotion)
        self.line = line
        self.renderer = renderer
        lastLine = line
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    isolated deinit { ticker?.cancel() }

    private func tick() {
        let previous = timeline.phase
        timeline.update(at: Self.now())
        if let seconds = timeline.arrivalSeconds(since: previous) { renderer?.startArrival(duration: seconds) }
        if line != timeline.currentLine { line = timeline.currentLine }
        if !timeline.isActive { stop() }
    }

    /// A connection stage started with this line.
    func stage(_ line: String) {
        guard line != lastLine else { return }
        lastLine = line
        timeline.stage(line: line, at: Self.now())
    }

    /// The connection is up: the picture comes next.
    func gameRuns() {
        timeline.gameRuns(at: Self.now())
    }

    func framePresented() {
        timeline.framePresented()
    }

    /// The scene goes away at once (the stream failed, or is being left); an arrival still running ends with it.
    func stop() {
        ticker?.cancel()
        ticker = nil
        isActive = false
        if timeline.isActive { renderer?.cancelArrival() }
    }
}

/// What the launch scene says about the game and the stream.
struct LaunchCard {
    let title: String
    /// The game's SteamGridDB logo, which replaces the title when it exists.
    var logo: CGImage?
    /// "1920 × 1080 · Auto · 60 FPS": what the stream asks for.
    let parameters: String
    /// "Calling up <PC>", told before the first stage.
    let greeting: String
}

enum LaunchText {
    /// The stream's effective resolution, codec policy and frame rate (`formatLaunchStreamParameters`): read-only, from
    /// the profile's settings. The codec is the profile's choice (Auto until the PC picks one), not the negotiated one.
    static func parameters(settings: StreamSettings, display: DisplayInfo?) -> String {
        guard let display else { return "" }
        let size = settings.resolution(displayWidth: display.pixelWidth, displayHeight: display.pixelHeight)
        let codec = switch settings.codec {
        case .automatic: L("stream_loader_codec_auto")
        case .av1: "AV1"
        case .hevc: "HEVC"
        case .h264: "H.264"
        case .pyroWave: "PyroWave"
        }
        return "\(size.width) × \(size.height) · \(codec) · \(settings.fps) FPS"
    }

    /// The percentage under the bar.
    static func percent(_ progress: Double) -> String { "\(Int((LaunchLook.unit(progress) * 100).rounded()))%" }
}

/// The loader above the stream while it connects and opens (`LaunchOverlay` and `LoaderScene` of DELOS for Android): the
/// hyperspace tunnel (a still calm scene with reduced motion), the game's logo or title, the stream's parameters, the
/// connection line, the bar and its percentage. Once the game runs the information fades and the tunnel opens a soft
/// aperture over the picture below.
struct LaunchLoader: View {
    let director: LaunchDirector
    let card: LaunchCard
    /// Cancels the launch (the persistent pill; B and Escape do the same through the screen). Nil: no pill.
    var onCancel: (@MainActor () -> Void)?
    @Environment(\.stage) private var stage

    /// The pill's height: 64 stage pixels, at least 44 points for a finger.
    private var pillHeight: CGFloat { max(stage.px(LaunchLook.cancelHeight), 44) }

    /// How far the information moves up so that the pill under it does not touch it.
    private var lift: CGFloat {
        guard onCancel != nil else { return 0 }
        let pillTop = stage.px(LaunchLook.cancelBottom + stage.safe.bottom) + pillHeight + stage.px(LaunchLook.cancelGap)
        return max(0, pillTop - stage.px(LaunchLook.infoBottom + stage.safe.bottom))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TimelineView(.animation(paused: !director.isActive)) { _ in
                let now = LaunchDirector.now()
                LaunchScene(
                    card: card, line: director.line, progress: director.timeline.progress(at: now),
                    opening: director.timeline.opening(at: now), time: now - director.start, run: director.run,
                    reducedMotion: director.timeline.reducedMotion, lift: lift)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.greeting)
            .accessibilityValue(director.line ?? "")
            #if !os(tvOS)
            if let onCancel {
                // A persistent pill, not one that a first tap reveals: the loader lasts seconds on a LAN, so a tap to reveal Cancel
                // and another to press it would come too late. It fades with the information, as long as it can be pressed.
                TimelineView(.animation(paused: !director.isActive)) { _ in
                    let alpha = LaunchLook.infoAlpha(opening: director.timeline.opening(at: LaunchDirector.now()))
                    LaunchCancelPill(height: pillHeight, action: onCancel)
                        .opacity(alpha)
                        .allowsHitTesting(alpha > 0.5)
                }
                .padding(.bottom, stage.px(LaunchLook.cancelBottom + stage.safe.bottom))
            }
            #endif
        }
        .ignoresSafeArea()
    }
}

/// The Cancel pill of the launch scene (the look of ``PillButton``'s glass pill): a close icon and "Cancel".
struct LaunchCancelPill: View {
    let height: CGFloat
    let action: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Button(action: action) {
            HStack(spacing: stage.px(12)) {
                SymbolView(symbol: Symbols.close, size: 30, color: colors.text)
                Text(L("common_cancel"))
                    .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, stage.px(28))
            .frame(height: height)
            .background {
                GlassShape(Capsule(), tint: colors.surface)
                    .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("common_cancel"))
    }
}

/// One frame of the launch scene.
struct LaunchScene: View {
    let card: LaunchCard
    let line: String?
    let progress: Double
    let opening: Double
    /// Seconds since the scene began (the tunnel's clock).
    let time: Double
    let run: LaunchTunnelRun
    let reducedMotion: Bool
    /// How far the information is lifted (the Cancel pill is under it), points.
    var lift: CGFloat = 0
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack(alignment: .bottom) {
            if reducedMotion {
                calm
            } else {
                LaunchTunnel(run: run, time: time, progress: progress, opening: opening)
            }
            information
        }
    }

    /// The still scene of reduced motion: the background with the third accent glowing in it, fading out with the exit.
    private var calm: some View {
        GeometryReader { proxy in
            ZStack {
                colors.bg.color
                RadialGradient(
                    colors: [colors.accent3.opacity(LaunchLook.calmAlpha).color, colors.bg.color], center: .center, startRadius: 0,
                    endRadius: max(min(proxy.size.width, proxy.size.height) / 2, 1))
            }
        }
        .opacity(1 - LaunchLook.unit(opening))
    }

    private var information: some View {
        VStack(spacing: 0) {
            if let logo = card.logo {
                Image(decorative: logo, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: stage.px(LaunchLook.logoWidth), height: stage.px(LaunchLook.logoHeight))
            } else {
                Text(card.title)
                    .font(DelosFonts.unbounded(stage.tpx(LaunchLook.titleSize)))
                    .foregroundStyle(colors.text.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            Text(card.parameters)
                .font(DelosFonts.figtree(stage.tpx(LaunchLook.parametersSize)))
                .tracking(stage.tpx(LaunchLook.parametersTracking))
                .foregroundStyle(colors.text2.color)
                .padding(.top, stage.px(18))
            Text(line ?? card.greeting)
                .font(DelosFonts.figtree(stage.tpx(LaunchLook.stageSize)))
                .lineSpacing(stage.tpx(LaunchLook.stageSize * (LaunchLook.stageLineHeight - 1)))
                .foregroundStyle(colors.text.color)
                .multilineTextAlignment(.center)
                .padding(.top, stage.px(15))
            track
                .padding(.top, stage.px(15))
            Text(LaunchText.percent(progress))
                .font(DelosFonts.figtree(stage.tpx(LaunchLook.percentSize)))
                .tracking(stage.tpx(LaunchLook.percentTracking))
                .monospacedDigit()
                .foregroundStyle(colors.text2.color)
                .padding(.top, stage.px(12))
        }
        .frame(width: stage.px(LaunchLook.infoWidth))
        .padding(.bottom, stage.px(LaunchLook.infoBottom + stage.safe.bottom) + lift)
        .opacity(LaunchLook.infoAlpha(opening: opening))
    }

    private var track: some View {
        let width = stage.px(LaunchLook.trackWidth), height = stage.px(LaunchLook.trackHeight)
        return Capsule().fill(colors.text.opacity(0.16).color)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: [colors.accent2.color, colors.accent.color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * LaunchLook.unit(progress), height: height)
            }
    }
}

/// The hyperspace tunnel (`HyperspaceTunnel`): the Metal port of Android's AGSL shader, drawn at 0.6 of the size and scaled
/// up. Once the opening is complete it draws nothing.
struct LaunchTunnel: View {
    let run: LaunchTunnelRun
    let time: Double
    let progress: Double
    let opening: Double
    @Environment(\.delosColors) private var colors

    var body: some View {
        GeometryReader { proxy in
            let scale = LaunchLook.renderScale
            let size = CGSize(width: max(proxy.size.width * scale, 1), height: max(proxy.size.height * scale, 1))
            let _ = run.step(time: time, progress: progress, opening: opening)
            Rectangle().fill(.black)
                .frame(width: size.width, height: size.height)
                .colorEffect(shader(size: size))
                .drawingGroup()
                .scaleEffect(1 / scale, anchor: .topLeading)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func shader(size: CGSize) -> Shader {
        func color(_ rgba: RGBA, _ gain: Double) -> Shader.Argument {
            .float3(rgba.red * gain, rgba.green * gain, rgba.blue * gain)
        }
        return ShaderLibrary.bundle(.module).delosHyperspace(
            .float2(size.width, size.height), .float(time), .float(run.smoothed), .float(opening), .float(run.travel),
            color(colors.bg, 1), color(colors.accent, LaunchLook.accentGain), color(colors.accent2, LaunchLook.accent2Gain),
            color(colors.accent3, LaunchLook.accent3Gain))
    }
}

/// Leaving a stream (`StreamExit` of DELOS for Android): the portal opens over the stream ("Disconnecting", "Quitting
/// <game>", the PC below), the DELOS background comes in under it, and the last moments fade the scene into the flat
/// background color that the library then lights up from. The stream's own blur, zoom and fade are
/// ``StreamExitMotion``.
struct StreamExitScene: View {
    let portal: Portal
    let since: Date
    let reducedMotion: Bool
    let focus: FocusModel
    @Environment(\.delosColors) private var colors
    @State private var shown = false

    var body: some View {
        ZStack {
            PortalOverlay(portal: portal, burst: false, focus: focus, holdsFocus: false, onCancel: {})
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: PortalLook.fadeIn), value: shown)
            TimelineView(.animation) { timeline in
                colors.bg.color
                    .opacity(ExitLook.flat(at: timeline.date.timeIntervalSince(since), reduced: reducedMotion))
                    .ignoresSafeArea()
            }
            .allowsHitTesting(false)
        }
        .onAppear { shown = true }
    }
}

/// The stream's picture while it is left: it blurs and zooms in a little and gives way to the DELOS background. Not
/// moving while the stream runs; the clock is paused then.
struct StreamExitMotion<Content: View>: View {
    /// When leaving began; nil while the stream runs.
    let since: Date?
    let reducedMotion: Bool
    /// The picture, given how much of it has given way (0…1).
    let content: (Double) -> Content
    @Environment(\.stage) private var stage

    var body: some View {
        TimelineView(.animation(paused: since == nil)) { timeline in
            let time = since.map { timeline.date.timeIntervalSince($0) }
            content(time.map { ExitLook.cover(at: $0, reduced: reducedMotion) } ?? 0)
                .scaleEffect(time.map { ExitLook.scale(at: $0, reduced: reducedMotion) } ?? 1)
                .blur(radius: time.map { stage.px(ExitLook.blurRadius(at: $0, reduced: reducedMotion)) } ?? 0)
        }
    }
}
