import DelosData
import SwiftUI

/// The backdrop of the root: the game background shows only behind the library (`ShellBackdrop`'s heroShown). It reads the
/// focused game's background itself, so a new one (140 ms after every step of the library's focus) redraws the backdrop
/// alone, not the root and every screen and bar under it while the row of covers is still moving.
struct ShellBackdrop: View {
    let appearance: Appearance
    let showsLibrary: Bool
    @Environment(HomeArt.self) private var art

    var body: some View {
        Backdrop(appearance: appearance, hero: showsLibrary ? art.hero : nil)
    }
}

/// The layered background behind every screen, as `Backdrop` in DELOS for Android (`shell/ui/Backdrop.kt`): the theme
/// color, the focused game's background ("hero", blurred, at the game background's opacity, faded into the theme color
/// at the bottom and on the left), and the animated background of `appearance.background` drawn on a 960 × 540 canvas
/// that keeps its proportions and grows along the axis with more room. In the dark theme the animated background is
/// blended with "screen", so it lights the game background up instead of covering it; over a game background its base
/// gradient fades to 12 %, and with "Match the app's colors" it takes on the game's three colors.
struct Backdrop: View {
    let appearance: Appearance
    /// The game background to show (the library's focused game), nil elsewhere.
    var hero: GameArt?
    @Environment(\.delosColors) private var colors
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(HomeArt.self) private var art
    @State private var start = Date.now
    @State private var tints = BackdropTintClock()

    var body: some View {
        let heroOn = appearance.heroBackground && hero != nil && appearance.heroOpacity > 0
        let matching = heroOn && appearance.matchGameColors && !colors.materialYou
        let gameColors = matching ? hero.flatMap { art.gameColors($0.id) } : nil
        // A game whose colors are not worked out yet keeps the previous game's, so nothing flashes in between
        let pending = matching && !(hero.map { art.colorsKnown($0.id) } ?? true)
        // The game background is larger than the screen (the tilt swings its margin into view): overlays, so it never
        // makes the backdrop, and the screens over it, larger than the window
        colors.bg.color
            .overlay {
                HeroLayer(art: heroOn ? hero : nil, blur: appearance.heroBlur, reduced: appearance.reducedMotion || systemReduceMotion)
                    .opacity(heroOn ? Double(appearance.heroOpacity) / 100 : 0)
                    .animation(Motion.fastOutSlowIn(800), value: heroOn)
            }
            .overlay {
                HeroFade(bg: colors.bg)
                    .opacity(heroOn ? 1 : 0)
                    .animation(Motion.fastOutSlowIn(800), value: heroOn)
            }
            .overlay { animated(gameColors: gameColors, pending: pending, heroActive: heroOn) }
            .clipped()
            .ignoresSafeArea()
    }

    private func animated(gameColors: GameColors?, pending: Bool, heroActive: Bool) -> some View {
        let kind = appearance.background
        // Under a game background the animated one is a faint light: it repaints at 30 Hz at most
        return TimelineView(.animation(minimumInterval: heroActive ? 1.0 / 30 : 1.0 / 60, paused: kind == .still && !heroActive)) { context in
            // The prototype advances its clock by 0.016 per 60 Hz frame (0.96 per second); reduced motion slows it down
            let t = context.date.timeIntervalSince(start) * 0.96 * (systemReduceMotion ? 0.15 : 1)
            let state = tints.advance(to: context.date, target: gameColors, baseTarget: heroActive ? 0.12 : 1)
            GeometryReader { proxy in
                let (unit, canvas) = BackgroundParams.canvas(for: proxy.size)
                let game = (gameColors != nil || pending) ? state.game : nil
                let p = game.map { BackgroundParams(colors: colors, canvas: canvas, t: t, game: $0) }
                    ?? BackgroundParams(colors: colors, canvas: canvas, t: t)
                layer(p, kind: kind, unit: unit, size: proxy.size, baseAlpha: state.baseAlpha)
                    .compositingGroup()
                    .blendMode(colors.dark ? .screen : .normal)
            }
        }
    }

    @ViewBuilder
    private func layer(_ p: BackgroundParams, kind: BackgroundKind, unit: Double, size: CGSize, baseAlpha: Double) -> some View {
        switch BackgroundStyle(kind) {
        case .still:
            base(p).opacity(baseAlpha)
        case .canvas:
            Canvas { context, _ in
                context.scaleBy(x: unit, y: unit)
                context.opacity = baseAlpha
                context.fill(Path(CGRect(x: 0, y: 0, width: p.w, height: p.h)), with: .linearGradient(
                    Gradient(colors: baseColors(p)), startPoint: .zero, endPoint: CGPoint(x: 0, y: p.h)
                ))
                context.opacity = 1
                CanvasBackgrounds.draw(kind, in: &context, p)
            }
        case .contour:
            ZStack {
                base(p).opacity(baseAlpha)
                contour(p, unit: unit, size: size)
            }
        case let .shader(name):
            let (c1, c2, c3) = p.lights
            ZStack {
                base(p).opacity(baseAlpha)
                Rectangle()
                    .colorEffect(
                        ShaderLibrary.bundle(.module)[dynamicMember: name](
                            .float(unit), .float2(p.w, p.h), .float(p.t),
                            .color(c1.color), .color(c2.color), .color(c3.color), .float(p.glow)
                        )
                    )
                    .blendMode(p.dark ? .plusLighter : .normal)
            }
        }
    }

    private func baseColors(_ p: BackgroundParams) -> [Color] {
        p.dark
            ? [hsl(p.base, 40, 8).color, hsl(p.base, 38, 5).color]
            : [hsl(p.base, 45, 96).color, hsl(p.base, 38, 90).color]
    }

    private func base(_ p: BackgroundParams) -> some View {
        LinearGradient(colors: baseColors(p), startPoint: .top, endPoint: .bottom)
    }

    private func contour(_ p: BackgroundParams, unit: Double, size: CGSize) -> some View {
        let dark = p.dark
        let lightness = dark ? 68.0 : 40.0
        // The lowest level in the main color, the highest in the secondary one
        let c1 = hsl(p.acc, 80 * p.s(p.acc), lightness)
        let c2 = hsl(p.tint, 80 * p.s(p.tint), lightness)
        let blend: BlendMode = dark ? .plusLighter : .normal
        return ZStack {
            // The glow under the lines
            RadialGradient(
                colors: [hsl(p.acc, 80 * p.sat1, dark ? 50 : 70, dark ? 0.14 : 0.2).color, hsl(p.acc, 80, 50, 0).color],
                center: UnitPoint(x: 0.66, y: 0.5), startRadius: 0, endRadius: size.width * 0.55
            )
            .blendMode(blend)
            Rectangle()
                .colorEffect(
                    ShaderLibrary.bundle(.module).delosContour(
                        .float(unit), .float2(p.w, p.h), .float(p.t),
                        .color(c1.color), .color(c2.color), .float(dark ? 1 : 0)
                    )
                )
                .blendMode(blend)
        }
    }
}

/// The smoothed values of the animated background (`BackgroundClock` of DELOS for Android): the focused game's three
/// colors as they follow it, and the base gradient's opacity. Pure, so the tests can step it.
struct BackdropTints: Equatable {
    struct Game: Equatable {
        var hues: [Double]
        var saturations: [Double]
    }

    /// Nil until a game's colors were first seen.
    var game: Game?
    /// Nil until the first step.
    var baseAlpha: Double?

    /// Per-frame smoothing factor [k] (the prototype's per-frame lerps at 60 fps) for [dt] seconds.
    static func smoothing(_ k: Double, _ dt: Double) -> Double { 1 - pow(1 - k, dt * 60) }

    /// One step of [dt] seconds toward [target] (nil: the colors stay where they are) and the base opacity [baseTarget].
    mutating func advance(dt: Double, target: GameColors?, baseTarget: Double) {
        if let target, target.hues.count >= 3, target.saturations.count >= 3 {
            if var game {
                let k = Self.smoothing(0.04, dt)
                for i in 0..<3 {
                    game.hues[i] = lerpHue(game.hues[i], target.hues[i], k)
                    game.saturations[i] += (target.saturations[i] - game.saturations[i]) * k
                }
                self.game = game
            } else {
                // The first game's colors are taken at once; its saturations rise from the palette's
                game = Game(hues: Array(target.hues.prefix(3)), saturations: [1, 1, 1])
                advance(dt: dt, target: target, baseTarget: baseTarget)
                return
            }
        }
        baseAlpha = baseAlpha.map { $0 + (baseTarget - $0) * Self.smoothing(0.05, dt) } ?? baseTarget
    }
}

/// Holds ``BackdropTints`` across the frames of the timeline, outside SwiftUI's state (it changes on every frame).
@MainActor
final class BackdropTintClock {
    private var tints = BackdropTints()
    private var last: Date?

    func advance(to date: Date, target: GameColors?, baseTarget: Double) -> (game: BackdropTints.Game?, baseAlpha: Double) {
        let dt = last.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        last = date
        tints.advance(dt: dt, target: target, baseTarget: baseTarget)
        return (tints.game, tints.baseAlpha ?? baseTarget)
    }
}

/// The game background fades into the theme color at the bottom (from 42 % of the height) and on the left (to 38 % of
/// the width), at 90 %, behind the texts.
private struct HeroFade: View {
    let bg: RGBA

    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: bg.opacity(0).color, location: 0.42), .init(color: bg.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            LinearGradient(stops: [.init(color: bg.color, location: 0), .init(color: bg.opacity(0).color, location: 0.38)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .compositingGroup()
        .opacity(0.9)
        .allowsHitTesting(false)
    }
}

/// The game background with Android's 900 ms cross-fade from one game to the next.
private struct HeroLayer: View {
    let art: GameArt?
    let blur: Int
    let reduced: Bool

    var body: some View {
        ZStack {
            if let art {
                HeroArt(art: art, blur: blur, reduced: reduced)
                    .id(art.id + (art.image.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"))
                    .transition(.opacity)
            }
        }
        .animation(Motion.fastOutSlowIn(900), value: art)
    }
}

/// One game's background (`HeroArt`, the still path): the rendered picture over the hero area, centred on the screen
/// and tilted by the slow orbit; a game without an image shows its placeholder art, unblurred and still. Animated heroes
/// are not played.
private struct HeroArt: View {
    let art: GameArt
    let blur: Int
    let reduced: Bool
    @Environment(HomeArt.self) private var homeArt
    @Environment(\.stage) private var stage
    @State private var rendered: CGImage?

    var body: some View {
        let area = HeroArea.of(stageWidth: stage.width, stageHeight: stage.height)
        Color.clear
            .overlay {
                if art.image != nil {
                    if let image = rendered ?? homeArt.cachedBackground(art, blur: blur, area: area) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: stage.px(area.width), height: stage.px(area.height))
                            .modifier(HeroTilt(reduced: reduced))
                    }
                } else {
                    PlaceholderArt(hue: art.hue, hue2: art.hue2, icon: art.icon, glyphSize: 1050, glyphRight: 84, glyphTop: -0.14, glyphAlpha: 0.14)
                        .frame(width: stage.px(area.width), height: stage.px(area.height))
                }
            }
            // The placeholder fades out diagonally over the screen (the rendered picture has the fade in it)
            .mask {
                if art.image == nil {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.3), .init(color: .clear, location: 0.95)],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                } else {
                    Color.black
                }
            }
            .clipped()
            .task(id: "\(blur)/\(area.width)x\(area.height)") {
                rendered = await homeArt.background(art, blur: blur, area: area)
            }
    }
}

/// The very slow tilt of the game background (`heroTilt`): the plane's normal orbits 15° around the centre once in
/// 25 s, seen through a camera 2.2 times the plane's longer side away, scaled by ``HeroMotion/overscan`` so the area
/// covers the screen at every phase. The phase is a function of the clock, so a new game's background is in the same
/// pose. Off with reduced motion.
private struct HeroTilt: ViewModifier {
    let reduced: Bool

    func body(content: Content) -> some View {
        if reduced {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                content.modifier(HeroTiltEffect(turn: HeroMotion.turn(at: context.date.timeIntervalSinceReferenceDate)))
            }
        }
    }
}

private struct HeroTiltEffect: GeometryEffect {
    var turn: Double

    var animatableData: Double {
        get { turn }
        set { turn = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let pitch = HeroMotion.pitch(turn, reduced: false) * .pi / 180
        let yaw = HeroMotion.yaw(turn, reduced: false) * .pi / 180
        let camera = max(size.width, size.height) * HeroMotion.cameraDistanceFactor
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / camera
        var t = CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0)
        t = CATransform3DConcat(t, CATransform3DMakeScale(HeroMotion.overscan, HeroMotion.overscan, 1))
        t = CATransform3DConcat(t, CATransform3DMakeRotation(yaw, 0, 1, 0))
        t = CATransform3DConcat(t, CATransform3DMakeRotation(pitch, 1, 0, 0))
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        return ProjectionTransform(t)
    }
}
