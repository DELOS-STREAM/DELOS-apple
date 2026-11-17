import DelosData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// `#scr-profile` (`ProfileScreen` in DELOS for Android): the current profile with its avatar, and changing its avatar,
/// renaming it (the profile name dialog), switching to another one (the profiles menu), adding a profile or deleting
/// this one (at once, with Undo in the toast).
struct ProfileScreen: View {
    let profile: Profile
    let count: Int
    let focus: FocusModel
    let actions: ShellActions
    let onChangeAvatar: @MainActor () -> Void
    let onAdd: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        CenterColumn(gap: 54) {
            VStack(spacing: stage.px(18 * stage.compactScale)) {
                AvatarBadge(avatar: .of(profile.avatar), size: 240 * stage.compactScale, iconSize: 120 * stage.compactScale)
                    .background {
                        // box-shadow: 0 30px 80px -24px glow: a blur of 80 (sigma 40) of the circle shrunk by the spread
                        Circle().fill(colors.glow.color)
                            .padding(stage.px(24))
                            .blur(radius: stage.px(40))
                            .offset(y: stage.px(30))
                    }
                Text(profile.name)
                    .font(DelosFonts.unbounded(stage.tpx(stage.compact ? 48 : 64)))
                    .tracking(-stage.tpx(stage.compact ? 48 : 64) * 0.01)
                    .foregroundStyle(colors.text.color)
                Text(L("profile_signed_in", DeviceModel.name, count))
                    .font(DelosFonts.figtree(stage.tpx(26)))
                    .foregroundStyle(colors.text2.color)
            }
            CircleRow {
                FocusItem(id: "change-avatar", model: focus, action: onChangeAvatar) { focused in
                    CircleItem(icon: Symbols.face, label: L("profile_change_avatar"), big: false, focused: focused)
                }
                .staggerEntrance()
                FocusItem(id: "rename", model: focus, action: actions.renameProfile) { focused in
                    CircleItem(icon: Symbols.edit, label: L("profile_rename"), big: false, focused: focused)
                }
                .staggerEntrance()
                FocusItem(
                    id: "switch", model: focus, menu: { actions.profilesMenu() }, action: { actions.layers.openContextMenu(of: focus) }
                ) { focused in
                    CircleItem(icon: Symbols.switchAccount, label: L("profile_switch"), big: false, focused: focused)
                }
                .staggerEntrance()
                FocusItem(id: "add", model: focus, action: onAdd) { focused in
                    CircleItem(icon: Symbols.personAdd, label: L("profile_add"), big: false, focused: focused)
                }
                .staggerEntrance()
                FocusItem(id: "delete", model: focus, action: actions.deleteProfile) { focused in
                    CircleItem(icon: Symbols.delete, label: L("profile_delete"), big: false, focused: focused)
                }
                .staggerEntrance()
            }
        }
    }
}

/// The current profile at the top of the start screen (`ProfileChip` in DELOS for Android): the avatar, the name and a
/// chevron in a 68 px glass pill.
struct ProfileChip: View {
    let profile: Profile
    let focused: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(14)) {
            AvatarBadge(avatar: .of(profile.avatar), size: 56, iconSize: 30)
            Text(profile.name)
                .font(DelosFonts.figtree(stage.tpx(24), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(stage.compact ? 1 : nil)
            SymbolView(symbol: Symbols.expandMore, size: 28, color: focused ? colors.accent : colors.text3)
                .fixedSize()
        }
        .padding(.leading, stage.px(6))
        .padding(.trailing, stage.px(26))
        .frame(height: stage.px(68))
        .background {
            GlassShape(Capsule(), tint: colors.surface, share: 1)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .focusLook(focused, scale: 1.06, ring: 4, glowBlur: 40, glowY: 14, glowSpread: -12, gap: 4)
    }
}

/// What the device is, for "Signed in on this …" (Android shows its `Build.MODEL`).
enum DeviceModel {
    @MainActor static var name: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
    }
}
