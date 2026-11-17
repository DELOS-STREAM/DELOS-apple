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

    var body: some View {
        HStack(spacing: stage.px(gap)) {
            ForEach(Array(buttons.enumerated()), id: \.element.id) { index, button in
                FocusItem(id: button.id, model: focus, moves: Self.wrap(index, of: buttons.map(\.id)), action: button.action) { focused in
                    buttonView(button, focused: focused)
                }
            }
        }
        .padding(stage.px(StatusBarLayout.navPadding))
        .background {
            GlassShape(Capsule(), tint: colors.surface, role: .chrome)
        }
    }

    private func buttonView(_ button: NavButton, focused: Bool) -> some View {
        let size = buttonSize
        return ZStack {
            Circle().fill(colors.accent.color).opacity(focused ? 1 : 0)
            SymbolView(symbol: button.icon, size: 34, color: focused ? colors.onAccent : button.current ? colors.accent : colors.text2, filled: focused)
            if button.current && !focused {
                Circle().fill(colors.accent3.color)
                    .frame(width: stage.px(6), height: stage.px(6))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, stage.px(5))
            }
        }
        .frame(width: stage.px(size), height: stage.px(size))
        .shadow(color: focused ? colors.glow.color : .clear, radius: stage.px(15), y: stage.px(10))
        .scaleEffect(focused ? 1.12 : 1)
        // The name under the focused button, without widening the bar
        .overlay(alignment: .top) {
            if focused {
                Text(button.label)
                    .font(DelosFonts.figtree(stage.tpx(18), .semibold))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, stage.px(14))
                    .padding(.vertical, stage.px(6))
                    .background(Capsule().fill(colors.surface3.color))
                    .offset(y: stage.px(size + 20))
                    .transition(.opacity.combined(with: .offset(y: -stage.px(6))))
            }
        }
        .zIndex(focused ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.68), value: focused)
        .accessibilityLabel(button.label)
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
