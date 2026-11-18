import DelosData
import DelosHost
import Foundation

/// Adding a PC by its address and links from outside the app (`addAndPair` of `DeviceFlows.kt`, the link effect of
/// `Shell.kt` and ShortcutTrampoline of DELOS for Android).
extension ShellActions {
    /// "Add PC" in the address dialog, or a pairing link the player agreed to (`addAndPair`): asks the address who it is,
    /// then pairs with it (with the link's one-time [code], when it has a valid one), or opens its library when it is
    /// paired already. What goes wrong is said in a toast; false keeps the dialog open on a wrong address.
    func addAndPair(_ text: String, code: OneTimeCode? = nil) -> Bool {
        let address: HostAddress
        switch AddressEntry(text) {
        case .empty:
            feedback?.play(.error)
            toasts.show(L("devices_address_required"), icon: Symbols.error)
            return false
        case .invalid:
            feedback?.play(.error)
            toasts.show(L("devices_add_not_an_address", text.trimmingCharacters(in: .whitespacesAndNewlines)), icon: Symbols.error)
            return false
        case .address(let typed):
            address = typed
        }
        let code = code.flatMap { code -> OneTimeCode? in
            if case .code(let valid) = OneTimeCode.Entry(pin: code.pin, passphrase: code.passphrase) { valid } else { nil }
        }
        toasts.show(L("devices_address_looking", address.description), icon: Symbols.search)
        Task {
            do {
                let host = try await hosts.ask(address, typed: true)
                let added = await PairStateWait.until(timeout: 5, clock: SystemConnectClock()) { [hosts] in hosts.host(host.id) != nil }
                guard !Task.isCancelled else { return }
                guard added else {
                    feedback?.play(.error)
                    toasts.show(L("devices_address_not_added", address.description), icon: Symbols.error)
                    return
                }
                go {
                    if host.pin != nil {
                        connect(host.id)
                    } else if let code {
                        navigator.push(.pairCode(hostID: host.id, code: code), focus: "cancel")
                    } else {
                        navigator.push(.pin(hostID: host.id), focus: "cancel")
                    }
                }
            } catch {
                feedback?.play(.error)
                toasts.show(L("devices_add_no_answer", address.description), icon: Symbols.error)
            }
        }
        return true
    }

    /// A link from outside the app (`Shell.kt`): it can come from any web page or app, so pairing and starting a game ask
    /// first, in a security prompt. An `.art` file DELOS cannot use only says so (ShortcutTrampoline's `reject`).
    func openLink(_ link: ShellLink) {
        switch link {
        case .rejected(let key):
            reject(L(key))
        case .pair(let address, let name, let code):
            feedback?.play(.open)
            let who = name.map { "\($0) (\(address))" } ?? address
            layers.openDialog(DialogSpec(
                title: L("shell_link_pair_title", who), note: L("shell_link_pair_message"), fields: [],
                confirm: L("shell_link_pair_action")
            ) { [self] _ in
                _ = addAndPair(address, code: code)
                return true
            })
        case .launch(let launch):
            feedback?.play(.open)
            let prompt = launch.prompt
            layers.openDialog(DialogSpec(title: prompt.title, note: prompt.message, fields: [], confirm: L("shell_link_start_action")) { [self] _ in
                start(launch)
                return true
            })
        }
    }

    /// A launch link the player agreed to (ShortcutTrampoline): the PC it names is opened (woken and waited for when it
    /// sleeps), then its game starts. Another game running on the PC is never quit: its games open with a toast. A PC that
    /// is not paired shows the start's failure: the stream's result overlay for a game, a toast for the PC alone.
    private func start(_ link: LaunchLink) {
        let target: (id: String?, name: String?, app: LaunchLink.AppRef?)
        switch link.target {
        case .invalid(let key):
            reject(L(key))
            return
        case .host(let id, let name, let app):
            target = (id, name, app)
        }
        let host = target.id.flatMap { hosts.host($0) }
            ?? target.name.flatMap { name in hosts.hosts.first { $0.name == name || $0.serverName == name } }
        guard let host else {
            reject(L("scut_pc_not_found"))
            return
        }
        guard host.pin != nil else {
            if let app = target.app {
                var appID = Self.resolve(app, in: hosts.apps[host.id] ?? [])?.id
                if appID == nil, case .id(let id) = app { appID = id }
                guard let appID else {
                    reject(L("scut_invalid_app_id"))
                    return
                }
                go {
                    navigator.openHome(hostID: host.id)
                    navigator.openStream(hostID: host.id, appID: appID)
                }
            } else {
                reject(L("stream_result_unpaired", host.name))
            }
            return
        }
        connection.connect(host.id) { [self] in
            guard let ref = target.app else { return }
            guard let app = Self.resolve(ref, in: hosts.apps[host.id] ?? []) else {
                reject(L("scut_invalid_app_id"))
                return
            }
            let runningID = hosts.host(host.id)?.runningAppID ?? 0
            guard runningID == 0 || runningID == app.id else {
                let running = hosts.apps[host.id]?.first { $0.id == runningID }
                toasts.show(running.map { L("scut_game_running", $0.title) } ?? L("scut_other_game_running"), icon: Symbols.info)
                return
            }
            play(hostID: host.id, app: app)
        }
    }

    /// The game a link names among the PC's [apps]: by its UUID, its id, or its name (any case).
    static func resolve(_ ref: LaunchLink.AppRef, in apps: [HostApp]) -> HostApp? {
        switch ref {
        case .uuid(let uuid): apps.first { $0.uuid?.caseInsensitiveCompare(uuid) == .orderedSame }
        case .id(let id): apps.first { $0.id == id }
        case .name(let name): apps.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// A link that names nothing DELOS can start: an error toast.
    private func reject(_ text: String) {
        feedback?.play(.error)
        toasts.show(text, icon: Symbols.error, kind: .error)
    }
}
