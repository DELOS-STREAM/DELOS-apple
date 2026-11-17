import DelosData
import DelosHost

/// What the context menus and dialogs of the screens do (`DeviceActions`, `GameActions` and the profile functions of
/// DELOS for Android): each menu is built when it opens, from what is true then, and its actions report in a toast.
@MainActor
final class ShellActions {
    let navigator: Navigator
    let hosts: HostStore
    let profiles: ProfileStore
    let toasts: Toasts
    let layers: Layers
    let artwork: ArtworkStore
    let metadata: GameMetadataModel
    /// Connecting to a PC: the portal, the wake-up and the wait.
    let connection: ConnectFlow
    private let playtimes = PlaytimeStore()
    private let played = PlayedGames()
    let streams = StreamSettingsStore()
    let gameSettings = GameSettingsStore()

    init(navigator: Navigator, hosts: HostStore, profiles: ProfileStore, toasts: Toasts, layers: Layers, artwork: ArtworkStore,
         metadata: GameMetadataModel) {
        self.navigator = navigator
        self.hosts = hosts
        self.profiles = profiles
        self.toasts = toasts
        self.layers = layers
        self.artwork = artwork
        self.metadata = metadata
        connection = ConnectFlow(
            environment: AppConnectEnvironment(hosts: hosts, toasts: toasts, layers: layers) { id in
                go { navigator.openHome(hostID: id) }
            },
            clock: SystemConnectClock())
    }

    /// Opens a PC's library through the portal (`DeviceActions.connect`): a PC that sleeps is woken up and waited for.
    func connect(_ hostID: String) {
        connection.connect(hostID)
    }

    var feedback: Feedback? { layers.feedback }

    /// The start screen's first focus: the default PC, else the first paired PC that is online, else the first one,
    /// else "Pair a new PC".
    func startFocus() -> String {
        let paired = hosts.paired.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let pc = paired.first { $0.id == profiles.startup.defaultPC } ?? paired.first { $0.reachability == .online } ?? paired.first
        return pc.map { StartScreen.pcID($0.id) } ?? "pair"
    }

    // MARK: PCs

    /// The menu of a PC on the start screen (`startMenu`): start DELOS with it or not, wake it when it sleeps, rename it.
    func startMenu(_ hostID: String) -> ContextMenu? {
        guard let host = hosts.host(hostID) else { return nil }
        var items = [
            profiles.startup.defaultPC == hostID
                ? MenuItem(icon: Symbols.star, label: L("devices_menu_default_off")) { [self] in setDefault(nil) }
                : MenuItem(icon: Symbols.star, label: L("devices_menu_default_on")) { [self] in setDefault(host) },
        ]
        if host.reachability != .online, host.macAddress != nil {
            items.append(MenuItem(icon: Symbols.wake, label: L("devices_menu_wake")) { [self] in wake(hostID) })
        }
        items.append(MenuItem(icon: Symbols.edit, label: L("devices_menu_rename")) { [self] in rename(hostID) })
        return ContextMenu(title: host.name, items: items, below: true)
    }

    /// The Devices screen's first focus (`DevicesLogic.firstFocus`).
    func devicesFocus() -> String { DevicesLogic.firstFocus(DevicesLogic.paired(hosts.hosts)) }

    /// The menu of a PC on the Devices screen (`deviceMenu`): connect or open its apps, make it the default or not, rename
    /// it, wake it (offline), unpair it (online), remove it from DELOS. Android's menu has no default row; the start
    /// screen's has, and the task of this screen includes it.
    func devicesMenu(_ hostID: String) -> ContextMenu? {
        guard let host = hosts.host(hostID) else { return nil }
        let active = hostID == libraryHostID
        let items = DevicesLogic.actions(host, active: active, isDefault: profiles.startup.defaultPC == hostID).map { action in
            switch action {
            case .connect(let openApps):
                MenuItem(icon: Symbols.login, label: L(openApps ? "devices_menu_open_games" : "devices_menu_connect")) { [self] in
                    connect(hostID)
                }
            case .makeDefault: MenuItem(icon: Symbols.star, label: L("devices_menu_default_on")) { [self] in setDefault(host) }
            case .clearDefault: MenuItem(icon: Symbols.star, label: L("devices_menu_default_off")) { [self] in setDefault(nil) }
            case .rename: MenuItem(icon: Symbols.edit, label: L("devices_menu_rename")) { [self] in rename(hostID) }
            case .wake: MenuItem(icon: Symbols.wake, label: L("devices_menu_wake")) { [self] in wake(hostID) }
            case .unpair: MenuItem(icon: Symbols.linkOff, label: L("devices_menu_unpair")) { [self] in unpair(hostID) }
            case .remove: MenuItem(icon: Symbols.delete, label: L("devices_menu_remove"), danger: true) { [self] in remove(hostID) }
            }
        }
        return ContextMenu(title: host.name, items: items, below: true)
    }

    /// Asks the online PC to forget this client (`unpair`); the PC leaves the list once it has.
    private func unpair(_ hostID: String) {
        guard let name = hosts.host(hostID)?.name else { return }
        Task {
            let result = await hosts.unpairOnPC(hostID)
            if result == .unpaired {
                gameSettings.remove(hostID: hostID)
                if profiles.startup.defaultPC == hostID { profiles.setDefaultPC(nil) }
                navigator.dropLibrary(of: hostID)
            } else {
                feedback?.play(.error)
            }
            toasts.show(
                DevicesLogic.unpairText(result, name: name), icon: result == .unpaired ? Symbols.linkOff : Symbols.error,
                kind: result == .unpaired ? .success : .error)
        }
    }

    /// Removes the PC from DELOS at once (`remove`): choosing it is the confirmation; the PC can be found and paired again.
    private func remove(_ hostID: String) {
        guard let name = hosts.host(hostID)?.name else { return }
        hosts.remove(hostID)
        gameSettings.remove(hostID: hostID)
        if profiles.startup.defaultPC == hostID { profiles.setDefaultPC(nil) }
        navigator.dropLibrary(of: hostID)
        toasts.show(L("devices_removed_toast", name), icon: Symbols.delete)
    }

    private func setDefault(_ host: HostRecord?) {
        profiles.setDefaultPC(host?.id)
        toasts.show(host.map { L("devices_default_set_toast", $0.name) } ?? L("devices_default_cleared_toast"), icon: Symbols.star)
    }

    private func wake(_ hostID: String) {
        guard let name = hosts.host(hostID)?.name else { return }
        Task {
            let error: String? = switch await hosts.wake(hostID) {
            case .sent: nil
            case .noMAC: L("devices_wake_unsupported", name)
            case .failed: L("devices_wake_failed")
            }
            if error != nil { feedback?.play(.error) }
            toasts.show(error ?? L("devices_wake_sent_toast", name), icon: Symbols.wake, kind: error != nil ? .error : .info)
        }
    }

    /// "Pair with a one-time code" (`pairWithCode`): a dialog for the PIN and passphrase made in the PC's web UI; a valid
    /// pair goes on to the pairing screen, which sends them. What is wrong with them is said in a toast.
    func pairWithCode(hostID: String) {
        layers.openDialog(DialogSpec(
            title: L("pairing_otp_title"), note: L("pairing_otp_note"),
            fields: [
                DialogField(icon: Symbols.dialpad, placeholder: L("pairing_otp_pin_hint"), maxLength: OneTimeCode.pinLength, secret: true),
                DialogField(icon: Symbols.password, placeholder: L("pairing_otp_passphrase_hint"), maxLength: OneTimeCode.maxPassphraseLength, secret: true),
            ],
            confirm: L("pairing_otp_action")
        ) { [self] values in
            let entry = OneTimeCode.Entry(pin: values[0], passphrase: values[1])
            guard case .code(let code) = entry else {
                feedback?.play(.error)
                toasts.show(L(entry.errorKey ?? ""), icon: Symbols.error)
                return false
            }
            go { navigator.push(.pairCode(hostID: hostID, code: code), focus: "cancel") }
            return true
        })
    }

    /// The PC's name in DELOS on this device: empty returns to the PC's own name.
    private func rename(_ hostID: String) {
        guard let host = hosts.host(hostID) else { return }
        layers.openDialog(DialogSpec(
            title: L("devices_rename_title"), note: L("devices_rename_note", host.serverName),
            fields: [DialogField(icon: Symbols.edit, initial: host.name, maxLength: HostStore.maxNameLength)],
            confirm: L("devices_rename_action")
        ) { [self] values in
            let name = values[0].trimmingCharacters(in: .whitespacesAndNewlines)
            hosts.rename(hostID, to: name)
            feedback?.play(.select)
            toasts.show(name.isEmpty ? L("devices_rename_reset_toast", host.serverName) : L("devices_rename_done_toast", name), icon: Symbols.checkCircle)
            return true
        })
    }

    // MARK: Games

    /// A game's menu in the library (`gameMenu`), depending on what runs on the PC: this game (resume, quit), another
    /// game (quit that one and start this one, or go back to it) or nothing (start). Choosing Quit is the confirmation.
    /// Metadata shows when a metadata service is configured.
    func gameMenu(hostID: String, app: HostApp) -> ContextMenu? {
        guard let host = hosts.host(hostID) else { return nil }
        let running = host.runningAppID == 0 ? nil : hosts.apps[hostID]?.first { $0.id == host.runningAppID }
        let start = { [self] (app: HostApp) in play(hostID: hostID, app: app) }
        var items: [MenuItem]
        if running?.id == app.id {
            items = [
                MenuItem(icon: Symbols.resume, label: L("home_menu_resume")) { start(app) },
                MenuItem(icon: Symbols.powerSettingsNew, label: L("home_menu_quit"), danger: true) { [self] in quit(hostID: hostID, app: app) },
            ]
        } else if let running {
            // The stream quits the running game before it starts this one
            items = [
                MenuItem(icon: Symbols.swapGame, label: L("home_menu_quit_and_start", running.title), danger: true) { start(app) },
                MenuItem(icon: Symbols.resume, label: L("home_menu_resume_other", running.title)) { start(running) },
            ]
        } else {
            items = [MenuItem(icon: Symbols.playArrow, label: L("home_menu_start")) { start(app) }]
        }
        let hidden = isHidden(hostID: hostID, appID: app.id)
        let custom = !gameOverrides(hostID: hostID, appID: app.id).isEmpty
        let other = running.flatMap { $0.id == app.id ? nil : L("home_header_other_running", $0.title) }
        let header = MenuHeader(
            status: running?.id == app.id ? L("home_header_running") : L("home_header_game"), running: running?.id == app.id,
            meta: [other, custom ? L("home_header_custom") : nil, hidden ? L("home_header_hidden") : nil].compactMap { $0 }.reduce(nil) { facts, next in
                facts.map { L("home_meta_join", $0, next) } ?? next
            })
        items.append(MenuItem(icon: Symbols.photoLibrary, label: L("home_menu_artwork")) { [self] in openArtwork(hostID: hostID, app: app) })
        if metadata.offers(app) {
            items.append(MenuItem(icon: Symbols.metadata, label: L("home_menu_metadata")) { [self] in openMetadataMenu(hostID: hostID, app: app) })
        }
        items.append(MenuItem(icon: Symbols.settings, label: L("home_menu_settings")) { [self] in openAppSettings(hostID: hostID, app: app) })
        items.append(
            hidden
                ? MenuItem(icon: Symbols.visibility, label: L("home_menu_show")) { [self] in setHidden(false, hostID: hostID, app: app) }
                : MenuItem(icon: Symbols.visibilityOff, label: L("home_menu_hide")) { [self] in setHidden(true, hostID: hostID, app: app) })
        return ContextMenu(title: app.title, items: items, header: header, initialRow: running != nil && running?.id != app.id ? 1 : 0)
    }

    // MARK: Hiding games

    /// Hidden games of the current profile and the side menu's switch that shows them.
    let hiding = HiddenLibrary()

    func isHidden(hostID: String, appID: Int) -> Bool {
        hiding.ids(profile: profiles.current?.id, hostID: hostID).contains(appID)
    }

    /// The pills on [appID]'s cover.
    func marks(hostID: String, appID: Int) -> [CoverMark] {
        (isHidden(hostID: hostID, appID: appID) ? [.hidden] : []) + (gameOverrides(hostID: hostID, appID: appID).isEmpty ? [] : [.custom])
    }

    /// Hides or shows [app] (`onHide` of `HomeScreen.kt`); hiding says where the game can be found again.
    private func setHidden(_ hidden: Bool, hostID: String, app: HostApp) {
        hiding.set(hidden, appID: app.id, profile: profiles.current?.id, hostID: hostID)
        if hidden { toasts.show(L("home_hidden_toast", app.title), icon: Symbols.visibilityOff) }
    }

    /// The side menu's "Show hidden apps" row for the open library, nil when it has none.
    func hiddenRow(pcName: String?) -> SideMenu.HiddenRow? {
        let apps = libraryHostID.flatMap { hosts.apps[$0] } ?? []
        let hidden = libraryHostID.map { hiding.ids(profile: profiles.current?.id, hostID: $0) } ?? []
        return LibraryHiding.sideRow(count: LibraryHiding.count(apps, hidden: hidden), showing: hiding.showHidden, pcName: pcName)
    }

    private func quit(hostID: String, app: HostApp) {
        let name = hosts.host(hostID)?.name ?? ""
        toasts.show(L("shell_game_quitting", app.title), icon: Symbols.powerSettingsNew)
        Task {
            do {
                try await hosts.quitApp(hostID)
                toasts.show(L("home_quit_done", app.title), icon: Symbols.checkCircle)
            } catch {
                feedback?.play(.error)
                let text = switch error {
                case HostError.hostStatus(599, _): L("home_quit_other_device", app.title)
                case HostError.unreachable, HostError.timedOut: L("devices_unreachable", name)
                default: L("home_quit_failed", app.title)
                }
                toasts.show(text, icon: Symbols.error)
            }
        }
    }

    /// Starts (or resumes) [app]'s stream and remembers when it was started, for the library's order.
    func play(hostID: String, app: HostApp) {
        if let profile = profiles.current?.id { played.markStarted(profile: profile, hostID: hostID, appID: app.id) }
        go { navigator.openStream(hostID: hostID, appID: app.id) }
    }

    /// A (or a tap) on [app]'s cover (`GameTile`'s `activate`): starts or resumes it; while another game runs on the PC
    /// it opens the game's menu instead, whose choices (quit that game and start this one, go back to the running one)
    /// are the confirmation, so a stray press never quits the running game. [focus] is the library's, with [app] focused.
    func activate(hostID: String, app: HostApp, focus: FocusModel) {
        let running = hosts.host(hostID).flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let known = running.flatMap { id in hosts.apps[hostID]?.first { $0.id == id }?.id }
        switch GameActivation.of(app: app.id, running: known) {
        case .start: play(hostID: hostID, app: app)
        case .offerChoices: layers.openContextMenu(of: focus)
        }
    }

    /// The game that has the focus in a PC's library, kept when the library is left (Settings, Profile, Devices or a
    /// stream open above it) and for its next opening (`ShellState.homeGame`): the cover's own registration goes away
    /// with its screen, this does not.
    private var homeGames: [String: Int] = [:]

    func homeGame(hostID: String) -> Int? { homeGames[hostID] }

    func rememberHomeGame(hostID: String, appID: Int) { homeGames[hostID] = appID }

    /// [apps] without the hidden ones (unless the side menu shows them), in the library's order (`PcRepository.order`):
    /// the running game, the played ones from the most recent, then the others in the PC's order.
    func libraryOrder(hostID: String, apps all: [HostApp]) -> [HostApp] {
        let apps = LibraryHiding.visible(all, hidden: hiding.ids(profile: profiles.current?.id, hostID: hostID), showHidden: hiding.showHidden)
        let running = hosts.host(hostID).flatMap { $0.runningAppID == 0 ? nil : $0.runningAppID }
        let times = profiles.current.map { played.times(profile: $0.id, hostID: hostID) } ?? [:]
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return PlayedGames.order(apps.map(\.id), played: times, running: running).compactMap { byID[$0] }
    }

    /// The game last started on the PC in the current profile.
    func lastPlayed(hostID: String) -> Int? {
        profiles.current.flatMap { played.last(profile: $0.id, hostID: hostID) }
    }

    /// The streaming time of an app in the current profile.
    func playtime(hostID: String, appID: Int) -> Playtime {
        profiles.current.map { playtimes.playtime(profile: $0.id, hostID: hostID, appID: appID) } ?? .none
    }

    // MARK: Artwork

    /// The SteamGridDB API key row's dialog (`covers_sgdb_key`): the key is kept in the Keychain; an empty one turns
    /// SteamGridDB off.
    func openSteamGridDBKeyDialog() {
        layers.openDialog(DialogSpec(
            title: L("settings_native_sgdb_key_title"), note: L("settings_native_sgdb_key_note"),
            fields: [DialogField(icon: Symbols.key, initial: artwork.apiKey, placeholder: L("settings_native_sgdb_key_placeholder"),
                                 maxLength: 64, secret: true)],
            confirm: L("settings_native_sgdb_key_save")
        ) { [self] values in
            do {
                try artwork.setAPIKey(values[0])
            } catch {
                feedback?.play(.error)
                toasts.show(L("artwork_error_save_failed"), icon: Symbols.error)
                return false
            }
            toasts.show(artwork.enabled ? L("settings_native_sgdb_key_saved_toast") : L("settings_native_sgdb_off_toast"), icon: Symbols.checkCircle)
            return true
        })
    }

    /// The PC whose library is open below the current screen.
    var libraryHostID: String? {
        for entry in navigator.stack.reversed() {
            if case .home(let hostID) = entry.screen { return hostID }
        }
        return nil
    }

    /// Downloads the best-rated artwork of the open library's games (`downloadAll`): the games never looked up, or all
    /// of them again with [refresh]. [quiet]: the library's own background download, which reports only failures.
    func downloadArtwork(hostID: String?, refresh: Bool, quiet: Bool = false) async {
        guard let hostID, let apps = hosts.apps[hostID] else {
            if !quiet { toasts.show(L("settings_native_connect_first_toast"), icon: Symbols.error) }
            return
        }
        if quiet, !artwork.lookupExpected { return }
        let name = hosts.host(hostID)?.name ?? ""
        if !quiet { toasts.show(L("settings_native_downloading_toast", name), icon: Symbols.download) }
        do {
            let found = try await artwork.downloadAll(hostID: hostID, apps: apps.map { ($0.id, $0.title) }, refresh: refresh)
            guard !quiet else { return }
            toasts.show(found == 0 && !refresh ? L("settings_native_artwork_complete_toast") : LPlural("settings_native_artwork_ready_toast", found),
                        icon: Symbols.checkCircle)
        } catch let error as SteamGridDBError {
            feedback?.play(.error)
            toasts.show(error.text, icon: Symbols.error)
        } catch {
            feedback?.play(.error)
            toasts.show(L("artwork_unreachable"), icon: Symbols.error)
        }
    }

    // MARK: Profiles

    /// The profiles to switch to, the current one checked, and a new one (`profilesMenu`).
    func profilesMenu() -> ContextMenu {
        let current = profiles.current?.id
        let items = profiles.profiles.all.map { profile in
            MenuItem(icon: profile.id == current ? Symbols.check : Symbols.accountCircle, label: profile.name) { [self] in
                guard profile.id != current else { return }
                profiles.switchTo(profile.id)
                toasts.show(L("profile_playing_as", profile.name), icon: Symbols.accountCircle)
            }
        } + [MenuItem(icon: Symbols.personAdd, label: L("profile_new")) { [self] in
            go { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) }
        }] + touchShortcuts
        return ContextMenu(title: L("profile_menu_title"), items: items, below: true)
    }

    /// On iPhone, iPad, Mac and Apple TV the profile and the settings are also in this menu. Android reaches them from the
    /// start screen with the left menu button only; without a controller (a touch user, the Siri Remote, which has no
    /// such button) and without a paired PC, there was no way to Settings (the library's top navigation is the other
    /// way in).
    private var touchShortcuts: [MenuItem] {
        #if os(iOS) || os(macOS) || os(tvOS)
        [
            MenuItem(icon: Symbols.accountCircle, label: L("shell_nav_profile")) { [self] in
                go { navigator.openFromNavigation(.profile, focus: "change-avatar") }
            },
            MenuItem(icon: Symbols.settings, label: L("shell_nav_settings")) { [self] in
                go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) }
            },
        ]
        #else
        []
        #endif
    }

    /// Rename on the profile screen: the profile name dialog.
    func renameProfile() {
        guard let profile = profiles.current else { return }
        openProfileNameDialog(title: L("profile_rename_title"), initial: profile.name) { [self] name in
            profiles.rename(profile.id, to: name)
            toasts.show(L("profile_renamed"), icon: Symbols.checkCircle)
        }
    }

    /// The one dialog a profile's name is typed in (`openProfileNameDialog`). A blank name is refused with a toast;
    /// [onName] gets the accepted name.
    func openProfileNameDialog(title: String, initial: String, onName: @escaping @MainActor (String) -> Void) {
        layers.openDialog(DialogSpec(
            title: title, note: L("profile_name_note"),
            fields: [DialogField(icon: Symbols.badge, initial: initial, maxLength: Profile.maxNameLength)],
            confirm: L("profile_name_save")
        ) { [self] values in
            guard let name = Profile.cleanName(values[0]) else {
                feedback?.play(.error)
                toasts.show(L("profile_name_required"), icon: Symbols.badge)
                return false
            }
            onName(name)
            return true
        })
    }

    /// Create / Save on the profile page (`CreateProfileScreen`'s `onDone` in `Shell.kt`), acknowledged in a toast. A
    /// profile made in the first run goes on to pairing, unless PCs are paired already (then to the start screen); one
    /// added or changed from the profile screen returns there.
    func profileDone(editing: Bool, name: String, avatar: Int) {
        if editing {
            if let id = profiles.current?.id { _ = profiles.update(id, name: name, avatar: avatar) }
            toasts.show(L("shell_profile_updated"), icon: Symbols.checkCircle)
            go { navigator.back() }
            return
        }
        _ = profiles.create(name: name, avatar: avatar)
        toasts.show(L("shell_welcome", name), icon: Symbols.wavingHand, kind: .success)
        let landing = FirstRunLanding.after(fromBoot: navigator.stack.contains { $0.screen == .boot }, pairedPCs: !hosts.paired.isEmpty)
        go {
            switch landing {
            case .pair:
                navigator.reset(to: .start, focus: startFocus())
                navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts))
            case .start: navigator.reset(to: .start, focus: startFocus())
            case .back: navigator.back()
            }
        }
    }

    /// Settings → About → "Replay the welcome": the boot screen again above Settings (B returns to it). Profiles and paired
    /// PCs are kept; going on creates one more profile and ends at the start screen.
    func replayWelcome() {
        go { navigator.push(.boot, focus: "begin") }
    }

    /// "Skip to home" on the boot screen (shown only when PCs are paired already): a default profile, then straight
    /// into the library of the first online paired PC, else the first one.
    func skipBoot() {
        let paired = hosts.paired.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard let host = paired.first(where: { $0.reachability == .online }) ?? paired.first else { return }
        let player = Avatar.all.firstIndex { $0.name == "Player" } ?? 0
        _ = profiles.create(name: L("shell_default_profile_name"), avatar: player)
        go {
            navigator.reset(to: .start, focus: startFocus())
            navigator.openHome(hostID: host.id)
        }
    }

    /// Deletes the current profile at once (`deleteProfile`): choosing Delete is the confirmation. The toast undoes it
    /// with Y or a tap while its settings are kept; the next profile takes over, or the first run starts again.
    func deleteProfile() {
        guard let profile = profiles.current else { return }
        let another = profiles.delete(profile.id)
        let undo = ToastAction(label: L("profile_undo")) { [self] in
            if profiles.undoDelete(profile.id) {
                toasts.show(L("profile_restored", profile.name), icon: Symbols.checkCircle)
                // The first-run screens make no sense with a profile again
                switch navigator.current {
                case .boot, .createProfile: go { navigator.reset(to: .start, focus: startFocus()) }
                default: break
                }
            } else {
                feedback?.play(.error)
                toasts.show(L("profile_restore_failed", profile.name), icon: Symbols.error)
            }
        }
        toasts.show(L("profile_deleted", profile.name), icon: Symbols.delete, action: undo)
        go { another ? navigator.reset(to: .start, focus: startFocus()) : navigator.reset(to: .boot, focus: "begin") }
    }
}
