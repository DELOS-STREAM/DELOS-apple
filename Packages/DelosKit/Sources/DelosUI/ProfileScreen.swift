import DelosData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// `#scr-profile` (`ProfileScreen` in DELOS for Android): the current profile with its avatar, and changing its avatar,
/// adding a profile or deleting this one.
///
/// Android's Rename and Switch profile are left out until their layers exist: Rename opens the text dialog and Switch
/// opens the profiles context menu. The name can be changed on the Change avatar page, whose name field is typed in
/// directly. Delete has no Undo toast yet (no toasts exist), so it is final at once.
struct ProfileScreen: View {
    let profile: Profile
    let count: Int
    let focus: FocusModel
    let onChangeAvatar: @MainActor () -> Void
    let onAdd: @MainActor () -> Void
    let onDelete: @MainActor () -> Void
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(54)) {
            VStack(spacing: stage.px(18)) {
                // box-shadow: 0 30px 80px -24px glow
                AvatarBadge(avatar: .of(profile.avatar), size: 240, iconSize: 120)
                    .shadow(color: colors.glow.color, radius: stage.px(40), y: stage.px(30))
                Text(profile.name)
                    .font(DelosFonts.unbounded(stage.px(stage.compact ? 48 : 64)))
                    .tracking(-stage.px(stage.compact ? 48 : 64) * 0.01)
                    .foregroundStyle(colors.text.color)
                    .lineLimit(1)
                Text(L("profile_signed_in", DeviceModel.name, count))
                    .font(DelosFonts.figtree(stage.px(26)))
                    .foregroundStyle(colors.text2.color)
            }
            HStack(alignment: .top, spacing: stage.px(56)) {
                FocusItem(id: "change-avatar", model: focus, action: onChangeAvatar) { focused in
                    CircleItem(icon: Symbols.face, label: L("profile_change_avatar"), big: false, focused: focused)
                }
                FocusItem(id: "add", model: focus, action: onAdd) { focused in
                    CircleItem(icon: Symbols.personAdd, label: L("profile_add"), big: false, focused: focused)
                }
                FocusItem(id: "delete", model: focus, action: onDelete) { focused in
                    CircleItem(icon: Symbols.delete, label: L("profile_delete"), big: false, focused: focused)
                }
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
                .font(DelosFonts.figtree(stage.px(24), .semibold))
                .foregroundStyle(colors.text.color)
                .lineLimit(1)
            SymbolView(symbol: Symbols.expandMore, size: 28, color: focused ? colors.accent : colors.text3)
        }
        .padding(.leading, stage.px(6))
        .padding(.trailing, stage.px(26))
        .frame(height: stage.px(68))
        .background {
            Capsule().fill(colors.surface.color)
                .overlay(Capsule().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
        }
        .focusLook(focused, scale: 1.06, ring: 4, glowBlur: 40, glowY: 14)
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
