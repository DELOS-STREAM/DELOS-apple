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

/// The top navigation in the middle of the status bar (`TopNav` of DELOS for Android): round 64 px buttons, 14 px apart,
/// in a glass capsule. The focused button lies on the main color, grows by 12 % and shows its name under it; the
/// current screen's button has its icon in the main color and a small dot. Android's buttons are Settings, Profile and
/// Devices; Devices waits for its screen.
struct TopNav: View {
    let buttons: [NavButton]
    let focus: FocusModel
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func buttons(current: Screen, onSettings: @escaping @MainActor () -> Void, onProfile: @escaping @MainActor () -> Void) -> [NavButton] {
        [
            NavButton(id: "nav-settings", icon: Symbols.settings, label: L("shell_nav_settings"), current: current == .settings, action: onSettings),
            NavButton(id: "nav-profile", icon: Symbols.accountCircle, label: L("shell_nav_profile"), current: current == .profile, action: onProfile),
        ]
    }

    var body: some View {
        HStack(spacing: stage.px(14)) {
            ForEach(buttons) { button in
                FocusItem(id: button.id, model: focus, action: button.action) { focused in
                    buttonView(button, focused: focused)
                }
            }
        }
        .padding(stage.px(8))
        .background {
            Capsule().fill(colors.surface.color)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
    }

    private func buttonView(_ button: NavButton, focused: Bool) -> some View {
        let size = 64.0
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
                    .font(DelosFonts.figtree(stage.px(18), .semibold))
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
/// start screen and the screens of the top navigation: a 620 px glass panel from the left with the profile and the
/// connected PC at its top. Android's quick settings (theme, background, sounds, haptics) are not ported yet; the one
/// row is All settings. A tap beside the panel, B or the menu button again closes it.
struct SideMenu: View {
    let profile: Profile?
    /// The PC whose library is open: its name and whether it is online.
    let pc: (name: String, online: Bool)?
    let focus: FocusModel
    let onSettings: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    static let settingsID = "side-settings"

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: stage.px(10)) {
                header
                FocusItem(id: Self.settingsID, model: focus, action: onSettings) { focused in
                    SettingRowView(
                        row: SettingRow(
                            id: Self.settingsID, tab: .stream, section: "", icon: Symbols.settings, label: L("shell_side_all_settings"),
                            value: .action, help: ""),
                        focused: focused, compact: true)
                }
                Spacer()
            }
            .padding(.top, stage.px(48 + stage.safe.top))
            .padding(.bottom, stage.px(48))
            .padding(.leading, stage.px(40 + stage.safe.leading))
            .padding(.trailing, stage.px(40))
            .frame(width: stage.px(620 + stage.safe.leading))
            .frame(maxHeight: .infinity)
            .background {
                Rectangle().fill(colors.surface3.color)
                    .overlay(alignment: .trailing) { Rectangle().fill(colors.line.color).frame(width: stage.px(1)) }
                    .ignoresSafeArea()
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var header: some View {
        HStack(spacing: stage.px(20)) {
            if let profile { AvatarBadge(avatar: .of(profile.avatar), size: 72, iconSize: 40) }
            VStack(alignment: .leading, spacing: stage.px(2)) {
                Text(profile?.name ?? "DELOS")
                    .font(DelosFonts.unbounded(stage.px(28)))
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                Text(status)
                    .font(DelosFonts.figtree(stage.px(20)))
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
