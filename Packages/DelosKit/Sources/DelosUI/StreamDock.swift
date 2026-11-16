import SwiftUI

/// The numbers of the stream menu's dock (`StreamMenuLayout` and `StreamMenuMotion` of DELOS for Android) for [count]
/// tiles: stage pixels and milliseconds. The tiles and the labels take their progress from one clock (milliseconds since
/// the menu opened, and since it started to close), like the prototype's per-element animations with a delay.
enum StreamDockLayout {
    static let tile = 150.0
    static let tileRadius = 42.0
    static let gap = 40.0
    static let icon = 64.0
    static let focusScale = 1.12
    static let iconFocusScale = 1.04
    /// The ring around the focused tile: 186 box (the tile at 1.12 is 168, plus 9 each side).
    static let ring = 186.0
    static let ringRadius = 56.0
    static let ringWidth = 4.0
    static let labelSize = 24.0
    static let labelGap = 24.0
    static let labelFocusShift = 8.0
    /// The tiles' top lies this far above the stage's bottom edge (1080 − 628).
    static let topFromBottom = 452.0

    static let pillHeight = 34.0
    static let pillSize = 18.0
    static let pillPaddingX = 15.0
    static let pillRight = -12.0
    static let pillTop = -14.0

    // The entrance (delays from the moment the menu opens), milliseconds
    static let enter = 620.0
    static let tileDelay = 100.0
    static let staggerTile = 42.0
    static let labelExtraDelay = 140.0
    static let ringExtraDelay = 260.0
    static let labelDuration = enter * 0.8
    static let exitStagger = 8.0
    /// The gradient behind the tiles (and the blur of the stream) arrives and leaves.
    static let gradientIn = 460.0
    static let gradientOut = leave + 80
    static let leave = Motion.exit
    static let ringGlide = 560.0
    static let breathe = 2600.0
    /// The stream behind the menu is blurred by this many stage pixels.
    static let videoBlur = 50.0

    static func rowWidth(count: Int) -> Double { Double(count) * tile + Double(max(count - 1, 0)) * gap }

    static func tileLeft(_ index: Int) -> Double { Double(index) * (tile + gap) }

    static func ringLeft(_ index: Int) -> Double { tileLeft(index) + tile / 2 - ring / 2 }

    static func tileDelay(_ index: Int) -> Double { tileDelay + Double(max(index, 0)) * staggerTile }

    static func labelDelay(_ index: Int) -> Double { tileDelay(index) + labelExtraDelay }

    static func ringDelay(_ index: Int) -> Double { tileDelay(index) + ringExtraDelay }

    /// The tile's exit starts later the further left it is: the last one leaves first.
    static func exitDelay(_ index: Int, count: Int) -> Double { Double(max(count - 1 - index, 0)) * exitStagger }

    /// The time the whole entrance needs: the ring on the last tile is the last to arrive.
    static func enterTotal(count: Int) -> Double {
        max(ringDelay(count - 1) + enter, labelDelay(count - 1) + labelDuration)
    }

    /// The time the whole exit needs: the first tile starts last.
    static func exitTotal(count: Int) -> Double { exitDelay(0, count: count) + leave }

    /// The dock stays mounted this long after the menu closed: the exit, then 80 ms.
    static func closeTotal(count: Int) -> Double { exitTotal(count: count) + 80 }
}

/// The stream menu's dock: the existing four actions as glass tiles of Android's stream menu, one gold ring that glides
/// between them and breathes, on a dark ramp over the blurred stream. They rise in one after the other and leave the other
/// way round. [open] false: the dock is leaving (the parent unmounts it once the exit is over).
struct StreamMenu: View {
    let focus: FocusModel
    let controller: StreamController
    let open: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(Layers.self) private var layers: Layers?
    @State private var openedAt = Date()
    @State private var closedAt: Date?
    @State private var animating = true

    private typealias D = StreamDockLayout

    static let resumeID = "stream-resume"
    private static let ids = [resumeID, "stream-statistics", "stream-disconnect", "stream-quit"]

    var body: some View {
        let count = Self.ids.count
        TimelineView(.animation(paused: !animating)) { timeline in
            let now = timeline.date
            let t = now.timeIntervalSince(openedAt) * 1000
            let exitT = closedAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
            ZStack(alignment: .topLeading) {
                backdrop(t: t, exitT: exitT)
                dock(t: t, exitT: exitT, count: count)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .disabled(!open)
        .onAppear { focus.focus(Self.resumeID) }
        .task {
            try? await Task.sleep(for: .milliseconds(Int(D.enterTotal(count: count)) + 50))
            if open { animating = false }
        }
        .onChange(of: open) { _, now in
            if now {
                closedAt = nil
            } else {
                closedAt = Date()
                animating = true
            }
        }
    }

    // MARK: Backdrop

    /// `#grad`: the soft ramp under the dock; a tap beside the tiles resumes.
    private func backdrop(t: Double, exitT: Double) -> some View {
        let alpha = open || closedAt == nil
            ? Motion.progress(t, delay: 0, duration: D.gradientIn, Motion.ease)
            : 1 - Motion.progress(exitT, delay: 0, duration: D.gradientOut, Motion.ease)
        let ink = RGBA(red: 4 / 255, green: 6 / 255, blue: 14 / 255)
        return LinearGradient(stops: [
            .init(color: ink.opacity(0).color, location: 0),
            .init(color: ink.opacity(0).color, location: 0.34),
            .init(color: ink.opacity(0.22).color, location: 0.48),
            .init(color: ink.opacity(0.55).color, location: 0.66),
            .init(color: ink.opacity(0.80).color, location: 0.84),
            .init(color: ink.opacity(0.90).color, location: 1),
        ], startPoint: .top, endPoint: .bottom)
            .opacity(alpha)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                layers?.feedback?.play(.back)
                controller.closeMenu()
            }
    }

    // MARK: Dock

    private func dock(t: Double, exitT: Double, count: Int) -> some View {
        let width = D.rowWidth(count: count)
        let top = min(stage.height - D.topFromBottom, stage.height - stage.safe.bottom / stage.scale - D.tile - D.labelGap - 70)
        let focusedIndex = Self.ids.firstIndex { focus.focused == AnyHashable($0) }
        let first = Self.ids.first!, last = Self.ids.last!
        return ZStack(alignment: .topLeading) {
            DockRing(index: focusedIndex ?? 0, t: t, exitT: exitT, count: count)
            ForEach(Self.ids.indices, id: \.self) { index in
                let id = Self.ids[index]
                FocusItem(
                    id: id, model: focus,
                    moves: index == 0 ? [.left: AnyHashable(last)] : index == count - 1 ? [.right: AnyHashable(first)] : [:],
                    clickCue: id == Self.resumeID ? .back : .select, action: { activate(id) }
                ) { focused in
                    DockTile(
                        spec: spec(id), focused: focused, index: index, count: count, t: t, exitT: exitT)
                }
                .offset(x: stage.px(D.tileLeft(index)))
            }
        }
        .frame(width: stage.px(width), height: stage.px(D.tile), alignment: .topLeading)
        .offset(x: (stage.px(stage.width) - stage.px(width)) / 2, y: stage.px(top))
    }

    private func activate(_ id: String) {
        switch id {
        case Self.resumeID: controller.closeMenu()
        case "stream-statistics": controller.toggleStatistics()
        case "stream-disconnect": Task { await controller.leave(quit: false) }
        default: Task { await controller.leave(quit: true) }
        }
    }

    private func spec(_ id: String) -> DockTile.Spec {
        switch id {
        case Self.resumeID:
            DockTile.Spec(icon: Symbols.resume, label: L("stream_menu_tile_resume"), on: nil)
        case "stream-statistics":
            DockTile.Spec(icon: Symbols.overlay, label: L("stream_menu_tile_overlay"), on: controller.statisticsEnabled)
        case "stream-disconnect":
            DockTile.Spec(icon: Symbols.logout, label: L("stream_menu_tile_disconnect"), on: nil)
        default:
            DockTile.Spec(icon: Symbols.powerSettingsNew, label: L("stream_menu_tile_quit"), on: nil)
        }
    }
}

/// One tile with its label: 150 px of glass, the icon, and for a toggle the On / Off pill. The focus lifts it to 1.12 with
/// the spring, lights its glass, fills its icon and turns the label gold and 8 px lower; a toggle that is on has accent
/// glass and an accent icon.
private struct DockTile: View {
    struct Spec {
        let icon: String
        let label: String
        /// A toggle's state; nil: not a toggle.
        let on: Bool?
    }

    let spec: Spec
    let focused: Bool
    let index: Int
    let count: Int
    let t: Double
    let exitT: Double
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @Environment(\.pressed) private var pressed

    private typealias D = StreamDockLayout

    var body: some View {
        let on = spec.on == true
        let p = Motion.progress(t, delay: D.tileDelay(index), duration: D.enter, Motion.easeSpring)
        let q = Motion.progress(exitT, delay: D.exitDelay(index, count: count), duration: D.leave, Motion.easeIn)
        let label = Motion.progress(t, delay: D.labelDelay(index), duration: D.labelDuration, Motion.ease)
        let entrance = reducedMotion ? 1 : Motion.lerp(Motion.lerp(0.8, 1, p), 0.92, q)
        let rise = reducedMotion ? 0 : 90 * (1 - p) + 46 * q
        let alpha = min(max(p, 0), 1) * (1 - q)
        let shape = RoundedRectangle(cornerRadius: stage.px(D.tileRadius), style: .continuous)
        ZStack {
            tile(shape: shape, on: on)
                .frame(width: stage.px(D.tile), height: stage.px(D.tile))
                .overlay {
                    ZStack(alignment: .topTrailing) {
                        SymbolView(symbol: spec.icon, size: D.icon, color: on ? colors.accent : colors.text, filled: focused)
                            .scaleEffect(focused ? D.iconFocusScale : 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if let on = spec.on {
                            pill(on: on)
                                .offset(x: -stage.px(D.pillRight), y: stage.px(D.pillTop))
                                .fixedSize()
                        }
                    }
                }
                .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: D.focusScale))
                .animation(.focusScale(pressed: pressed, reduced: reducedMotion), value: TilePress(focused: focused, pressed: pressed))
                .animation(Motion.spring(Motion.focus), value: focused)
                .scaleEffect(entrance)
                .offset(y: stage.px(rise))
                .opacity(alpha)
            Text(spec.label)
                .font(DelosFonts.figtree(stage.tpx(D.labelSize), .semibold))
                .foregroundStyle((focused ? colors.accent : colors.text2).color)
                .shadow(color: .black.opacity(0.6), radius: stage.px(6), y: stage.px(2))
                .lineLimit(1)
                .fixedSize()
                .offset(y: stage.px(D.tile / 2 + D.labelGap + 18 + (focused ? D.labelFocusShift : 0)))
                .animation(reducedMotion ? nil : Motion.spring(Motion.focus), value: focused)
                .animation(.easeOut(duration: Motion.fade / 1000), value: focused)
                .opacity(label * (1 - Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)))
        }
        .frame(width: stage.px(D.tile), height: stage.px(D.tile))
    }

    private func tile(shape: RoundedRectangle, on: Bool) -> some View {
        ZStack {
            shape.fill(RGBA(red: 5 / 255, green: 7 / 255, blue: 15 / 255).opacity(0.28).color)
            GlassShape(shape, tint: colors.surface2)
            // `--tile-fill-focus`, and the accent glass of a tile that is on
            shape.fill(LinearGradient(
                stops: [.init(color: .white.opacity(0.40), location: 0), .init(color: .white.opacity(0.16), location: 0.6),
                        .init(color: .white.opacity(0.22), location: 1)],
                startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                .opacity(focused ? 1 : 0)
            shape.fill(LinearGradient(
                stops: [.init(color: colors.accent.opacity(0.30).color, location: 0), .init(color: colors.accent.opacity(0.10).color, location: 0.6),
                        .init(color: .white.opacity(0.12), location: 1)],
                startPoint: UnitPoint(x: 0.2, y: 0), endPoint: UnitPoint(x: 0.8, y: 1)))
                .opacity(on ? 1 : 0)
        }
        .animation(.easeOut(duration: Motion.fade / 1000), value: focused)
        .animation(.easeOut(duration: Motion.fade / 1000), value: on)
        // 0 18 40 −14 black at rest; focused 0 26 56 −14 and the accent glow
        .shadow(color: .black.opacity(focused ? 0.6 : 0.55), radius: stage.px(focused ? 28 : 20), y: stage.px(focused ? 26 : 18))
        .shadow(color: focused ? colors.accent.opacity(0.22).color : .clear, radius: stage.px(30))
        .animation(Motion.out(Motion.focus), value: focused)
    }

    private func pill(on: Bool) -> some View {
        Text(on ? L("common_on") : L("common_off"))
            .font(DelosFonts.figtree(stage.tpx(D.pillSize), .bold))
            .tracking(stage.tpx(D.pillSize) * 0.02)
            .foregroundStyle((on ? colors.onAccent : colors.text2).color)
            .lineLimit(1)
            .padding(.horizontal, stage.px(D.pillPaddingX))
            .frame(height: stage.px(D.pillHeight))
            .background {
                Capsule()
                    .fill(on ? colors.accent.color : RGBA(red: 22 / 255, green: 28 / 255, blue: 48 / 255, alpha: 0.78).color)
                    .shadow(color: on ? colors.glow.color : .black.opacity(0.55), radius: stage.px(10), y: stage.px(8))
            }
            // A new text pops in from 0.6
            .id(on)
            .transition(reducedMotion ? .identity : .scale(scale: Motion.popFromPill))
            .animation(reducedMotion ? nil : Motion.spring(Motion.pillPop), value: on)
    }
}

private struct TilePress: Equatable {
    let focused: Bool
    let pressed: Bool
}

/// The dock's one ring: a gold 186 box that glides to the focused tile (560 ms, overshooting) and breathes (2.6 s),
/// behind the tiles. It arrives after the first tile, from a 0.7 scale; reduced motion: it jumps and does not breathe.
private struct DockRing: View {
    let index: Int
    let t: Double
    let exitT: Double
    let count: Int
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion

    private typealias D = StreamDockLayout
    private static let breathing = CubicBezier(0.42, 0, 0.58, 1)

    var body: some View {
        let p = Motion.progress(t, delay: D.ringDelay(0), duration: D.enter, Motion.easeSpring)
        let leaving = Motion.progress(exitT, delay: 0, duration: D.leave, Motion.ease)
        TimelineView(.animation(paused: reducedMotion)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate * 1000).truncatingRemainder(dividingBy: D.breathe) / D.breathe
            let b = reducedMotion ? 0 : Self.breathing(phase < 0.5 ? phase * 2 : 2 - phase * 2)
            ring(breath: b)
        }
        .scaleEffect(reducedMotion ? 1 : Motion.lerp(0.7, 1, p))
        .opacity(min(max(p, 0), 1) * (1 - leaving))
        .frame(width: stage.px(D.ring), height: stage.px(D.ring))
        .offset(x: stage.px(D.ringLeft(index)), y: stage.px((D.tile - D.ring) / 2))
        .animation(reducedMotion ? nil : .timingCurve(0.3, 1.22, 0.42, 1, duration: D.ringGlide / 1000), value: index)
        .allowsHitTesting(false)
    }

    private func ring(breath b: Double) -> some View {
        let shape = RoundedRectangle(cornerRadius: stage.px(D.ringRadius), style: .continuous)
        return shape.strokeBorder(colors.accent.color, lineWidth: stage.px(D.ringWidth))
            .overlay {
                // inset 0 0 30px −4px, breathing to 36px −2px
                shape.inset(by: stage.px(D.ringWidth)).stroke(colors.accent.opacity(0.22).color, lineWidth: stage.px(Motion.lerp(14, 18, b)))
                    .blur(radius: stage.px(Motion.lerp(12, 15, b)))
                    .clipShape(shape.inset(by: stage.px(D.ringWidth)))
            }
            // 0 0 44px 4px glow, breathing to 62px 8px
            .background {
                shape.fill(colors.glow.opacity(Motion.lerp(1.0, 1.0, b)).color)
                    .blur(radius: stage.px(Motion.lerp(22, 31, b)))
                    .opacity(Motion.lerp(0.55, 0.7, b))
            }
    }
}
