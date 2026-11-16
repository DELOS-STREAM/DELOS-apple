import DelosData
import DelosHost
import SwiftUI

/// What the Devices screen decides without drawing (`DevicesScreen`, `deviceMenu` of DELOS for Android's
/// DeviceScreens.kt): which PCs it lists, the line under each and the rows of its menu.
enum DevicesLogic {
    /// One row of a PC's menu.
    enum Action: Equatable {
        /// Connect (opens the PC's apps), or "Open its apps" when its library is the one open.
        case connect(openApps: Bool)
        case makeDefault, clearDefault, wake, rename, unpair, remove
    }

    /// The paired PCs by name (the Devices screen lists no found-but-unpaired PC).
    static func paired(_ hosts: [HostRecord]) -> [HostRecord] {
        hosts.filter { $0.pin != nil }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The line under a PC: Connected (online, and its library is open), Online, Asleep (it can be woken: its MAC address is
    /// known) or Offline; the default PC says so too. Android's Devices screen leaves the default out; the start screen
    /// has it, and this screen's menu can set it, so the status shows it.
    nonisolated static func status(_ host: HostRecord, active: Bool, isDefault: Bool) -> String {
        let online = host.reachability == .online
        let status = online ? L(active ? "devices_status_connected" : "devices_status_online")
            : host.macAddress != nil ? L("devices_status_asleep") : L("devices_status_offline")
        return isDefault ? L("devices_status_with_default", status, L("devices_status_default")) : status
    }

    /// The rows of a PC's menu, in Android's order: Connect, Rename, Wake (only an offline PC that can be woken), Unpair (only
    /// an online one), Remove. The default PC toggle comes after Connect.
    static func actions(_ host: HostRecord, active: Bool, isDefault: Bool) -> [Action] {
        let online = host.reachability == .online
        var rows: [Action] = [.connect(openApps: active), isDefault ? .clearDefault : .makeDefault, .rename]
        if !online, host.macAddress != nil { rows.append(.wake) }
        if online { rows.append(.unpair) }
        rows.append(.remove)
        return rows
    }

    /// The first focus: the first PC, else "Pair a new PC".
    static func firstFocus(_ paired: [HostRecord]) -> String {
        paired.first.map { StartScreen.pcID($0.id) } ?? "pair"
    }

    /// The sentence a failed or successful unpairing says (`UnpairResult.text`).
    nonisolated static func unpairText(_ result: HostStore.UnpairResult, name: String) -> String {
        switch result {
        case .unpaired: L("devices_unpaired", name)
        case .offline: L("devices_unpair_offline", name)
        case .notPaired: L("devices_unpair_not_paired", name)
        case .failed: L("devices_unpair_failed", name)
        case .unreachable: L("devices_unreachable", name)
        }
    }
}

/// `#scr-devices` (`DevicesScreen` in DELOS for Android): the paired PCs in circles with their status, the one whose library
/// is open marked; A or a tap opens a PC's menu (connect, default, rename, wake, unpair, remove), and the last circle pairs
/// a new PC (the pairing screen lists the PCs found and takes an address). Showing it looks for PCs and asks the paired
/// ones again, as the start screen does.
struct DevicesScreen: View {
    let focus: FocusModel
    /// The PC whose library is open below this screen.
    let activeID: String?
    let defaultPC: String?
    let actions: ShellActions
    let onPair: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage

    var body: some View {
        let paired = DevicesLogic.paired(hosts.hosts)
        VStack(spacing: stage.px(48)) {
            Heading(title: L("devices_title"), sub: L("devices_note"))
                .staggerEntrance()
            CircleRow {
                ForEach(paired, id: \.id) { host in
                    let active = host.id == activeID
                    FocusItem(
                        id: StartScreen.pcID(host.id), model: focus, menu: { actions.devicesMenu(host.id) },
                        action: { actions.layers.openContextMenu(of: focus) }
                    ) { focused in
                        CircleItem(
                            icon: Symbols.desktopWindows, label: host.name,
                            meta: DevicesLogic.status(host, active: active, isDefault: host.id == defaultPC),
                            metaDot: host.reachability == .online ? .onlineGreen : nil,
                            selected: active, focused: focused)
                    }
                    .staggerEntrance()
                }
                FocusItem(id: "pair", model: focus, action: onPair) { focused in
                    CircleItem(icon: Symbols.addLink, label: L("devices_pair_new"), meta: L("devices_pair_new_meta"), focused: focused)
                }
                .staggerEntrance()
            }
        }
        .entranceScope()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { hosts.startDiscovery() }
        .task {
            let ids = hosts.paired.map(\.id)
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await hosts.refresh(id) } }
            }
        }
    }
}
