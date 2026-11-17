import DelosData
import SwiftUI

/// The first screen of the first run (`#scr-boot`, `BootScreen` in DELOS for Android): the logo, the wordmark, the
/// tagline and "Get started". [onSkip] ("Skip to home") exists only when PCs are paired already.
struct BootScreen: View {
    let focus: FocusModel
    let onBegin: @MainActor () -> Void
    var onSkip: (@MainActor () -> Void)?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(28)) {
            BootLogo()
                .padding(.bottom, stage.px(8))
            // The leading padding balances the letter spacing after the last letter
            Text(verbatim: "DELOS")
                .font(DelosFonts.unbounded(stage.tpx(stage.compact ? 96 : 132)))
                .tracking(stage.tpx(stage.compact ? 96 : 132) * 0.24)
                .foregroundStyle(colors.text.color)
                .padding(.leading, stage.px(stage.compact ? 22 : 30))
            Text(L("firstrun_boot_tagline"))
                .font(DelosFonts.figtree(stage.tpx(28)))
                .foregroundStyle(colors.text2.color)
                .multilineTextAlignment(.center)
            HStack(spacing: stage.px(24)) {
                FocusItem(id: "begin", model: focus, action: onBegin) { focused in
                    PillButton(label: L("firstrun_boot_begin"), icon: Symbols.arrowForward, primary: true, focused: focused)
                }
                if let onSkip {
                    FocusItem(id: "skip", model: focus, action: onSkip) { focused in
                        PillButton(label: L("firstrun_boot_skip"), icon: Symbols.fastForward, focused: focused)
                    }
                }
            }
            .padding(.top, stage.px(26))
        }
    }
}

/// `.boot-logo`: the DELOS ring (210 px) with its glow, the island inside and the moon circling it, 7 s a turn. The glow
/// and the moon reach beyond the 210 px the logo takes in the layout.
struct BootLogo: View {
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    /// The drawing's square: the moon's orbit (132 px from the center) plus its 44 px glow on each side.
    private static let canvas = 360.0

    var body: some View {
        Color.clear
            .frame(width: stage.px(210), height: stage.px(210))
            .overlay {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 7) / 7 * 2 * Double.pi
                    Canvas { g, size in draw(&g, size: size, turn: turn) }
                }
                .frame(width: stage.px(Self.canvas), height: stage.px(Self.canvas))
                .allowsHitTesting(false)
            }
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, turn: Double) {
        let k = size.width / Self.canvas
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func disc(_ center: CGPoint, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        }
        // The glow around the ring
        let glow = 160 * k
        g.fill(disc(c, glow), with: .radialGradient(
            Gradient(stops: [
                .init(color: colors.glow.color, location: 0),
                .init(color: colors.glow.opacity(colors.glow.alpha * 0.4).color, location: 0.66),
                .init(color: colors.glow.opacity(0).color, location: 1),
            ]),
            center: c, startRadius: 0, endRadius: glow
        ))
        g.stroke(disc(c, 101 * k), with: .color(colors.accent.color), lineWidth: 8 * k)
        // radial-gradient(circle at 35% 30%, text, accent-3): the third color tints the island's shadow side
        let isle = 37 * k
        let light = CGPoint(x: c.x - isle * 0.3, y: c.y - isle * 0.4)
        g.drawLayer { layer in
            layer.opacity = 0.92
            layer.fill(disc(c, isle), with: .radialGradient(
                Gradient(colors: [colors.text.color, colors.accent3.color]),
                center: light, startRadius: 0, endRadius: isle * 1.6
            ))
        }
        // The moon starts at the orbit's top right and turns clockwise around the center
        let (x, y) = (87 * k, -99 * k)
        let moon = CGPoint(x: c.x + x * cos(turn) - y * sin(turn), y: c.y + x * sin(turn) + y * cos(turn))
        g.fill(disc(moon, 44 * k), with: .radialGradient(
            Gradient(colors: [colors.accent2.opacity(0.6).color, colors.accent2.opacity(0).color]),
            center: moon, startRadius: 0, endRadius: 44 * k
        ))
        g.fill(disc(moon, 14 * k), with: .color(colors.accent2.color))
    }
}

/// `#scr-create` (`CreateProfileScreen` in DELOS for Android): the sixteen avatars in circles, the name and Create.
/// [editing] changes the current profile ([initial]) instead of creating one.
///
/// The name is shown in a pill that is not an input; "Change name" opens the profile name dialog (the one Rename profile
/// uses), and when it is accepted the focus goes on to Create. Create without a name opens the dialog too.
struct CreateProfileScreen: View {
    let editing: Bool
    let focus: FocusModel
    let actions: ShellActions
    let onDone: (_ name: String, _ avatar: Int) -> Void
    @State private var avatar: Int
    @State private var name: String
    @Environment(\.stage) private var stage

    init(
        editing: Bool, initial: Profile?, focus: FocusModel, actions: ShellActions,
        onDone: @escaping (_ name: String, _ avatar: Int) -> Void
    ) {
        self.editing = editing
        self.focus = focus
        self.actions = actions
        self.onDone = onDone
        _avatar = State(initialValue: Avatar.of(initial?.avatar ?? 0).index)
        _name = State(initialValue: initial?.name ?? L("firstrun_create_default_name"))
    }

    /// The focus id of an avatar's circle.
    static func avatarID(_ index: Int) -> AnyHashable { AnyHashable("avatar-\(index)") }

    /// The focus id of "Change name".
    static let changeNameID = "change-name"

    /// Eight columns: 144 px circles in 184 px cells, 32 px apart (1696 px); a compact stage takes four, and fewer where
    /// the stage is narrower than that (a window or a phone in portrait).
    private var columns: Int { AvatarGridLayout.columns(stage) }

    var body: some View {
        CenterColumn(gap: 40) {
            Heading(
                title: editing ? L("firstrun_create_edit_title") : L("firstrun_create_new_title"),
                sub: editing ? L("firstrun_create_edit_note") : L("firstrun_create_new_note")
            )
            .staggerEntrance()
            avatarGrid
            HStack(spacing: stage.px(stage.compact ? 44 : 24)) {
                ValuePill(
                    label: L("firstrun_create_name_label"), value: name, icon: Symbols.badge,
                    placeholder: L("firstrun_create_name_placeholder"))
                FocusItem(id: Self.changeNameID, model: focus, action: askName) { focused in
                    PillButton(label: L("firstrun_create_change_name"), icon: Symbols.edit, focused: focused)
                }
            }
            .tvFocusSection()
            FocusItem(id: "create", model: focus, action: submit) { focused in
                PillButton(
                    label: editing ? L("firstrun_create_save") : L("firstrun_create_create"),
                    icon: Symbols.check, primary: true, focused: focused
                )
            }
            .tvFocusSection()
        }
    }

    /// All avatars in rows. Up and down move to the same column; left at the start of a row and right at its end
    /// continue in the previous and the next row, and wrap from the last avatar to the first.
    private var avatarGrid: some View {
        let all = Avatar.all
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        let k = stage.compactScale
        return VStack(spacing: stage.px(stage.compact ? AvatarGridLayout.rowGap(144 * k) : 26)) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: stage.px(AvatarGridLayout.columnGap(stage))) {
                    ForEach(rows[row]) { a in
                        FocusItem(id: Self.avatarID(a.index), model: focus, moves: wrap(a.index), action: { pick(a.index) }) { focused in
                            CircleItem(
                                icon: a.icon, label: a.label, avatar: a, selected: a.index == avatar,
                                diameter: 144 * k, width: 184 * k, labelGap: stage.compact ? AvatarGridLayout.labelGap(144 * k) : nil,
                                focused: focused
                            )
                        }
                        .staggerEntrance()
                    }
                }
            }
        }
    }

    private func wrap(_ i: Int) -> [FocusDirection: AnyHashable] {
        let n = Avatar.all.count
        var moves: [FocusDirection: AnyHashable] = [:]
        if i % columns == 0 { moves[.left] = Self.avatarID((i - 1 + n) % n) }
        if i % columns == columns - 1 || i == n - 1 { moves[.right] = Self.avatarID((i + 1) % n) }
        return moves
    }

    private func pick(_ index: Int) {
        avatar = index
        // A new profile goes on to its name
        if !editing { focus.focus(Self.changeNameID) }
    }

    /// The profile name dialog; the accepted name is shown and the focus goes on to Create / Save.
    private func askName() {
        actions.openProfileNameDialog(title: L("firstrun_create_name_title"), initial: name) { entered in
            name = entered
            focus.focus("create")
        }
    }

    /// Without a name there is nothing to create: the dialog asks for one.
    private func submit() {
        guard let clean = Profile.cleanName(name) else {
            askName()
            return
        }
        onDone(clean, avatar)
    }
}

/// The avatar picker's grid on a stage of any width (`CircleRowFit` of DELOS for Android): as many columns as fit
/// between the margins, eight at most (four on a compact stage), and on a compact stage the gaps that keep a focused
/// circle's ring clear of its neighbours and of the label under it.
enum AvatarGridLayout {
    static let cell = 184.0, wideGap = 32.0, compactGap = 24.0
    /// A focused circle's growth, its ring (5 px gap and 5 px of ring) and the air kept above the next row.
    static let focusScale = 1.16, ring = 10.0, air = 12.0

    static func columnGap(_ stage: Stage) -> Double { stage.compact ? compactGap : wideGap }

    static func columns(_ stage: Stage) -> Int {
        let room = stage.width - 2 * (CenterColumnLayout.margin + max(stage.safe.leading, stage.safe.trailing))
        let gap = columnGap(stage), width = cell * stage.compactScale
        let fit = Int(((room + gap) / (width + gap)).rounded(.down))
        return min(stage.compact ? 4 : 8, max(fit, 2))
    }

    /// How far a focused circle [side] wide reaches beyond its box: half its growth and the ring.
    static func focusReach(_ side: Double) -> Double { side * (focusScale - 1) / 2 + ring * focusScale }
    /// The gap between a circle and its label on a compact stage: the reach and 8 px.
    static func labelGap(_ side: Double) -> Double { focusReach(side) + 8 }
    /// The gap between two rows on a compact stage: the reach and ``air``.
    static func rowGap(_ side: Double) -> Double { focusReach(side) + air }
}

/// A labelled value that looks like a ``TextPill`` but is not an input (`ValuePill` in DELOS for Android): the text is
/// typed in a dialog, the page shows what is there ([value], or [placeholder] in the muted color while it is empty).
struct ValuePill: View {
    let label: String
    let value: String
    let icon: String
    let placeholder: String
    var width = 520.0
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(16)) {
            SymbolView(symbol: icon, size: 34, color: colors.text3)
            VStack(alignment: .leading, spacing: 0) {
                Text(label.uppercased(with: .current))
                    .font(DelosFonts.figtree(stage.tpx(17), .semibold))
                    .tracking(stage.tpx(17) * 0.08)
                    .foregroundStyle(colors.text3.color)
                    .lineLimit(1)
                Text(value.isEmpty ? placeholder : value)
                    .font(DelosFonts.figtree(stage.tpx(30), .semibold))
                    .foregroundStyle((value.isEmpty ? colors.text3 : colors.text).color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, stage.px(28))
        .frame(width: stage.px(width), height: stage.px(84), alignment: .leading)
        .background {
            GlassShape(Capsule(), tint: colors.surface2)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }
}

/// Where Create goes after a profile was made (`CreateProfileScreen`'s `onDone` in `Shell.kt`).
enum FirstRunLanding: Equatable {
    /// The first run, no PC paired yet: the start screen with the pairing screen above it.
    case pair
    /// The first run with PCs paired already (the last profile was deleted, or the PCs were paired in the classic UI):
    /// the start screen, no pairing needed.
    case start
    /// A profile added from the profile screen: back to it.
    case back

    static func after(fromBoot: Bool, pairedPCs: Bool) -> FirstRunLanding {
        guard fromBoot else { return .back }
        return pairedPCs ? .start : .pair
    }
}
