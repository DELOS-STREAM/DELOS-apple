import SwiftUI

/// The DELOS mark: a ring in the main color with a small moon in the secondary color at its top right
/// (`LogoMark` in DELOS for Android). [size] in stage pixels.
struct LogoMark: View {
    var size: Double = 40
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let k = stage.px(size) / 40
        // The moon's center sits on the ring's top right and reaches past the mark's box: drawn as views, not in a
        // Canvas, so nothing clips it (in a Canvas half of the moon was cut off)
        let moon = CGPoint(x: stage.px(size) - 1.5 * k, y: 7.5 * k)
        Circle()
            .strokeBorder(colors.accent.color, lineWidth: 3 * k)
            .frame(width: stage.px(size), height: stage.px(size))
            .overlay(alignment: .topLeading) {
                ZStack {
                    Circle().fill(colors.accent2.opacity(0.35).color).frame(width: 18 * k, height: 18 * k)
                    Circle().fill(colors.accent2.color).frame(width: 11 * k, height: 11 * k)
                }
                .position(moon)
            }
    }
}

/// The mark and the wordmark at the top left of the status bar.
struct Brand: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(18)) {
            LogoMark()
            Wordmark()
        }
    }
}

/// "DELOS" beside the mark.
struct Wordmark: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Text(verbatim: "DELOS")
            .font(DelosFonts.unbounded(stage.tpx(26)))
            .tracking(stage.tpx(26) * 0.14)
            .foregroundStyle(colors.text.color)
    }
}

/// A headline with an optional line under it (`.h1` and `.sub` of the prototype).
struct Heading: View {
    let title: String
    var sub: String?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(14)) {
            Text(title)
                .font(DelosFonts.unbounded(stage.tpx(stage.compact ? 48 : 64)))
                .tracking(-stage.tpx(stage.compact ? 48 : 64) * 0.01)
                .foregroundStyle(colors.text.color)
            if let sub {
                Text(sub)
                    .font(DelosFonts.figtree(stage.tpx(26)))
                    .foregroundStyle(colors.text2.color)
                    .lineSpacing(stage.tpx(26 * 0.4))
                    .frame(maxWidth: stage.px(stage.compact ? stage.width - 144 : 1000))
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// A round item with an icon, a label and a status line (`CircleItem` in DELOS for Android): 220 stage pixels wide
/// when [big], 176 otherwise, or [diameter]; [width] is a fixed width of the item (a grid's cell), else 220. The focused
/// circle grows by 16 %, gets a ring in the main color 5 px outside it and a glow. [avatar] fills the circle with the
/// avatar's colors and illustration; [selected] adds the check badge on its edge and lights the label like the focus.
struct CircleItem: View {
    let icon: String
    let label: String
    var meta: String?
    /// A dot before the status line (an online PC's green).
    var metaDot: RGBA?
    var big = true
    var avatar: Avatar?
    var selected = false
    var diameter: Double?
    var width: Double?
    /// The gap between the circle and its label, stage pixels (a compact stage's: the focused ring's reach and more).
    var labelGap: Double?
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    @Environment(\.pressed) private var pressed
    @Environment(\.glideRing) private var glide

    var body: some View {
        let side = diameter ?? (big ? 220.0 : 176.0)
        let iconSize = big ? 96.0 : 76.0
        let lit = focused || selected
        VStack(spacing: stage.px(labelGap ?? (side < 176 ? 14 : 22))) {
            ZStack {
                if let avatar {
                    AvatarBadge(avatar: avatar, size: side, iconSize: iconSize)
                } else {
                    GlassShape(Circle(), tint: colors.surface2)
                        .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                    SymbolView(symbol: icon, size: iconSize, color: colors.text, filled: focused)
                }
            }
            .frame(width: stage.px(side), height: stage.px(side))
            // One ring glides between the circles of a row (`GlideRingHost`); a lone circle draws its own
            .glideTarget(focused: focused)
            .background {
                if glide == nil {
                    // Ring: 5 px wide, 5 px outside the circle, the gap in the background color
                    ZStack {
                        Circle().strokeBorder(colors.bg.color, lineWidth: stage.px(5)).padding(-stage.px(5))
                        Circle().strokeBorder(colors.accent.color, lineWidth: stage.px(5)).padding(-stage.px(10))
                    }
                    .opacity(focused ? 1 : 0)
                }
            }
            // The glow of a round element, `FocusGlow(26, 70, -16)`: centered on the circle, not moved down
            .background {
                GlowDisc(radius: stage.px(side / 2), spread: -stage.px(16), blur: stage.px(70), color: colors.glow)
                    .opacity(focused ? 1 : 0)
            }
            .animation(.focusRing(focused: focused), value: focused)
            .overlay(alignment: .topLeading) { if selected { checkBadge(side: side) } }
            .scaleEffect(focusScale(focused: focused, pressed: pressed, focus: 1.16))
            .zIndex(focused ? 1 : 0)
            VStack(spacing: stage.px(8)) {
                Text(label)
                    .font(DelosFonts.figtree(stage.tpx(26), .semibold))
                    .foregroundStyle(colors.text.color)
                    .opacity(lit ? 1 : 0.55)
                    .offset(y: lit ? 0 : -stage.px(6))
                    // `lit`: 420 ms ease-out, not the focus spring
                    .animation(reduceMotion ? nil : Motion.out(Motion.focus), value: lit)
                    .lineLimit(1)
                if let meta {
                    HStack(spacing: stage.px(8)) {
                        if let metaDot { Circle().fill(metaDot.color).frame(width: stage.px(12), height: stage.px(12)) }
                        Text(meta)
                            .font(DelosFonts.figtree(stage.tpx(20)))
                            .foregroundStyle(colors.text3.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(width: stage.px(max(width ?? 220, side)))
        .animation(.focusScale(pressed: pressed, reduced: reduceMotion), value: CirclePress(focused: focused, pressed: pressed))
        .animation(reduceMotion ? .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000) : Motion.spring(Motion.pillPop), value: selected)
    }

    /// `.circle::before`: a 52 px circle in the secondary color with a check, centered on the circle's edge at the top
    /// right (45°), above the focus ring. It pops in when the circle becomes the selected one.
    private func checkBadge(side: Double) -> some View {
        let edge = side / 2 * (1 - 0.70710677)
        let badge = 52.0
        return ZStack {
            Circle().fill(colors.accent2.color)
            SymbolView(symbol: Symbols.check, size: 26, color: colors.onAccent)
        }
        .frame(width: stage.px(badge), height: stage.px(badge))
        .offset(x: stage.px(side - edge - badge / 2), y: stage.px(edge - badge / 2))
        .transition(reduceMotion ? .opacity : .scale(scale: Motion.popFromPill).combined(with: .opacity))
    }
}

private struct CirclePress: Equatable {
    let focused: Bool
    let pressed: Bool
}

/// The value of a choice between its two chevrons (`valueSlide` and `chevronBump` of DELOS for Android): when the
/// selection steps to [index] the new value fades in sliding ``Motion/valueSlideDistance`` stage pixels from the side the
/// step came from (300 ms), and the chevron that was pressed nudges ``Motion/chevronBumpDistance`` toward it (320 ms).
/// The direction is the sign of the step; a step from the last to the first of [count] (or back) is the wrap and counts
/// the other way. Reduced motion: the value only fades, nothing moves.
struct ChoiceValue<Value: View>: View {
    let index: Int
    let count: Int
    let arrows: RGBA
    @ViewBuilder let value: () -> Value
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion
    /// The step count triggers the animations; the direction of the last one is read while they run.
    @State private var steps = 0
    @State private var direction = 0

    /// -1 / 1 for a step of the selection from [old] to [new] among [count] values (the wrap is a step of one); 0: none.
    static func direction(from old: Int, to new: Int, count: Int) -> Int {
        guard old != new else { return 0 }
        if count > 2, abs(new - old) == count - 1 { return new < old ? 1 : -1 }
        return new > old ? 1 : -1
    }

    var body: some View {
        // Read here: the animators' closures are not on the main actor
        let slide = reduceMotion ? 0 : Double(direction) * stage.px(Motion.valueSlideDistance)
        HStack(spacing: stage.px(12)) {
            chevron(Symbols.chevronLeft, side: -1)
            value().modifier(ValueSlide(steps: steps, slide: slide))
            chevron(Symbols.chevronRight, side: 1)
                .offset(x: stage.px(9))
        }
        .onChange(of: index) { old, new in
            direction = Self.direction(from: old, to: new, count: count)
            steps += 1
        }
    }

    private func chevron(_ symbol: String, side: Int) -> some View {
        let nudge = reduceMotion || direction != side ? 0 : Double(side) * stage.px(Motion.chevronBumpDistance)
        return SymbolView(symbol: symbol, size: 30, color: arrows).modifier(ChevronBump(steps: steps, nudge: nudge))
    }
}

/// The new value fades in over ``Motion/valueSlide`` ms, from [slide] points to the side it came from.
private struct ValueSlide: ViewModifier {
    let steps: Int
    let slide: Double

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: steps) { view, progress in
            view.opacity(progress).offset(x: slide * (1 - progress))
        } keyframes: { _ in
            KeyframeTrack { CubicKeyframe(0, duration: 0.001); CubicKeyframe(1, duration: Motion.valueSlide / 1000, startVelocity: 7) }
        }
    }
}

/// The chevron nudges [nudge] points and back in ``Motion/chevronBump`` ms (40 % out, 60 % back).
private struct ChevronBump: ViewModifier {
    let steps: Int
    let nudge: Double

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: steps) { view, bump in
            view.offset(x: nudge * bump)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(1, duration: Motion.chevronBump * 0.4 / 1000)
                CubicKeyframe(0, duration: Motion.chevronBump * 0.6 / 1000)
            }
        }
    }
}
