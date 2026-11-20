import DelosData
import DelosInput
import SwiftUI

/// Full-viewport media. The native player, its loading thumbnail and the controls are independent siblings:
/// effects and transitions belong only to images and overlays, never to the live native surface.
struct OverviewViewer: View {
    let session: OverviewSession
    /// The items as they were when the viewer opened (``OverviewSession/viewerMedia``).
    let media: [OverviewContent.Media]
    let index: Int
    var onControlsVisibilityChanged: (Bool) -> Void = { _ in }
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    /// 0: on the thumbnail, 1: fitted.
    @State private var zoom = 0.0
    @State private var ready = false
    @State private var drag = CGSize.zero
    @State private var origin = CGPoint.zero
    /// The item the viewer has settled on (no zoom, no browse running): a video's player exists only then.
    @State private var settled: Int?
    @State private var closing = false

    private var video: OverviewVideo { session.video }

    /// The entire viewport belongs to media. Images fit their natural aspect ratio; the iframe fits the video itself.
    static func fit(width: Double, height: Double) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    static func videoFit(width: Double, height: Double) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    /// Where [item] shows, stage pixels.
    static func frame(_ item: OverviewContent.Media, width: Double, height: Double) -> CGRect {
        item.kind == .video ? videoFit(width: width, height: height) : fit(width: width, height: height)
    }

    var body: some View {
        let item = media[index]
        let target = target(item)
        let controls = video.controls
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if item.kind == .video, settled == index, !closing, video.error == nil, video.videoID == item.id {
                #if !os(tvOS)
                OverviewVideoPlayer(videoID: item.id, video: video)
                    .frame(width: target.width, height: target.height)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.identity)
                    .transaction { $0.animation = nil; $0.disablesAnimations = true }
                #endif
            }
            picture(item, tall: stage.height > 1200, target: target)
                .id(index)
                .transition(reduced ? .opacity : .asymmetric(
                    insertion: .modifier(active: Slide(x: session.viewerDirection * stage.px(160), scale: 0.96, opacity: 0), identity: Slide(x: 0, scale: 1, opacity: 1))
                        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.56)),
                    removal: .modifier(active: Slide(x: -session.viewerDirection * stage.px(90), scale: 0.94, opacity: 0), identity: Slide(x: 0, scale: 1, opacity: 1))
                        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42))))
            if item.kind == .video, let error = video.error {
                OverviewVideoError(code: error).frame(width: target.width, height: target.height)
            }
            if ready, controls.visible, !closing {
                ui(item, target: target)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        #if !os(tvOS)
        .simultaneousGesture(SpatialTapGesture().onEnded { _ in controls.onInput() })
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged {
            controls.onInput()
            drag = $0.translation
        }.onEnded { value in
            controls.onInput()
            let t = value.translation
            withAnimation(reduced ? nil : Motion.spring(400)) { drag = .zero }
            if t.height > stage.px(120), abs(t.height) > abs(t.width) { close() }
            else if t.width < -stage.px(90) { go(index + 1) }
            else if t.width > stage.px(90) { go(index - 1) }
        })
        .onContinuousHover { _ in controls.onInput() }
        .onKeyPress(phases: [.down, .up, .repeat]) { _ in controls.onInput(); return .ignored }
        #endif
        .onChange(of: session.viewerClosing) { _, now in if now { close() } }
        .onChange(of: scenePhase) { _, now in video.setActive(now == .active) }
        .onChange(of: controls.visible, initial: true) { _, visible in onControlsVisibilityChanged(visible) }
        .task(id: controls.visible) {
            while controls.visible {
                do { try await Task.sleep(for: controls.remaining()) } catch { return }
                controls.hideIfIdle()
            }
        }
        .task(id: index) {
            settled = nil
            video.reset(nil)
            controls.onInput()
            do { try await Task.sleep(for: .milliseconds(reduced ? 280 : 560)) } catch { return }
            guard !Task.isCancelled, session.viewer == index, !closing else { return }
            video.reset(item.kind == .video ? item.id : nil)
            settled = index
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(reduced ? 0 : 300)) } catch { return }
            ready = true
        }
        .task(id: closing) {
            guard closing else { return }
            do { try await Task.sleep(for: .milliseconds(reduced ? 240 : 440)) } catch { return }
            guard session.viewer == index, session.viewerClosing else { return }
            session.viewer = nil
            session.viewerClosing = false
        }
        .onAppear {
            session.viewerClosing = false
            video.setActive(scenePhase == .active)
            controls.onInput()
            withAnimation(reduced ? .easeOut(duration: 0.28) : .timingCurve(0.2, 0.9, 0.25, 1, duration: 0.56)) { zoom = 1 }
        }
        .onDisappear {
            video.setActive(false)
            video.reset(nil)
            onControlsVisibilityChanged(true)
        }
    }

    /// [item]'s place on the screen, points.
    private func target(_ item: OverviewContent.Media) -> CGRect {
        let fit = Self.frame(item, width: stage.width, height: stage.height)
        return CGRect(x: stage.px(fit.minX), y: stage.px(fit.minY), width: stage.px(fit.width), height: stage.px(fit.height))
    }


    private func picture(_ item: OverviewContent.Media, tall: Bool, target: CGRect) -> some View {
        let thumb = session.thumbFrames[item.id].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let from = thumb.flatMap { $0.intersects(target) ? $0 : nil }
        let z = reduced || from == nil ? 1 : zoom
        let startScale = from.map { min($0.width / target.width, $0.height / target.height) } ?? 1
        let scale = Motion.lerp(startScale, 1, z)
        let dx = from.map { ($0.midX - target.width * startScale / 2) * (1 - z) } ?? 0
        let dy = from.map { ($0.midY - target.height * startScale / 2) * (1 - z) } ?? 0
        let playing = item.kind == .video && video.videoID == item.id && video.started && video.error == nil && !closing
        return ViewerImage(item: item, maxPixels: max(1920, Int(max(target.width, target.height))))
            .frame(width: target.width, height: target.height)
            .background(Color.black)
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: dx + (item.kind == .video || reduced ? 0 : drag.width * 0.6),
                    y: dy + (item.kind == .video || reduced ? 0 : max(drag.height, 0)))
            .opacity(playing ? 0 : (from == nil ? zoom : 1))
            .animation(reduced ? nil : .easeOut(duration: 0.28), value: playing)
            .allowsHitTesting(false)
    }

    private func ui(_ item: OverviewContent.Media, target: CGRect) -> some View {
        let pointer = ControllerGlyphs.shared.kind == .pointer
        let touch = ControllerGlyphs.shared.kind == .touch
        return ZStack(alignment: .topLeading) {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.65), location: 0), .init(color: .clear, location: 0.2),
                .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.8), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
            HStack(alignment: .firstTextBaseline, spacing: stage.px(6)) {
                Text("\(index + 1)").font(DelosFonts.unbounded(stage.tpx(26), .bold)).foregroundStyle(colors.accent.color)
                Text(L("overview_viewer_count", media.count, name(item))).font(DelosFonts.figtree(stage.tpx(22), .bold)).foregroundStyle(colors.text2.color)
            }
            .monospacedDigit()
            .padding(.trailing, stage.px(180))
            .padding(.leading, stage.px(72 + stage.safe.leading))
            .padding(.top, stage.px(40))
            #if !os(tvOS)
            if item.kind == .video, video.error == nil {
                OverviewVideoBar(video: video)
                    .frame(width: target.width - stage.px(144), height: stage.px(72))
                    .position(x: target.midX, y: target.maxY - stage.px(148))
            }
            #endif
            if pointer {
                navButton(Symbols.chevronLeft, label: L("overview_previous")) { go(index - 1) }
                    .position(x: stage.px(40 + 42), y: stage.px(stage.height / 2))
                navButton(Symbols.chevronRight, label: L("overview_next")) { go(index + 1) }
                    .position(x: stage.px(stage.width - 40 - 42), y: stage.px(stage.height / 2))
            }
            if pointer || touch {
                navButton(Symbols.close, label: L("shell_hint_close"), size: 72) { close() }
                    .position(x: stage.px(stage.width - 56 - 36), y: stage.px(30 + 36))
            }
        }
    }

    private func navButton(_ icon: String, label: String, size: Double = 84, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SymbolView(symbol: icon, size: 34, color: colors.text)
                .frame(width: stage.px(size), height: stage.px(size))
                .background(GlassShape(Circle(), tint: colors.surface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func name(_ item: OverviewContent.Media) -> String {
        switch item.kind {
        case .video: item.name ?? L("overview_video")
        case .screenshot: L("overview_screenshot", (media.filter { $0.kind == .screenshot }.firstIndex(of: item) ?? 0) + 1)
        }
    }

    /// Goes to item [k]; past either end the picture nudges instead.
    func go(_ k: Int) {
        video.controls.onInput()
        guard media.indices.contains(k), k != index else { return }
        session.viewerDirection = k > index ? 1 : -1
        withAnimation(reduced ? .easeOut(duration: 0.28) : nil) { session.viewer = k }
    }

    func close() {
        guard !closing else { return }
        video.controls.onInput()
        closing = true
        session.viewerClosing = true
        ready = false
        settled = nil
        video.setActive(false)
        video.reset(nil)
        withAnimation(reduced ? .easeIn(duration: 0.24) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.44)) { zoom = 0 }
    }

    /// A command while the viewer is open, always taken. On a video that can play Left and Right seek 10 s, A plays or
    /// pauses and Y (or M) mutes; elsewhere Left and Right browse. L1 and R1 browse, B closes.
    static func handle(_ command: MenuCommand, session: OverviewSession, media: [OverviewContent.Media]) {
        guard let index = session.viewer, media.indices.contains(index) else { return }
        session.video.controls.onInput()
        let video = session.video
        let playable = media[index].kind == .video && video.error == nil
        func browse(_ step: Int) {
            guard media.indices.contains(index + step) else { return }
            session.viewerDirection = Double(step)
            session.viewer = index + step
        }
        switch command {
        case .left: if playable { video.seek(by: -10) } else { browse(-1) }
        case .right: if playable { video.seek(by: 10) } else { browse(1) }
        case .previousTab: browse(-1)
        case .nextTab: browse(1)
        case .accept: if playable { video.toggle() }
        case .toastAction, .mute: if playable { video.toggleMute() }
        case .back: session.viewerClosing = true
        default: break
        }
    }
}

/// A monotonic, allocation-free input deadline. Pointer motion does not invalidate the view while controls remain visible.
@MainActor
@Observable
final class OverviewViewerControls {
    private(set) var visible = true
    @ObservationIgnored private var lastInput: ContinuousClock.Instant

    init(now: ContinuousClock.Instant = .now) { lastInput = now }

    func onInput(at now: ContinuousClock.Instant = .now) {
        lastInput = now
        if !visible { visible = true }
    }

    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        max(.zero, .seconds(3) - lastInput.duration(to: now))
    }

    func hideIfIdle(at now: ContinuousClock.Instant = .now) {
        if remaining(at: now) == .zero { visible = false }
    }
}

/// Viewer-specific aspect fit, sharing the overview's decoded-image cache and download store.
private struct ViewerImage: View {
    let item: OverviewContent.Media
    let maxPixels: Int
    @Environment(GameMetadataModel.self) private var metadata
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
        }
        .task(id: item.id) {
            image = nil
            if let url = OverviewImageSizes.thumb(item, tall: true) {
                image = await load(url, pixels: 900)
            }
            guard !Task.isCancelled, let url = OverviewImageSizes.full(item, tall: true) else { return }
            if let full = await load(url, pixels: maxPixels), !Task.isCancelled { image = full }
        }
    }

    private func load(_ url: URL, pixels: Int) async -> CGImage? {
        let key = "\(url.absoluteString)#\(pixels)"
        if let cached = OverviewImageMemory.image(key) { return cached }
        guard let data = await metadata.images.data(url), !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { OverviewImageMemory.decode(data, maxPixels: pixels) }.value
        guard !Task.isCancelled else { return nil }
        if let decoded { OverviewImageMemory.store(decoded, key) }
        return decoded
    }
}

private struct Slide: ViewModifier {
    let x: Double
    let scale: Double
    let opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).scaleEffect(scale).opacity(opacity) }
}
