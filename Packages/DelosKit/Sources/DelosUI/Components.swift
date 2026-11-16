import SwiftUI

/// The DELOS mark: a ring in the main color with a small moon in the secondary color at its top right
/// (`LogoMark` in DELOS for Android). [size] in stage pixels.
struct LogoMark: View {
    var size: Double = 40
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / size
            let stroke = 3 * k
            let ring = CGRect(origin: .zero, size: canvas).insetBy(dx: stroke / 2, dy: stroke / 2)
            context.stroke(Path(ellipseIn: ring), with: .color(colors.accent.color), lineWidth: stroke)
            let moon = CGPoint(x: canvas.width - 1.5 * k, y: 7.5 * k)
            context.fill(Path(ellipseIn: CGRect(x: moon.x - 9 * k, y: moon.y - 9 * k, width: 18 * k, height: 18 * k)), with: .color(colors.accent2.opacity(0.35).color))
            context.fill(Path(ellipseIn: CGRect(x: moon.x - 5.5 * k, y: moon.y - 5.5 * k, width: 11 * k, height: 11 * k)), with: .color(colors.accent2.color))
        }
        .frame(width: stage.px(size), height: stage.px(size))
    }
}

/// The mark and the wordmark at the top left of the status bar.
struct Brand: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(18)) {
            LogoMark()
            Text("DELOS")
                .font(DelosFonts.unbounded(stage.px(26)))
                .tracking(stage.px(26) * 0.14)
                .foregroundStyle(colors.text.color)
        }
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
                .font(DelosFonts.unbounded(stage.px(64)))
                .tracking(-stage.px(64) * 0.01)
                .foregroundStyle(colors.text.color)
            if let sub {
                Text(sub)
                    .font(DelosFonts.figtree(stage.px(26)))
                    .foregroundStyle(colors.text2.color)
                    .frame(maxWidth: stage.px(1000))
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
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let side = diameter ?? (big ? 220.0 : 176.0)
        let iconSize = big ? 96.0 : 76.0
        let lit = focused || selected
        VStack(spacing: stage.px(side < 176 ? 14 : 22)) {
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
            .background {
                // Ring: 5 px wide, 5 px outside the circle
                Circle()
                    .strokeBorder(colors.accent.color, lineWidth: stage.px(5))
                    .padding(-stage.px(10))
                    .opacity(focused ? 1 : 0)
            }
            .shadow(color: focused ? colors.glow.color : .clear, radius: stage.px(35), y: stage.px(26))
            .overlay(alignment: .topLeading) { if selected { checkBadge(side: side) } }
            .scaleEffect(focused ? 1.16 : 1)
            .zIndex(focused ? 1 : 0)
            VStack(spacing: stage.px(8)) {
                Text(label)
                    .font(DelosFonts.figtree(stage.px(26), .semibold))
                    .foregroundStyle(colors.text.color)
                    .opacity(lit ? 1 : 0.55)
                    .offset(y: lit ? 0 : -stage.px(6))
                    .lineLimit(1)
                if let meta {
                    HStack(spacing: stage.px(8)) {
                        if let metaDot { Circle().fill(metaDot.color).frame(width: stage.px(12), height: stage.px(12)) }
                        Text(meta)
                            .font(DelosFonts.figtree(stage.px(20)))
                            .foregroundStyle(colors.text3.color)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(width: stage.px(max(width ?? 220, side)))
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.68), value: focused)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.36, dampingFraction: 0.6), value: selected)
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
        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
    }
}
