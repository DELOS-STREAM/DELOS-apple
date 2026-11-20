import DelosData
import DelosInput
import SwiftUI

/// The full-screen screenshot viewer (`Viewer` of the prototype): it zooms out of the thumbnail and back into it (a fade
/// when the thumbnail is off screen), crossfades with a little parallax between items, shows the count and a filmstrip
/// over a blurred backdrop (a material: real blur). Left and Right browse, A on a video opens it, B closes; touch swipes
/// sideways to browse and down to close; the pointer has arrows and a close button.
struct OverviewViewer: View {
    let session: OverviewSession
    let media: [OverviewContent.Media]
    let index: Int
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.openURL) private var openURL
    /// 0: on the thumbnail, 1: fitted.
    @State private var zoom = 0.0
    @State private var ready = false
    @State private var drag = CGSize.zero
    @State private var origin = CGPoint.zero

    /// The fitted picture, stage pixels: 16:9 inside the stage less 280 × 300.
    static func fit(width: Double, height: Double) -> CGRect {
        var w = width - 280, h = w * 9 / 16
        if h > height - 300 { h = height - 300; w = h * 16 / 9 }
        return CGRect(x: (width - w) / 2, y: (height - h) / 2 - 10, width: w, height: h)
    }

    var body: some View {
        let fit = Self.fit(width: stage.width, height: stage.height)
        let target = CGRect(x: stage.px(fit.minX), y: stage.px(fit.minY), width: stage.px(fit.width), height: stage.px(fit.height))
        let item = media[index]
        let tall = stage.height > 1200
        let pullDown = max(drag.height, 0)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Color(.sRGB, red: 4 / 255, green: 8 / 255, blue: 16 / 255, opacity: 0.55))
                .opacity(zoom * (1 - min(pullDown, 400) / 500))
                .ignoresSafeArea()
                .onTapGesture { close() }
            picture(item, tall: tall, target: target)
                .id(index)
                .transition(reduced ? .opacity : .asymmetric(
                    insertion: .modifier(active: Slide(x: session.viewerDirection * stage.px(160), scale: 0.96, opacity: 0), identity: Slide(x: 0, scale: 1, opacity: 1))
                        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.56)),
                    removal: .modifier(active: Slide(x: -session.viewerDirection * stage.px(90), scale: 0.94, opacity: 0), identity: Slide(x: 0, scale: 1, opacity: 1))
                        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42))))
            ui(item, target: target)
                .opacity(ready ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: ready)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        #if !os(tvOS)
        .gesture(DragGesture(minimumDistance: 12).onChanged { drag = $0.translation }.onEnded { value in
            let t = value.translation
            withAnimation(Motion.spring(400)) { drag = .zero }
            if t.height > stage.px(120), abs(t.height) > abs(t.width) { close() }
            else if t.width < -stage.px(90) { go(index + 1) }
            else if t.width > stage.px(90) { go(index - 1) }
        })
        #endif
        .onChange(of: session.viewerClosing) { _, now in if now { close() } }
        .onAppear {
            session.viewerClosing = false
            withAnimation(reduced ? .easeOut(duration: 0.28) : .timingCurve(0.2, 0.9, 0.25, 1, duration: 0.56)) { zoom = 1 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduced ? 0 : 300))
                ready = true
            }
        }
    }

    private func picture(_ item: OverviewContent.Media, tall: Bool, target: CGRect) -> some View {
        let thumb = session.thumbFrames[index].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        // From the thumbnail when it is on screen, else a fade
        let from = thumb.flatMap { $0.intersects(CGRect(x: 0, y: 0, width: stage.px(stage.width), height: stage.px(stage.height))) ? $0 : nil }
        let z = reduced || from == nil ? 1 : zoom
        let sx = from.map { Motion.lerp($0.width / target.width, 1, z) } ?? 1
        let sy = from.map { Motion.lerp($0.height / target.height, 1, z) } ?? 1
        let dx = from.map { Motion.lerp($0.minX - target.minX, 0, z) } ?? 0
        let dy = from.map { Motion.lerp($0.minY - target.minY, 0, z) } ?? 0
        let pull = max(drag.height, 0)
        return ZStack(alignment: .bottomLeading) {
            RemoteImage(url: OverviewImageSizes.full(item, tall: tall), maxPixels: tall ? 1920 : 1280,
                        placeholder: OverviewImageSizes.thumb(item, tall: tall), placeholderPixels: tall ? 900 : 600)
            if item.kind == .video {
                SymbolView(symbol: Symbols.videoPlay, size: 96, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
                    .shadow(color: .black.opacity(0.6), radius: stage.px(8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(L("overview_video_youtube", item.name ?? L("overview_video"))).font(DelosFonts.figtree(stage.tpx(26), .bold)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: stage.px(5)).padding(stage.px(28))
            }
        }
        .frame(width: target.width, height: target.height)
        .clipShape(RoundedRectangle(cornerRadius: stage.px(Motion.lerp(40, 18, z)), style: .continuous))
        .shadow(color: .black.opacity(0.8), radius: stage.px(60), y: stage.px(50))
        .scaleEffect(x: sx * (1 - min(pull, 400) / 1600), y: sy * (1 - min(pull, 400) / 1600), anchor: .topLeading)
        .offset(x: target.minX + dx + (pull > 0 ? 0 : drag.width * 0.6), y: target.minY + dy + pull)
        .opacity(from == nil && !reduced ? zoom : 1)
    }

    private func ui(_ item: OverviewContent.Media, target: CGRect) -> some View {
        let pointer = ControllerGlyphs.shared.kind == .pointer
        let touch = ControllerGlyphs.shared.kind == .touch
        return ZStack(alignment: .topLeading) {
            HStack(alignment: .firstTextBaseline, spacing: stage.px(6)) {
                Text("\(index + 1)").font(DelosFonts.unbounded(stage.tpx(26), .bold)).foregroundStyle(colors.text.color)
                Text(L("overview_viewer_count", media.count, name(item))).font(DelosFonts.figtree(stage.tpx(22), .bold)).foregroundStyle(colors.text2.color)
            }
            .monospacedDigit()
            .padding(.leading, stage.px(72 + stage.safe.leading))
            .padding(.top, stage.px(40))
            HStack(spacing: stage.px(12)) {
                ForEach(Array(media.enumerated()), id: \.offset) { k, m in
                    RemoteImage(url: OverviewImageSizes.thumb(m, tall: false), maxPixels: 200)
                        .frame(width: stage.px(96), height: stage.px(54))
                        .clipShape(RoundedRectangle(cornerRadius: stage.px(8)))
                        .overlay { if k == index { RoundedRectangle(cornerRadius: stage.px(8)).strokeBorder(colors.accent.color, lineWidth: stage.px(3)).padding(-stage.px(3)) } }
                        .opacity(k == index ? 1 : 0.45)
                        .scaleEffect(k == index ? 1.18 : 1)
                        .animation(reduced ? nil : Motion.spring(420), value: index)
                        .onTapGesture { go(k) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, stage.px(112))
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
        guard media.indices.contains(k), k != index else { return }
        session.viewerDirection = k > index ? 1 : -1
        withAnimation(reduced ? .easeOut(duration: 0.28) : nil) { session.viewer = k }
    }

    func close() {
        ready = false
        withAnimation(reduced ? .easeIn(duration: 0.24) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.44)) { zoom = 0 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduced ? 240 : 440))
            session.viewer = nil
            session.viewerClosing = false
        }
    }

    /// A command while the viewer is open: Left and Right browse, A watches a video, B closes. Always taken.
    static func handle(_ command: MenuCommand, session: OverviewSession, media: [OverviewContent.Media], openURL: OpenURLAction) {
        guard let index = session.viewer else { return }
        switch command {
        case .left where index > 0:
            session.viewerDirection = -1
            session.viewer = index - 1
        case .right where index + 1 < media.count:
            session.viewerDirection = 1
            session.viewer = index + 1
        case .back: session.viewerClosing = true
        case .accept:
            if media[index].kind == .video, let url = IGDBImage.videoPage(media[index].id) { openURL(url) }
        default: break
        }
    }
}

private struct Slide: ViewModifier {
    let x: Double
    let scale: Double
    let opacity: Double
    func body(content: Content) -> some View { content.offset(x: x).scaleEffect(scale).opacity(opacity) }
}
