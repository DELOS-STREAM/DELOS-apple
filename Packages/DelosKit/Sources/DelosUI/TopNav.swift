import DelosData
import SwiftUI

/// A button of the top navigation.
struct NavButton: Identifiable {
    let id: String
    let icon: String
    let label: String
    /// The screen it opens is the one shown.
    let current: Bool
    let action: @MainActor () -> Void
}

/// The top navigation in the middle of the status bar (`TopNav` of DELOS for Android): round buttons [buttonSize] wide
/// (64 px; 56 on a compact stage) and [gap] apart (14 px, 6 when the compact bar is tight), in a glass capsule. The
/// focused button lies on the main color, grows by 12 % and shows its name under it; the current screen's button has its
/// icon in the main color and a small dot. The buttons are Settings, Profile and Devices, in Android's order.
struct TopNav: View {
    let buttons: [NavButton]
    let focus: FocusModel
    var buttonSize = 64.0
    var gap = StatusBarLayout.navGap
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    static func buttons(current: Screen, onSettings: @escaping @MainActor () -> Void, onProfile: @escaping @MainActor () -> Void,
        onDevices: @escaping @MainActor () -> Void
    ) -> [NavButton] {
        [
            NavButton(id: "nav-settings", icon: Symbols.settings, label: L("shell_nav_settings"), current: current == .settings, action: onSettings),
            NavButton(id: "nav-profile", icon: Symbols.accountCircle, label: L("shell_nav_profile"), current: current == .profile, action: onProfile),
            NavButton(id: "nav-devices", icon: Symbols.devices, label: L("shell_nav_devices"), current: current == .devices, action: onDevices),
        ]
    }

    /// Left from the first button goes to the last, right from the last to the first (the navigation is a cycle).
    /// On tvOS the system focus engine decides and does not wrap.
    nonisolated static func wrap(_ index: Int, of ids: [String]) -> [FocusDirection: AnyHashable] {
        guard ids.count > 1 else { return [:] }
        if index == 0 { return [.left: AnyHashable(ids[ids.count - 1])] }
        if index == ids.count - 1 { return [.right: AnyHashable(ids[0])] }
        return [:]
    }

    /// The pill that glides behind the buttons while the focus moves between two of them (`TransientPill`): both edges are
    /// springs, the one in the direction of travel the stiffer, and the focused button's own fill fades in over it at the
    /// end. Never drawn at rest.
    @State private var pill = NavPill()
    @State private var frames: [String: CGRect] = [:]
    @State private var handover: Task<Void, Never>?

    /// The focused button, nil while the focus is elsewhere.
    private var focusedID: String? {
        guard let id = focus.focused as? String, buttons.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        HStack(spacing: stage.px(gap)) {
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                FocusItem(id: button.id, model: focus, moves: Self.wrap(index, of: buttons.map(\.id)), action: button.action) { focused in
                    buttonView(button, focused: focused)
                }
                // The layout bounds the pill glides between, before the focus scale
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[button.id] = $0 }
            }
        }
        .coordinateSpace(name: Self.space)
        .background(alignment: .topLeading) {
            if pill.visible {
                Capsule().fill(colors.accent.color)
                    .frame(width: max(pill.right - pill.left, 0), height: pill.height)
                    .offset(x: pill.left, y: pill.top)
                    .allowsHitTesting(false)
            }
        }
        .padding(stage.px(StatusBarLayout.navPadding))
        .background {
            GlassShape(Capsule(), tint: colors.surface, role: .chrome)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .onChange(of: focusedID) { old, new in move(from: old, to: new) }
    }

    private static let space = "topnav"
    /// What a focused button is scaled to (`NAV_FOCUS_SCALE`).
    private static let focusScale = 1.12

    /// A button's bounds as it looks focused: scaled about its centre (`TransientPillMotion.scaled`).
    private func scaled(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: -frame.width * (Self.focusScale - 1) / 2, dy: -frame.height * (Self.focusScale - 1) / 2)
    }

    /// The focus moved from one button to another: the pill starts as the old one looks focused and glides to the new
    /// one. Focus entering from outside, leaving, and reduced motion show no pill.
    private func move(from old: String?, to new: String?) {
        handover?.cancel()
        guard let new, let old, old != new, !reduceMotion, let from = frames[old].map(scaled), let to = frames[new].map(scaled) else {
            pill.visible = false
            return
        }
        // A pill still on its way carries on from where it is
        if !pill.visible {
            pill.left = from.minX
            pill.right = from.maxX
        }
        pill.top = to.minY
        pill.height = to.height
        pill.handover = 0
        pill.visible = true
        let rightwards = to.minX + to.maxX >= pill.left + pill.right
        withAnimation(NavPill.edge(leading: !rightwards)) { pill.left = to.minX }
        withAnimation(NavPill.edge(leading: rightwards)) { pill.right = to.maxX }
        // The button's own focus scale comes to rest after `Motion.focus`: pill and button then have the same bounds
        handover = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Motion.focus))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: 0.14)) { pill.handover = 1 }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            pill.visible = false
        }
    }

    private func buttonView(_ button: NavButton, focused: Bool) -> some View {
        let size = buttonSize
        // The icon's color follows the pill under it (dark while the accent pill is there)
        let iconColor = focused ? colors.onAccent : button.current ? colors.accent : colors.text2
        return ZStack {
            // The glow of a round element (`focusEffects`' circle branch: full up to the circle with the spread, then fading), 10 / 30 / -8
            GlowDisc(radius: stage.px(size / 2), spread: stage.px(-8), blur: stage.px(30), color: colors.glow)
                .opacity(focused ? 1 : 0)
                .animation(.focusRing(focused: focused), value: focused)
            // The accent fill is the focus itself; while the pill is on its way it shows instead, and this fades in over it
            Circle().fill(colors.accent.color)
                .opacity(focused ? (pill.visible ? pill.handover : 1) : 0)
                .animation(nil, value: focused)
            SymbolView(symbol: button.icon, size: 34, color: iconColor, filled: focused)
                .animation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: Motion.fade / 1000), value: focused)
            if button.current && !focused {
                Circle().fill(colors.accent3.color)
                    .frame(width: stage.px(6), height: stage.px(6))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, stage.px(5))
            }
        }
        .frame(width: stage.px(size), height: stage.px(size))
        .scaleEffect(focused ? Self.focusScale : 1)
        .animation(.focusScale(pressed: false, reduced: reduceMotion), value: focused)
        // The name under the focused button (`.nav-btn .tip`), without widening the bar: it fades in over 280 ms and slides
        // down from a quarter of its height above its place over 560 ms, and leaves in 240 ms
        .overlay(alignment: .top) {
            if focused {
                Text(button.label)
                    .font(DelosFonts.figtree(stage.tpx(18), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, stage.px(14))
                    .padding(.vertical, stage.px(6))
                    .background(GlassShape(Capsule(), tint: colors.surface3))
                    .offset(y: stage.px(size + 20))
                    .transition(.asymmetric(
                        insertion: reduceMotion ? Self.tipFade(Motion.fade)
                            : Self.tipFade(Motion.fade).combined(with: SlideByHeight(fraction: -0.25).animation(Motion.out(Motion.popIn))),
                        removal: reduceMotion ? Self.tipFade(Motion.exit)
                            : Self.tipFade(Motion.exit).combined(with: SlideByHeight(fraction: -0.25).animation(LayerHost.easeIn(Motion.exit)))))
            }
        }
        .zIndex(focused ? 1 : 0)
        .accessibilityLabel(button.label)
    }

    private static func tipFade(_ ms: Double) -> AnyTransition {
        .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: ms / 1000))
    }
}

/// The pill's edges and visibility (`PillGeometry`).
struct NavPill {
    var left = 0.0
    var right = 0.0
    var top = 0.0
    var height = 0.0
    var visible = false
    /// How much of the focused button's own fill shows over the pill.
    var handover = 0.0

    /// An edge's spring (`SelectionPillMotion.edgeSpec`): damping ratio 0.8 and `GEO_STIFFNESS` 190, 1.5 times that for the
    /// edge in the direction of travel and 0.75 times for the one behind it.
    static func edge(leading: Bool) -> Animation {
        let stiffness = 190.0 * (leading ? 1.5 : 0.75)
        return .interpolatingSpring(mass: 1, stiffness: stiffness, damping: 2 * 0.8 * stiffness.squareRoot())
    }
}

/// The glow of a round element: the accent's glow color up to a circle of [radius] + [spread], fading to a third and then to
/// nothing over [blur] beyond it (the radial gradient `focusEffects` draws for round elements).
struct GlowDisc: View {
    let radius: Double
    let spread: Double
    let blur: Double
    let color: RGBA

    var body: some View {
        let inner = max(radius + spread, 1)
        let outer = inner + blur
        Circle()
            .fill(RadialGradient(stops: [
                .init(color: color.color, location: 0),
                .init(color: color.color, location: inner / outer),
                .init(color: color.opacity(0.32).color, location: (inner / outer + 1) / 2),
                .init(color: color.opacity(0).color, location: 1),
            ], center: .center, startRadius: 0, endRadius: outer))
            .frame(width: outer * 2, height: outer * 2)
            // Not under the element itself: its glass would show the glow through it (Android's glass is a blurred copy of
            // the background, which lies over the glow)
            .mask {
                ZStack {
                    Rectangle().fill(.white)
                    Circle().fill(.black).frame(width: radius * 2, height: radius * 2).blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .frame(width: radius * 2, height: radius * 2)
            .allowsHitTesting(false)
    }
}

/// The side menu (`SideMenuLayer` of DELOS for Android), which the left menu button (View, Select, Create) opens on the
/// start screen and the screens of the top navigation: a 680 px panel from the left with the profile and the
/// connected PC at its top, the quick settings (``QuickSettings``: theme, background, interface sounds, haptics; A or a tap
/// steps one, left and right step it either way) and All settings. A tap beside the panel, B or the menu button again closes it.
struct SideMenu: View {
    let profile: Profile?
    /// The PC whose library is open: its name and whether it is online.
    let pc: (name: String, online: Bool)?
    let focus: FocusModel
    /// The current profile's appearance, whose values the quick settings show.
    let appearance: Appearance
    /// A quick setting [id] was stepped by a direction (1 or -1).
    let onStep: @MainActor (_ id: String, _ direction: Int) -> Void
    let onSettings: @MainActor () -> Void
    /// The "Show hidden apps" row, while a game of the open library is hidden or it is on (nil: no row).
    var hidden: HiddenRow? = nil
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduceMotion

    /// The panel's width in stage pixels (the safe area on its left comes on top).
    static let width = 680.0
    /// How far the focused row's scale, ring and glow reach beyond the rows' place at the sides and above and below.
    static let glowSide = 40.0, glowVertical = 56.0
    static let settingsID = "side-settings"
    static let hiddenID = "side-hidden"

    /// What the "Show hidden apps" row shows: its switch and the count of hidden games under its label.
    struct HiddenRow: Equatable {
        let showing: Bool
        let note: String
    }

    var body: some View {
        // The scrim under it is the root's (`LayerScrim`, with the blur of the screen), as Android's `Scrim` is the shell's
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: stage.px(10)) {
                header
                    .staggerEntrance()
                // What does not fit scrolls, with its edges fading: the focus brings a row into view
                FocusScroll(axis: .vertical, fades: (Self.glowVertical + 16, Self.glowVertical + 40)) {
                    VStack(alignment: .leading, spacing: stage.px(10)) {
                        ForEach(QuickSettings.rows(appearance)) { row in
                            FocusItem(id: row.id, model: focus, action: { onStep(row.id, 1) }) { focused in
                                SettingRowView(row: row, focused: focused, compact: true)
                            }
                            .staggerEntrance()
                        }
                        FocusItem(id: Self.settingsID, model: focus, action: onSettings) { focused in
                            SettingRowView(
                                row: SettingRow(
                                    id: Self.settingsID, tab: .stream, section: "", icon: Symbols.settings, label: L("shell_side_all_settings"),
                                    value: .action(label: nil), help: ""),
                                focused: focused, compact: true)
                        }
                        .staggerEntrance()
                        if let hidden {
                            FocusItem(id: Self.hiddenID, model: focus, action: { onStep(Self.hiddenID, 1) }) { focused in
                                SettingRowView(
                                    row: SettingRow(
                                        id: Self.hiddenID, tab: .stream, section: "", icon: Symbols.visibility, label: L("shell_side_show_hidden"),
                                        value: .toggle(hidden.showing), help: "", note: hidden.note),
                                    focused: focused, compact: true)
                            }
                            .staggerEntrance()
                        }
                    }
                    .padding(.horizontal, stage.px(14 + Self.glowSide))
                    .padding(.vertical, stage.px(18 + Self.glowVertical))
                }
                .focusable(false)
                .padding(.horizontal, -stage.px(Self.glowSide))
                .padding(.vertical, -stage.px(Self.glowVertical))
                .frame(maxHeight: .infinity)
            }
            .entranceScope()
            .padding(.top, stage.px(48 + stage.safe.top))
            .padding(.bottom, stage.px(48))
            .padding(.leading, stage.px(40 + stage.safe.leading))
            .padding(.trailing, stage.px(40))
            .frame(width: stage.px(Self.width + stage.safe.leading))
            .frame(maxHeight: .infinity)
            .background {
                // backdropBlur(haze, 28f, surface3): the panel glass
                GlassShape(Rectangle(), tint: colors.surface3, role: .panel)
                    .overlay(alignment: .trailing) { Rectangle().fill(colors.line.color).frame(width: stage.px(1)) }
                    .ignoresSafeArea()
            }
            // `sideEnter` / `sideExit`: from a tenth of its width left of its place, sliding in over 560 ms (ease-out) while
            // fading in over 280 ms, and out over 240 ms (ease-in); with reduced motion it only fades
            .transition(.asymmetric(
                insertion: reduceMotion ? Self.fade(Motion.fade)
                    : Self.fade(Motion.fade).combined(with: .offset(x: -stage.px(Self.width) / 10).animation(Motion.out(Motion.popIn))),
                removal: reduceMotion ? Self.fade(Motion.exit)
                    : Self.fade(Motion.exit).combined(with: .offset(x: -stage.px(Self.width) / 10).animation(LayerHost.easeIn(Motion.exit)))))
        }
    }

    private static func fade(_ ms: Double) -> AnyTransition {
        .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: ms / 1000))
    }

    private var header: some View {
        HStack(spacing: stage.px(20)) {
            if let profile { AvatarBadge(avatar: .of(profile.avatar), size: 72, iconSize: 40) }
            VStack(alignment: .leading, spacing: stage.px(2)) {
                Text(profile?.name ?? "DELOS")
                    .font(DelosFonts.unbounded(stage.tpx(28)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                Text(status)
                    .font(DelosFonts.figtree(stage.tpx(20)))
                    .foregroundStyle(colors.text3.color)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, stage.px(12))
        .padding(.bottom, stage.px(24))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(colors.line.color).frame(height: stage.px(1)) }
        .padding(.bottom, stage.px(14))
    }

    private var status: String {
        guard let pc else { return L("shell_side_not_connected") }
        return pc.online ? L("shell_side_connected", pc.name) : L("shell_side_offline", pc.name)
    }
}
