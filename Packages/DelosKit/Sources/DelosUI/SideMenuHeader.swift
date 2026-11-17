import DelosData
import DelosHost
import SwiftUI

/// The live state of the PC whose library is open, as the side menu's header shows it: a dot and a word.
enum SidePCState: Equatable, Sendable {
    case online, streaming, connecting, asleep, offline

    /// The state of a PC that is [reachability], runs a game ([running]) and is being connected to ([connecting]); one
    /// that is not online is asleep when it can be woken ([canWake]: its MAC address is known). Not known yet (the first
    /// answer has not come) counts as connecting.
    static func of(reachability: HostRecord.Reachability, running: Bool, connecting: Bool, canWake: Bool) -> SidePCState {
        if connecting { return .connecting }
        switch reachability {
        case .online: return running ? .streaming : .online
        case .unknown: return .connecting
        case .offline: return canWake ? .asleep : .offline
        }
    }

    static func of(_ host: HostRecord, connecting: Bool) -> SidePCState {
        of(reachability: host.reachability, running: host.runningAppID != 0, connecting: connecting, canWake: host.macAddress != nil)
    }

    var label: String {
        switch self {
        case .online: L("devices_status_online")
        case .streaming: L("shell_side_pc_streaming")
        case .connecting: L("shell_side_pc_connecting")
        case .asleep: L("devices_status_asleep")
        case .offline: L("devices_status_offline")
        }
    }
}

/// The PC in the side menu's header: its name and live state.
struct SidePC: Equatable {
    let name: String
    let state: SidePCState
}

/// The side menu's header (prototype A, "Status card"): the profile's avatar and name, under the name the PC with its live
/// dot and state (or "Not connected"), then a card in the stat-block language of the home screen with the profile's whole
/// streaming time and its last stream, and the rule above the rows.
struct SideMenuHeader: View {
    let profile: Profile?
    let pc: SidePC?
    let playtime: Playtime
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        let texts = PlaytimeTexts(playtime)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: stage.px(20)) {
                if let profile { AvatarBadge(avatar: .of(profile.avatar), size: 72, iconSize: 40) }
                VStack(alignment: .leading, spacing: stage.px(6)) {
                    Text(profile?.name ?? "DELOS")
                        .font(DelosFonts.unbounded(stage.tpx(28)))
                        .foregroundStyle(colors.text.color)
                        .lineLimit(1)
                    pcLine
                }
            }
            .padding(.horizontal, stage.px(12))
            HStack(spacing: stage.px(28)) {
                VStack(alignment: .leading, spacing: stage.px(6)) {
                    Eyebrow(text: texts.eyebrowTime, color: colors.accent)
                    HStack(alignment: .firstTextBaseline, spacing: stage.px(8)) {
                        Text(texts.full.number)
                            .font(DelosFonts.figtree(stage.tpx(30), .bold).monospacedDigit())
                            .foregroundStyle(colors.text.color)
                        Text(texts.full.unit)
                            .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                            .foregroundStyle(colors.text2.color)
                    }
                    .frame(height: stage.tpx(30))
                }
                StatDivider()
                VStack(alignment: .leading, spacing: stage.px(6)) {
                    Eyebrow(text: texts.eyebrowLast, color: colors.text3)
                    Text(texts.last)
                        .font(DelosFonts.figtree(stage.tpx(23), .semibold).monospacedDigit())
                        .foregroundStyle(colors.text2.color)
                        .frame(height: stage.tpx(30))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.vertical, stage.px(18))
            .padding(.horizontal, stage.px(24))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: stage.px(24), style: .continuous)
                shape.fill(colors.surface.color).overlay(shape.strokeBorder(colors.line.color, lineWidth: stage.px(1)))
            }
            .padding(.horizontal, stage.px(12))
            .padding(.top, stage.px(22))
            .padding(.bottom, stage.px(24))
            Rectangle().fill(colors.line.color).frame(height: stage.px(1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, stage.px(14))
        .accessibilityElement(children: .combine)
    }

    /// The PC's dot, name and state, or "Not connected".
    @ViewBuilder private var pcLine: some View {
        if let pc {
            HStack(spacing: stage.px(12)) {
                SidePCDot(state: pc.state)
                Text(pc.name)
                    .foregroundStyle(colors.text2.color)
                    .layoutPriority(-1)
                Text("·")
                    .foregroundStyle(colors.text3.color)
                Text(pc.state.label)
                    .foregroundStyle(colors.text3.color)
            }
            .font(DelosFonts.figtree(stage.tpx(21)))
            .lineLimit(1)
        } else {
            Text(L("shell_side_not_connected"))
                .font(DelosFonts.figtree(stage.tpx(21)))
                .foregroundStyle(colors.text3.color)
                .lineLimit(1)
        }
    }
}

/// The 12 px dot of a PC's state: green with its glow while online, the main color with a slow pulse while it streams,
/// the second accent blinking while it connects, a ring while it sleeps, grey while offline. Reduced motion: no pulse.
struct SidePCDot: View {
    let state: SidePCState
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reducedMotion
    @State private var beat = false

    var body: some View {
        let size = stage.px(12)
        Group {
            switch state {
            case .online:
                Circle().fill(RGBA.onlineGreen.color).shadow(color: RGBA.onlineGreen.color, radius: stage.px(5))
            case .streaming:
                Circle().fill(colors.accent.color).shadow(color: colors.accent.color, radius: stage.px(beat ? 1 : 6))
                    .scaleEffect(beat ? 0.8 : 1)
            case .connecting:
                Circle().fill(colors.accent2.color).opacity(beat ? 0.25 : 1)
            case .asleep:
                Circle().strokeBorder(colors.text3.color, lineWidth: stage.px(2))
            case .offline:
                Circle().fill(colors.text3.color)
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(state) \(reducedMotion)") {
            beat = false
            guard !reducedMotion, state == .streaming || state == .connecting else { return }
            withAnimation(.easeInOut(duration: state == .streaming ? 0.8 : 0.5).repeatForever(autoreverses: true)) { beat = true }
        }
    }
}
