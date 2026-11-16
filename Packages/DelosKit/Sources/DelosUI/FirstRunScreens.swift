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
                .font(DelosFonts.unbounded(stage.px(stage.compact ? 96 : 132)))
                .tracking(stage.px(stage.compact ? 96 : 132) * 0.24)
                .foregroundStyle(colors.text.color)
                .padding(.leading, stage.px(stage.compact ? 22 : 30))
            Text(L("firstrun_boot_tagline"))
                .font(DelosFonts.figtree(stage.px(28)))
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
/// The name is typed straight into the field (touch or a hardware keyboard); a controller user keeps the default name.
/// DELOS for Android shows the name in a pill with a "Change name" button that opens its text dialog, which does not
/// exist here yet.
struct CreateProfileScreen: View {
    let editing: Bool
    let focus: FocusModel
    let navigator: Navigator
    let feedback: Feedback?
    let onDone: (_ name: String, _ avatar: Int) -> Void
    @State private var avatar: Int
    @State private var name: String
    @FocusState private var typing: Bool
    @Environment(\.stage) private var stage

    init(
        editing: Bool, initial: Profile?, focus: FocusModel, navigator: Navigator, feedback: Feedback?,
        onDone: @escaping (_ name: String, _ avatar: Int) -> Void
    ) {
        self.editing = editing
        self.focus = focus
        self.navigator = navigator
        self.feedback = feedback
        self.onDone = onDone
        _avatar = State(initialValue: Avatar.of(initial?.avatar ?? 0).index)
        _name = State(initialValue: initial?.name ?? L("firstrun_create_default_name"))
    }

    /// The focus id of an avatar's circle.
    static func avatarID(_ index: Int) -> AnyHashable { AnyHashable("avatar-\(index)") }

    /// Eight columns: 144 px circles in 184 px cells, 32 px apart (1696 px); a compact stage takes four.
    private var columns: Int { stage.compact ? 4 : 8 }

    var body: some View {
        VStack(spacing: stage.px(40)) {
            Heading(
                title: editing ? L("firstrun_create_edit_title") : L("firstrun_create_new_title"),
                sub: editing ? L("firstrun_create_edit_note") : L("firstrun_create_new_note")
            )
            avatarGrid
            nameField
            FocusItem(id: "create", model: focus, action: submit) { focused in
                PillButton(
                    label: editing ? L("firstrun_create_save") : L("firstrun_create_create"),
                    icon: Symbols.check, primary: true, focused: focused
                )
            }
        }
        .onChange(of: typing) { _, now in navigator.isEditingText = now }
        .onChange(of: navigator.isEditingText) { _, now in if !now { typing = false } }
        .onChange(of: name) { _, now in
            if now.count > Profile.maxNameLength { name = String(now.prefix(Profile.maxNameLength)) }
        }
    }

    /// All avatars in rows. Up and down move to the same column; left at the start of a row and right at its end
    /// continue in the previous and the next row, and wrap from the last avatar to the first.
    private var avatarGrid: some View {
        let all = Avatar.all
        let rows = stride(from: 0, to: all.count, by: columns).map { Array(all[$0..<min($0 + columns, all.count)]) }
        return VStack(spacing: stage.px(26)) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(alignment: .top, spacing: stage.px(stage.compact ? 24 : 32)) {
                    ForEach(rows[row]) { a in
                        FocusItem(id: Self.avatarID(a.index), model: focus, moves: wrap(a.index), action: { pick(a.index) }) { focused in
                            CircleItem(
                                icon: a.icon, label: a.label, avatar: a, selected: a.index == avatar,
                                diameter: 144, width: 184, focused: focused
                            )
                        }
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
        if !editing { focus.focus("name") }
    }

    @ViewBuilder private var nameField: some View {
        #if os(tvOS)
        // The system focus engine moves onto the text field itself; selecting it opens the system keyboard
        TextPill(
            label: L("firstrun_create_name_label"), icon: Symbols.badge, placeholder: L("firstrun_create_name_placeholder"),
            text: $name, editing: $typing, focused: false, onSubmit: nameEntered
        )
        .onChange(of: typing) { _, now in if now { focus.focus("name") } }
        .onChange(of: focus.focused) { _, now in if now == AnyHashable("name") { typing = true } }
        #else
        FocusItem(id: "name", model: focus, action: { typing = true }) { focused in
            TextPill(
                label: L("firstrun_create_name_label"), icon: Symbols.badge, placeholder: L("firstrun_create_name_placeholder"),
                text: $name, editing: $typing, focused: focused, onSubmit: nameEntered
            )
        }
        #endif
    }

    /// The name is accepted: the focus goes on to Create / Save.
    private func nameEntered() {
        typing = false
        focus.focus("create")
    }

    /// Without a name there is nothing to create: the field asks for one.
    private func submit() {
        guard let clean = Profile.cleanName(name) else {
            feedback?.play(.error)
            focus.focus("name")
            typing = true
            return
        }
        onDone(clean, avatar)
    }
}
