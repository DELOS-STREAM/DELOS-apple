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

    /// Where [item] shows, stage pixels: the whole viewport, edge to edge, for screenshots (fitted inside it by their
    /// aspect) and videos (the player letterboxes) alike.
    static func frame(_ item: OverviewContent.Media, width: Double, height: Double) -> CGRect {
        CGRect(x: 0, y: 0, width: width, height: height)
    }

    var body: some View {
        let item = media[index]
        let target = target(item)
        let controls = video.controls
        ZStack(alignment: .topLeading) {
            // Flying to or from its tile, the page shows through as the picture leaves it (the tile takes over as it lands)
            Color.black.ignoresSafeArea()
                .opacity(flies(item, target: target) ? zoom : 1)
            if item.kind == .video, settled == index, !closing, video.error == nil, video.videoID == item.id {
                if let stream = item.steam?.stream {
                    // A Steam movie in AVPlayer: an ordinary view under the dock, whose glass blurs the video
                    OverviewNativePlayer(url: stream, video: video)
                        .frame(width: target.width, height: target.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.identity)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                } else {
                    #if !os(tvOS)
                    // While the overlay is hidden YouTube's own surface takes the touches and clicks (an ad's Skip); a tap
                    // there also brings the overlay back. While it shows, the overlay's tap layer takes them
                    OverviewVideoPlayer(videoID: item.id, video: video, interactive: !controls.visible, onTap: { controls.onInput() })
                        .frame(width: target.width, height: target.height)
                        .allowsHitTesting(!controls.visible)
                        .accessibilityHidden(true)
                        .transition(.identity)
                        .transaction { $0.animation = nil; $0.disablesAnimations = true }
                    #endif
                }
            }
            picture(item, tall: stage.height > 1200, target: target)
                .id(index)
                .transition(reduced ? .opacity : .asymmetric(
                    insertion: .offset(x: session.viewerDirection * target.width * 0.04).combined(with: .opacity),
                    removal: .offset(x: -session.viewerDirection * target.width * 0.04).combined(with: .opacity)))
            if let frame = video.browseFrame {
                ViewerVideoStill(frame: frame, reduced: reduced) {
                    if video.browseFrame?.serial == frame.serial { video.browseFrame = nil }
                }
                .frame(width: target.width, height: target.height)
                .id(frame.serial)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if item.kind == .video, let error = video.error {
                OverviewVideoError(code: error, steam: item.steam != nil).frame(width: target.width, height: target.height)
            }
            #if !os(tvOS)
            tapLayer(item)
            #endif
            if let flash = controls.flash, playable(item) {
                SeekFlashView(flash: flash) { controls.endFlash($0) }
                    .id(flash.direction)
                    .position(x: stage.px(flash.direction > 0 ? stage.width * 0.78 : stage.width * 0.22), y: stage.px(stage.height * 0.42))
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
            }
            if ready, controls.visible, !closing {
                ui(item, target: target)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .animation(OverviewViewerMotion.animation(reduced: reduced), value: index)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
        #if !os(tvOS)
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged {
            controls.onInput()
            // A slider's drag is not a swipe
            guard !controls.dragging else { return }
            drag = $0.translation
        }.onEnded { value in
            controls.onInput()
            guard !controls.dragging, drag != .zero else { return }
            let t = value.translation
            withAnimation(reduced ? nil : Motion.spring(400)) { drag = .zero }
            if t.height > stage.px(120), abs(t.height) > abs(t.width) { close() }
            else if t.width < -stage.px(90) { go(index + 1) }
            else if t.width > stage.px(90) { go(index - 1) }
        })
        .onContinuousHover { _ in controls.onInput() }
        .onKeyPress(phases: [.down, .up, .repeat]) { _ in controls.onInput(); return .ignored }
        #endif
        #if os(macOS)
        // The pointer hides with the overlay (iPadOS hides an idle pointer by itself)
        .pointerVisibility(controls.visible ? .automatic : .hidden)
        #endif
        // A video that is not playing (paused, ended, loading) keeps the overlay up
        .onChange(of: holds(item), initial: true) { _, now in
            controls.paused = now
            controls.onInput()
        }
        .onChange(of: session.viewerClosing) { _, now in if now { close() } }
        .onChange(of: scenePhase) { _, now in video.setActive(now == .active) }
        .onChange(of: controls.visible, initial: true) { _, visible in onControlsVisibilityChanged(visible) }
        .onChange(of: reduced, initial: true) { _, now in video.reducedBrowse = now }
        .task(id: controls.visible) {
            while controls.visible {
                do { try await Task.sleep(for: controls.remaining()) } catch { return }
                controls.hideIfIdle()
            }
        }
        .task(id: index) {
            let playable = item.kind == .video && video.error == nil
            controls.focus = controls.focus.surviving(playable: playable, direction: session.viewerDirection)
            settled = nil
            video.reset(nil)
            controls.onInput()
            do { try await Task.sleep(for: .milliseconds(reduced ? 200 : 600)) } catch { return }
            #if DEBUG && canImport(UIKit)
            OverviewFrameLog.shared.stop()
            #endif
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
            video.browseTask?.cancel()
            video.browseFrame = nil
            video.reset(nil)
            onControlsVisibilityChanged(true)
        }
    }

    /// [item]'s place on the screen, points.
    private func target(_ item: OverviewContent.Media) -> CGRect {
        let fit = Self.frame(item, width: stage.width, height: stage.height)
        return CGRect(x: stage.px(fit.minX), y: stage.px(fit.minY), width: stage.px(fit.width), height: stage.px(fit.height))
    }


    /// Whether [item]'s picture flies to and from its tile (the tile is on screen and motion is not reduced).
    private func flies(_ item: OverviewContent.Media, target: CGRect) -> Bool {
        guard !reduced, let tile = session.thumbFrames[item.id] else { return false }
        return tile.offsetBy(dx: -origin.x, dy: -origin.y).intersects(target)
    }

    private func picture(_ item: OverviewContent.Media, tall: Bool, target: CGRect) -> some View {
        let thumb = session.thumbFrames[item.id].map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
        let from = thumb.flatMap { $0.intersects(target) ? $0 : nil }
        let z = reduced || from == nil ? 1 : zoom
        // The tile shows the picture filling it, enlarged by its parallax rim: the flight starts and ends at that size, so
        // nothing grows or shrinks as the tile takes over; the whole picture fades over the flight's quarter at the tile,
        // so the rim that overhangs the tile is gone as it lands
        let startScale = from.map { OverviewMotion.viewerFlightScale(tile: $0.size, target: target.size, fills: item.kind == .video) } ?? 1
        let scale = Motion.lerp(startScale, 1, z)
        let dx = from.map { ($0.midX - target.width * startScale / 2) * (1 - z) } ?? 0
        let dy = from.map { ($0.midY - target.height * startScale / 2) * (1 - z) } ?? 0
        let playing = item.kind == .video && video.videoID == item.id && video.started && video.error == nil && !closing
        // A trailer's thumbnail fills the viewer like the video, blurred 16 px while the player loads; it fades out over
        // the sharp video once the player plays
        return ViewerImage(item: item, maxPixels: max(1920, Int(max(target.width, target.height))))
            .frame(width: target.width, height: target.height)
            .blur(radius: item.kind == .video ? stage.px(16) : 0, opaque: true)
            .clipped()
            // A screenshot's letterbox fades with the flight: at the tile only the picture is left
            .background(Color.black.opacity(from == nil ? 1 : z))
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: dx + (item.kind == .video || reduced ? 0 : drag.width * 0.6),
                    y: dy + (item.kind == .video || reduced ? 0 : max(drag.height, 0)))
            .opacity(playing ? 0 : (from == nil ? zoom : min(max(z * 4, 0), 1)))
            .animation(reduced ? nil : .easeOut(duration: 0.28), value: playing)
            .allowsHitTesting(false)
    }

    private func playable(_ item: OverviewContent.Media) -> Bool { item.kind == .video && video.error == nil }

    /// A video that can play and is not playing: the overlay stays.
    private func holds(_ item: OverviewContent.Media) -> Bool { playable(item) && !video.playing }

    #if !os(tvOS)
    /// Over the picture, under the dock. Touch: a tap shows or hides the overlay, a double tap in the left or right third
    /// seeks 10 s. Pointer: a click plays or pauses. While the overlay is hidden over a YouTube video it lets the touches
    /// through to YouTube's surface (``OverviewVideoPlayer/interactive``); over a Steam movie it always takes them.
    private func tapLayer(_ item: OverviewContent.Media) -> some View {
        let controls = video.controls
        return GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { value in
                    controls.onInput()
                    guard playable(item), ControllerGlyphs.shared.kind != .pointer else { return }
                    let third = proxy.size.width / 3
                    if value.location.x < third { video.seek(by: -OverviewViewerControls.seekStep); controls.seekFlash(-1) }
                    else if value.location.x > 2 * third { video.seek(by: OverviewViewerControls.seekStep); controls.seekFlash(1) }
                }.exclusively(before: SpatialTapGesture().onEnded { _ in
                    if ControllerGlyphs.shared.kind == .pointer {
                        controls.onInput()
                        if playable(item) { video.toggle() }
                    } else if controls.visible {
                        controls.hide()
                    } else {
                        controls.onInput()
                    }
                }))
        }
        .allowsHitTesting(controls.visible || item.kind != .video || item.steam != nil || video.videoID != item.id)
        .accessibilityHidden(true)
    }
    #endif

    private func ui(_ item: OverviewContent.Media, target: CGRect) -> some View {
        let tall = stage.height > 1200
        let rise: AnyTransition = reduced ? .opacity.animation(.easeOut(duration: 0.2)) : .asymmetric(
            insertion: .modifier(active: DockRise(y: 18, opacity: 0), identity: DockRise(y: 0, opacity: 1)).animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)),
            removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.24)))
        let drop: AnyTransition = reduced ? .opacity.animation(.easeOut(duration: 0.2)) : .asymmetric(
            insertion: .modifier(active: DockRise(y: -14, opacity: 0), identity: DockRise(y: 0, opacity: 1)).animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42).delay(0.092)),
            removal: .opacity.animation(.timingCurve(0.4, 0, 1, 1, duration: 0.24)))
        return ZStack(alignment: .topLeading) {
            // Soft shades under the close button and the dock; each panel fades by its own opacity (the blur stays whole)
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: stage.px(220))
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.24)))
            OverviewDock(session: session, media: media, index: index, playable: playable(item), title: name(item), go: go)
                .padding(.horizontal, stage.px(64))
                .frame(width: stage.px(stage.width), height: stage.px(stage.height) - stage.px(tall ? 124 : 112), alignment: .bottom)
                .transition(rise)
            closeButton
                .position(x: stage.px(stage.width - 56 - 38), y: stage.px(40 + 38))
                .transition(drop)
        }
    }

    private var closeButton: some View {
        let focused = video.controls.focus == .close && [.controller, .keyboard].contains(ControllerGlyphs.shared.kind)
        return Button { close() } label: {
            InkSymbol(symbol: Symbols.close, size: DockButton.glyph(76), color: colors.text, filled: focused)
                .frame(width: stage.px(76), height: stage.px(76))
                .background {
                    DockGlass(radius: stage.px(38))
                    if focused { Circle().fill(Color.white.opacity(0.26)) }
                }
                .contentShape(Circle())
                .scaleEffect(focused && !reduced ? 1.08 : 1)
                .animation(reduced ? nil : .spring(response: 0.42, dampingFraction: 0.6), value: focused)
        }
        .buttonStyle(.plain)
        .overlay {
            ViewerDockRing(inflate: stage.px(OverviewDock.ringInflate(.close)))
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(L("shell_hint_close"))
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
        Self.browse(to: k, session: session, media: media)
    }

    /// Both pointer and controller browsing use one transaction, including focus migration.
    private static func browse(to next: Int, session: OverviewSession, media: [OverviewContent.Media]) {
        guard let index = session.viewer, media.indices.contains(next), next != index else { return }
        let video = session.video
        let generation = video.generation
        video.browseTask?.cancel()
        func finish(_ image: CGImage?) {
            guard video.generation == generation, session.viewer == index, !session.viewerClosing else { return }
            let direction = next > index ? 1.0 : -1.0
            if let image {
                video.browseFrame = .init(image: image, direction: direction, serial: generation)
            }
            session.viewerDirection = direction
            video.reset(nil)
            withAnimation(OverviewViewerMotion.animation(reduced: video.reducedBrowse)) {
                video.controls.focus = video.controls.focus.surviving(playable: media[next].kind == .video, direction: direction)
                session.viewer = next
            }
            #if DEBUG && canImport(UIKit)
            OverviewFrameLog.shared.start("viewer-browse")
            #endif
        }
        if video.started, let native = video.native {
            finish(native.snapshot())
        } else if video.started, let snapshot = video.snapshot {
            video.browseTask = Task { @MainActor in
                let image = await snapshot()
                guard !Task.isCancelled else { return }
                finish(image)
            }
        } else {
            finish(nil)
        }
    }

    func close() {
        guard !closing else { return }
        video.browseTask?.cancel()
        video.controls.onInput()
        closing = true
        session.viewerClosing = true
        ready = false
        settled = nil
        video.setActive(false)
        video.reset(nil)
        withAnimation(reduced ? .easeIn(duration: 0.24) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.44)) { zoom = 0 }
    }

    /// A command while the viewer is open, always taken. The dock's focus starts on the timeline of a video (Left and
    /// Right seek 10 s, A plays or pauses) or on next; elsewhere the D-pad walks the rows. Y (or M) mutes, L1 and R1 (only
    /// they) browse, B closes. A press while the overlay is hidden shows it with the focus back home, and acts.
    static func handle(_ command: MenuCommand, session: OverviewSession, media: [OverviewContent.Media]) {
        guard let index = session.viewer, media.indices.contains(index) else { return }
        let video = session.video
        let controls = video.controls
        let playable = media[index].kind == .video && video.error == nil
        let rows = OverviewDockFocus.rows(playable: playable)
        if !controls.visible || !rows.contains(where: { $0.contains(controls.focus) }) {
            controls.focus = OverviewDockFocus.home(playable: playable)
        }
        controls.onInput()
        func browse(_ step: Int) {
            Self.browse(to: index + step, session: session, media: media)
        }
        let focus = controls.focus
        switch command {
        case .left, .right:
            let step = command == .left ? -1 : 1
            switch focus {
            case .timeline:
                video.seek(by: OverviewViewerControls.seekStep * Double(step))
                controls.seekFlash(step)
            case .volume: video.setVolume(video.volume + Double(10 * step))
            default: if let next = focus.moved(command, playable: playable) { controls.focus = next }
            }
        case .up, .down:
            if let next = focus.moved(command, playable: playable) { controls.focus = next }
        case .previousTab: browse(-1)
        case .nextTab: browse(1)
        case .accept:
            switch focus {
            case .timeline, .play: if playable { video.toggle() }
            case .back:
                video.seek(by: -OverviewViewerControls.seekStep)
                controls.seekFlash(-1)
            case .forward:
                video.seek(by: OverviewViewerControls.seekStep)
                controls.seekFlash(1)
            case .previous: browse(-1)
            case .next: browse(1)
            case .mute, .volume: video.toggleMute()
            case .close: session.viewerClosing = true
            }
        case .toastAction, .mute: if playable { video.toggleMute() }
        case .back: session.viewerClosing = true
        default: break
        }
    }
}

/// A stop of the viewer's dock for the controller and the keyboard.
enum OverviewDockFocus: Hashable, Sendable {
    case close, timeline, previous, back, play, forward, next, mute, volume

    /// The dock's rows, top to bottom: close, then (a video that can play) the timeline and the transport with the sound,
    /// or (anything else) previous and next around the page indicator, which is no stop: only L1 and R1 browse.
    static func rows(playable: Bool) -> [[OverviewDockFocus]] {
        playable ? [[.close], [.timeline], [.previous, .back, .play, .forward, .next, .mute, .volume]]
            : [[.close], [.previous, .next]]
    }

    /// Where the focus starts: the timeline of a video, else next.
    static func home(playable: Bool) -> OverviewDockFocus { playable ? .timeline : .next }
    /// Keep shared stops in place. A disappearing video stop lands on its closest surviving neighbour.
    func surviving(playable: Bool, direction: Double) -> Self {
        if Self.rows(playable: playable).contains(where: { $0.contains(self) }) { return self }
        switch self {
        case .back: return .previous
        case .forward, .mute, .volume: return .next
        default: return direction < 0 ? .previous : .next
        }
    }

    /// The stop a direction leads to from [self]; nil: none that way. Up and Down land on the first stop of the new row
    /// (the app's rule for rows), except that the transport row is entered on play (its middle, the main control).
    func moved(_ command: MenuCommand, playable: Bool) -> OverviewDockFocus? {
        let rows = Self.rows(playable: playable)
        guard let r = rows.firstIndex(where: { $0.contains(self) }), let c = rows[r].firstIndex(of: self) else { return nil }
        switch command {
        case .left: return c > 0 ? rows[r][c - 1] : nil
        case .right: return c + 1 < rows[r].count ? rows[r][c + 1] : nil
        case .up: return r > 0 ? rows[r - 1][0] : nil
        case .down:
            guard r + 1 < rows.count else { return nil }
            return rows[r + 1].contains(.play) ? .play : rows[r + 1][0]
        default: return nil
        }
    }
}

/// The viewer's overlay: shown, its 3 s idle deadline (monotonic, allocation-free; pointer motion does not invalidate the
/// view while it shows), the hold while a video is paused, ended or a slider is dragged, the dock's focus and the seek flash.
@MainActor
@Observable
final class OverviewViewerControls {
    private(set) var visible = true
    var focus = OverviewDockFocus.timeline
    /// The running total of the last seek presses in one direction (B's arc flash: 10, 20…); nil: none showing.
    private(set) var flash: SeekFlash?
    /// A video that is paused, ended or not started: the overlay does not hide.
    @ObservationIgnored var paused = false
    /// A slider is dragged: the overlay does not hide, and the viewer's swipe does not run.
    @ObservationIgnored var dragging = false
    var held: Bool { paused || dragging }
    @ObservationIgnored private var lastInput: ContinuousClock.Instant
    @ObservationIgnored private var flashAt: ContinuousClock.Instant?

    struct SeekFlash: Equatable {
        /// -1 back, 1 forward.
        let direction: Int
        /// Seconds, a multiple of 10.
        let total: Int
        let serial: Int
    }

    /// One seek: the ± buttons, a double tap at a side, Left and Right on the timeline (seconds; owner, 2026-11-21).
    static let seekStep = 5.0

    /// How long a flash stays and how soon a repeated press adds to it.
    static let flashHold = Duration.milliseconds(900)

    init(now: ContinuousClock.Instant = .now) { lastInput = now }

    func onInput(at now: ContinuousClock.Instant = .now) {
        lastInput = now
        if !visible { visible = true }
    }

    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        max(.zero, .seconds(3) - lastInput.duration(to: now))
    }

    /// Hides the overlay 3 s after the last input; while [held] the 3 s start over.
    func hideIfIdle(at now: ContinuousClock.Instant = .now) {
        if held { lastInput = now; return }
        if remaining(at: now) == .zero { visible = false }
    }

    /// A tap on the picture while the overlay shows (touch): it goes at once.
    func hide() {
        if !held, visible { visible = false }
    }

    /// A seek of ``seekStep`` in [direction]: the flash on that side counts up while the presses come within ``flashHold``.
    func seekFlash(_ direction: Int, at now: ContinuousClock.Instant = .now) {
        let adds = flash?.direction == direction && flashAt.map { $0.duration(to: now) < Self.flashHold } == true
        let step = Int(Self.seekStep)
        flash = SeekFlash(direction: direction, total: adds ? (flash?.total ?? 0) + step : step, serial: (flash?.serial ?? 0) + 1)
        flashAt = now
    }

    func endFlash(_ serial: Int) {
        if flash?.serial == serial { flash = nil }
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
            if let image {
                if item.kind == .video {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
            }
        }
        .task(id: item.id) {
            image = nil
            if let url = OverviewImageSizes.thumb(item, tall: true) {
                image = await load(url, pixels: 900)
            }
            guard !Task.isCancelled, let url = OverviewImageSizes.full(item, tall: true) else { return }
            // YouTube's missing `maxresdefault` is a 120 × 90 placeholder: the thumbnail stays
            if let full = await load(url, pixels: maxPixels), full.width > 120, !Task.isCancelled { image = full }
            // A Steam trailer's own still replaces the shared poster once it is made
            if let still = item.steam?.still, let own = await load(still, pixels: maxPixels), !Task.isCancelled { image = own }
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

private struct DockRise: ViewModifier {
    let y: Double
    let opacity: Double
    @Environment(\.stage) private var stage
    func body(content: Content) -> some View { content.offset(y: stage.px(y)).opacity(opacity) }
}

/// The one spring used by the media layers and all dock geometry.
enum OverviewViewerMotion {
    static func animation(reduced: Bool) -> Animation {
        reduced ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.8)
    }
}

/// The released player's last frame participates in the transition, not its native surface.
private struct ViewerVideoStill: View {
    let frame: OverviewVideo.BrowseFrame
    let reduced: Bool
    let finished: () -> Void
    @State private var leaving = false

    var body: some View {
        GeometryReader { proxy in
            Image(decorative: frame.image, scale: 1).resizable().scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color.black)
                .offset(x: leaving && !reduced ? -frame.direction * proxy.size.width * 0.04 : 0)
                .opacity(leaving ? 0 : 1)
        }
        .onAppear {
            withAnimation(OverviewViewerMotion.animation(reduced: reduced)) { leaving = true }
        }
        .task {
            do { try await Task.sleep(for: .milliseconds(reduced ? 200 : 600)) } catch { return }
            finished()
        }
    }
}
