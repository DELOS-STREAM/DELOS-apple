import CoreText
import DelosData
import DelosInput
import SwiftUI

/// The viewer's dock (variant A): one tall glass panel across the bottom. A video's has the timeline (buffered and played,
/// the elapsed and the remaining time) over a row of the count and title, the transport centred on the screen and the
/// sound; a screenshot's has previous, a page indicator and next instead of the timeline and the transport.
struct OverviewDock: View {
    let session: OverviewSession
    let media: [OverviewContent.Media]
    let index: Int
    /// A video that can play: the timeline, the transport and the sound.
    let playable: Bool
    let title: String
    let go: (Int) -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @Namespace private var ring

    private var video: OverviewVideo { session.video }
    private var controls: OverviewViewerControls { video.controls }
    /// The focus ring shows for the controller and the keyboard only.
    private var ringShown: Bool {
        let kind = ControllerGlyphs.shared.kind
        return kind == .controller || kind == .keyboard
    }

    var body: some View {
        VStack(spacing: stage.px(14)) {
            if playable {
                HStack(spacing: stage.px(22)) {
                    Text(OverviewVideo.clock(video.time))
                        .frame(width: stage.px(104), alignment: .trailing)
                    DockTimeline(video: video)
                        .stop(.timeline, focus: controls.focus, ring: ring)
                    Text("\u{2212}" + OverviewVideo.clock(max(0, video.duration - video.time)))
                        .frame(width: stage.px(104), alignment: .leading)
                }
                .font(DelosFonts.figtree(stage.tpx(22), .bold))
                .foregroundStyle(colors.text.color)
                .monospacedDigit()
                .frame(height: stage.px(52))
            }
            // Info and sound take equal widths, so the transport is centred on the dock and the screen
            HStack(spacing: stage.px(30)) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                if playable { transport } else { pages }
                sound.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minHeight: stage.px(playable ? 128 : 96))
        }
        .padding(.top, stage.px(24))
        .padding(.horizontal, stage.px(44))
        .padding(.bottom, stage.px(30))
        .background { DockGlass(radius: stage.px(46)) }
        // Any press on the dock counts as input (the idle timer starts over)
        .simultaneousGesture(TapGesture().onEnded { controls.onInput() })
        .overlay {
            // One ring that glides to the focused stop (`matchedGeometryEffect` on the stops' frames)
            if ringShown, controls.focus != .close, OverviewDockFocus.rows(playable: playable).contains(where: { $0.contains(controls.focus) }) {
                Capsule()
                    .strokeBorder(colors.accent.color, lineWidth: stage.px(5))
                    .padding(-stage.px(9))
                    .matchedGeometryEffect(id: controls.focus, in: ring, properties: .frame, isSource: false)
                    .animation(reduced ? nil : Motion.spring(Motion.focus), value: controls.focus)
                    .allowsHitTesting(false)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: stage.px(10)) {
            Text(session.app.title.uppercased())
                .font(DelosFonts.figtree(stage.tpx(18), .bold))
                .tracking(stage.px(2))
                .foregroundStyle(colors.text2.color)
            HStack(alignment: .firstTextBaseline, spacing: stage.px(8)) {
                Text("\(index + 1)").font(DelosFonts.unbounded(stage.tpx(34), .bold)).foregroundStyle(colors.accent.color)
                Text(L("overview_viewer_count", media.count, title))
                    .font(DelosFonts.figtree(stage.tpx(30), .bold)).foregroundStyle(colors.text.color)
            }
            .monospacedDigit()
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var transport: some View {
        HStack(spacing: stage.px(26)) {
            DockButton(symbol: Symbols.playerPrevious, size: 76, label: L("overview_previous"), enabled: index > 0) { go(index - 1) }
                .stop(.previous, focus: controls.focus, ring: ring)
            DockButton(symbol: Symbols.playerSeekBack, size: 92, label: L("overview_video_back"), ten: true) {
                video.seek(by: -10)
                controls.seekFlash(-1)
            }
            .stop(.back, focus: controls.focus, ring: ring)
            DockButton(symbol: video.playing ? Symbols.playerPause : Symbols.playerPlay, size: 124,
                       label: video.playing ? L("overview_hint_pause") : L("overview_hint_play"), primary: true) { video.toggle() }
                .stop(.play, focus: controls.focus, ring: ring)
            DockButton(symbol: Symbols.playerSeekForward, size: 92, label: L("overview_video_forward"), ten: true) {
                video.seek(by: 10)
                controls.seekFlash(1)
            }
            .stop(.forward, focus: controls.focus, ring: ring)
            DockButton(symbol: Symbols.playerNext, size: 76, label: L("overview_next"), enabled: index + 1 < media.count) { go(index + 1) }
                .stop(.next, focus: controls.focus, ring: ring)
        }
    }

    /// A screenshot: previous, one dot per item (videos as rings, the current one a gold bar) and next. Only L1 and R1
    /// browse with the controller; a dot is a touch and pointer target.
    private var pages: some View {
        HStack(spacing: stage.px(26)) {
            DockButton(symbol: Symbols.playerPrevious, size: 76, label: L("overview_previous"), enabled: index > 0) { go(index - 1) }
                .stop(.previous, focus: controls.focus, ring: ring)
            HStack(spacing: stage.px(14)) {
                ForEach(media.indices, id: \.self) { k in
                    let on = k == index
                    Capsule()
                        .fill(on ? colors.accent.color : (media[k].kind == .video ? Color.clear : Color.white.opacity(0.4)))
                        .overlay {
                            if !on, media[k].kind == .video { Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: stage.px(2)) }
                        }
                        .frame(width: stage.px(on ? 40 : 12), height: stage.px(12))
                        .padding(.vertical, stage.px(18))
                        .contentShape(Rectangle())
                        .onTapGesture { go(k) }
                }
            }
            .animation(reduced ? .easeOut(duration: 0.2) : Motion.spring(Motion.focus), value: index)
            .padding(.horizontal, stage.px(30))
            .frame(height: stage.px(76))
            .background(Capsule().fill(Color.white.opacity(0.08)).overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: stage.px(1))))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(index + 1) " + L("overview_viewer_count", media.count, title))
            DockButton(symbol: Symbols.playerNext, size: 76, label: L("overview_next"), enabled: index + 1 < media.count) { go(index + 1) }
                .stop(.next, focus: controls.focus, ring: ring)
        }
    }

    @ViewBuilder private var sound: some View {
        if playable {
            HStack(spacing: stage.px(18)) {
                DockButton(symbol: Self.speaker(muted: video.muted, volume: video.volume), size: 76,
                           label: video.muted ? L("overview_hint_unmute") : L("overview_hint_mute")) { video.toggleMute() }
                    .stop(.mute, focus: controls.focus, ring: ring)
                DockVolume(video: video)
                    .frame(width: stage.px(200), height: stage.px(52))
                    .stop(.volume, focus: controls.focus, ring: ring)
            }
        } else {
            // Keeps the info's width matched, so the page indicator stays centred
            Color.clear.frame(height: 1)
        }
    }

    /// The sound's icon: muted, none, low (under half) or high.
    static func speaker(muted: Bool, volume: Double) -> String {
        if muted { return Symbols.playerMuted }
        if volume <= 0 { return Symbols.playerVolumeNone }
        return volume < 50 ? Symbols.playerVolumeLow : Symbols.playerSound
    }
}

private extension View {
    /// A stop of the dock's focus: the ring takes its frame while it is focused.
    func stop(_ id: OverviewDockFocus, focus: OverviewDockFocus, ring: Namespace.ID) -> some View {
        background(Color.clear.matchedGeometryEffect(id: id, in: ring, properties: .frame, isSource: true))
    }
}

/// The dock's glass: a light tint (0.20) over a real backdrop blur, the system material, which blurs whatever is drawn
/// below it, the video's web view included; a top highlight and a hairline.
struct DockGlass: View {
    let radius: CGFloat
    @Environment(\.stage) private var stage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color(red: 10 / 255, green: 16 / 255, blue: 32 / 255).opacity(0.20))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.10), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)))
            shape.strokeBorder(Color.white.opacity(0.14), lineWidth: stage.px(1))
        }
        .environment(\.colorScheme, .dark)
    }
}

/// A round dock button: [size] stage pixels, its glyph optically centred (``InkSymbol``). The primary one (play) is the
/// gold disc; [ten] draws "10" inside the seek arrows.
struct DockButton: View {
    let symbol: String
    let size: Double
    let label: String
    var primary = false
    var ten = false
    var enabled = true
    let action: () -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                InkSymbol(symbol: symbol, size: Self.glyph(size), color: primary ? colors.onAccent : colors.text,
                          filled: primary, centroid: symbol == Symbols.playerPlay)
                if ten {
                    Text("10")
                        .font(DelosFonts.figtree(stage.tpx(size * 0.17), .heavy))
                        .foregroundStyle(colors.text.color)
                        .offset(y: stage.px(size * 0.02))
                }
            }
            .frame(width: stage.px(size), height: stage.px(size))
            .background {
                if primary {
                    Circle().fill(colors.accent.color)
                } else {
                    Circle().fill(Color.white.opacity(hovered ? 0.18 : 0.08))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: stage.px(1)))
                }
            }
            .contentShape(Circle())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        #if !os(tvOS)
        .onHover { hovered = $0 }
        #endif
        .accessibilityLabel(label)
    }

    /// The glyph's em for a button [size] wide: about 0.44 of it.
    static func glyph(_ size: Double) -> Double { (size * 0.44).rounded() }
}

/// A Phosphor glyph drawn as its outline, placed so its ink is centred in the frame: the middle of its ink bounds, or with
/// [centroid] the centroid of its area (the play triangle sits a little right of its box, as the eye expects). A glyph of
/// the font's text layout sits by its advance and line metrics instead, which leaves most icons off centre.
struct InkSymbol: View {
    let symbol: String
    let size: Double
    var color: RGBA
    var filled = false
    var centroid = false
    @Environment(\.stage) private var stage

    var body: some View {
        InkShape(path: Path(InkGlyph.path(symbol, size: stage.tpx(size), filled: filled, centroid: centroid)))
            .fill(color.color)
            .accessibilityHidden(true)
    }
}

private struct InkShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        path.applying(CGAffineTransform(translationX: rect.midX, y: rect.midY))
    }
}

/// Glyph outlines centred on the origin, cached by glyph, em and centring.
@MainActor
enum InkGlyph {
    private struct Key: Hashable {
        let symbol: String
        let size: CGFloat
        let filled: Bool
        let centroid: Bool
    }

    private static var cache: [Key: CGPath] = [:]

    /// [symbol]'s outline at [size] points, y down, its ink centre (or area centroid) on the origin.
    static func path(_ symbol: String, size: CGFloat, filled: Bool, centroid: Bool = false) -> CGPath {
        let key = Key(symbol: symbol, size: size, filled: filled, centroid: centroid)
        if let cached = cache[key] { return cached }
        let font = CTFontCreateWithName((filled ? "Phosphor-Fill" : "Phosphor") as CFString, size, nil)
        let chars = Array(symbol.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        var outline = CGPath(rect: .zero, transform: nil)
        if CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count), let glyph = CTFontCreatePathForGlyph(font, glyphs[0], nil) {
            var flip = CGAffineTransform(scaleX: 1, y: -1)
            outline = glyph.copy(using: &flip) ?? glyph
        }
        let box = outline.boundingBoxOfPath
        let centre = centroid ? Self.centroid(outline) ?? CGPoint(x: box.midX, y: box.midY) : CGPoint(x: box.midX, y: box.midY)
        var move = CGAffineTransform(translationX: -centre.x, y: -centre.y)
        let placed = outline.copy(using: &move) ?? outline
        cache[key] = placed
        return placed
    }

    /// The area centroid of [path]'s closed contours (shoelace over the flattened outline); nil without area.
    static func centroid(_ path: CGPath) -> CGPoint? {
        var area = 0.0, cx = 0.0, cy = 0.0
        var points: [CGPoint] = []
        func close() {
            guard points.count > 2 else { points.removeAll(); return }
            for i in points.indices {
                let p = points[i], q = points[(i + 1) % points.count]
                let cross = Double(p.x * q.y - q.x * p.y)
                area += cross
                cx += Double(p.x + q.x) * cross
                cy += Double(p.y + q.y) * cross
            }
            points.removeAll()
        }
        path.applyWithBlock { element in
            let e = element.pointee
            let last = points.last ?? .zero
            switch e.type {
            case .moveToPoint:
                close()
                points.append(e.points[0])
            case .addLineToPoint:
                points.append(e.points[0])
            case .addQuadCurveToPoint:
                let c = e.points[0], end = e.points[1]
                for s in 1...8 {
                    let t = CGFloat(s) / 8, u = 1 - t
                    points.append(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * end.x, y: u * u * last.y + 2 * u * t * c.y + t * t * end.y))
                }
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for s in 1...8 {
                    let t = CGFloat(s) / 8, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * end.x, y: a * last.y + b * c1.y + c * c2.y + d * end.y))
                }
            case .closeSubpath:
                close()
            @unknown default: break
            }
        }
        close()
        guard abs(area) > 1e-6 else { return nil }
        return CGPoint(x: cx / (3 * area), y: cy / (3 * area))
    }
}

/// The dock's timeline: the track, the buffered and the played share, a knob. Dragging seeks where it is let go (the
/// overlay holds meanwhile); the pointer's hover shows the time under it.
struct DockTimeline: View {
    let video: OverviewVideo
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @State private var scrub: Double?
    @State private var hover: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let played = scrub ?? (video.duration > 0 ? min(max(video.time / video.duration, 0), 1) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(Color.white.opacity(0.34)).frame(width: w * max(video.loaded, played))
                Capsule().fill(colors.accent.color).frame(width: w * played)
                Circle().fill(colors.accent.color)
                    .frame(width: stage.px(scrub == nil ? 22 : 30), height: stage.px(scrub == nil ? 22 : 30))
                    .offset(x: w * played - stage.px(scrub == nil ? 11 : 15))
            }
            .frame(height: stage.px(8))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let x = hover ?? scrub.map({ CGFloat($0) * w }), video.duration > 0 {
                    Text(OverviewVideo.clock(Double(x / w) * video.duration))
                        .font(DelosFonts.figtree(stage.tpx(20), .bold))
                        .monospacedDigit()
                        .foregroundStyle(colors.text.color)
                        .padding(.horizontal, stage.px(12))
                        .frame(height: stage.px(36))
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .fixedSize()
                        .position(x: min(max(x, stage.px(40)), w - stage.px(40)), y: -stage.px(22))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                video.controls.onInput()
                video.controls.dragging = true
                scrub = min(max(value.location.x / w, 0), 1)
            }.onEnded { value in
                video.controls.dragging = false
                video.controls.onInput()
                video.seek(to: min(max(value.location.x / w, 0), 1))
                scrub = nil
            })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = min(max(point.x, 0), w)
                case .ended: hover = nil
                }
            }
            #endif
        }
        .accessibilityElement()
        .accessibilityLabel(L("overview_hint_seek"))
        .accessibilityValue(OverviewVideo.clock(video.time))
        .accessibilityAdjustableAction { direction in
            video.seek(by: direction == .increment ? 10 : -10)
        }
    }
}

/// The dock's volume slider (0…100); dragging it holds the overlay.
struct DockVolume: View {
    let video: OverviewVideo
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        GeometryReader { proxy in
            let w = max(proxy.size.width, 1)
            let level = video.muted ? 0 : video.volume / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22))
                Capsule().fill(colors.text.color).frame(width: w * level)
                Circle().fill(colors.text.color)
                    .frame(width: stage.px(22), height: stage.px(22))
                    .offset(x: w * level - stage.px(11))
            }
            .frame(height: stage.px(6))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                video.controls.onInput()
                video.controls.dragging = true
                video.setVolume(min(max(value.location.x / w, 0), 1) * 100)
            }.onEnded { _ in
                video.controls.dragging = false
                video.controls.onInput()
            })
            #endif
        }
        .accessibilityElement()
        .accessibilityLabel(L("overview_video_volume"))
        .accessibilityValue("\(Int(video.muted ? 0 : video.volume))")
        .accessibilityAdjustableAction { direction in
            video.setVolume(video.volume + (direction == .increment ? 10 : -10))
        }
    }
}

/// The seek feedback (variant B's arc flash): a gold arc on the side of the seek with the running total (10, 20…), that
/// nudges outwards on each press and fades after ``OverviewViewerControls/flashHold``.
struct SeekFlashView: View {
    let flash: OverviewViewerControls.SeekFlash
    let onDone: (Int) -> Void
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    @Environment(\.reducedMotion) private var reduced
    @State private var nudge = 0.0

    var body: some View {
        let d = Double(flash.direction)
        ZStack {
            // The arc: the side of a ring, the open side towards the middle of the screen
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(colors.accent.color.opacity(0.85), style: StrokeStyle(lineWidth: stage.px(10), lineCap: .round))
                .rotationEffect(.degrees(d > 0 ? -54 : 126))
                .frame(width: stage.px(300), height: stage.px(300))
            Circle()
                .fill(RadialGradient(colors: [colors.accent.color.opacity(0.30), .clear], center: .center, startRadius: 0, endRadius: stage.px(150)))
                .frame(width: stage.px(300), height: stage.px(300))
            VStack(spacing: stage.px(6)) {
                InkSymbol(symbol: d > 0 ? Symbols.playerSeekForward : Symbols.playerSeekBack, size: 48, color: colors.text)
                    .frame(width: stage.px(60), height: stage.px(60))
                Text("\(flash.total) s")
                    .font(DelosFonts.unbounded(stage.tpx(30), .bold))
                    .monospacedDigit()
                    .foregroundStyle(colors.text.color)
                    .contentTransition(.numericText(value: Double(flash.total)))
            }
        }
        .offset(x: stage.px(nudge * d))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: flash.serial) {
            if !reduced {
                nudge = 26
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42)) { nudge = 0 }
            }
            do { try await Task.sleep(for: OverviewViewerControls.flashHold) } catch { return }
            onDone(flash.serial)
        }
    }
}
