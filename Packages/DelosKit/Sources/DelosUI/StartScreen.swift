import DelosData
import DelosHost
import DelosInput
import SwiftUI

/// The start screen (`StartScreen` in DELOS for Android's DeviceScreens.kt): the greeting, the current profile's chip at
/// the top, every paired PC in a circle with its status (the default one marked), and the circle that pairs a new PC.
/// Showing it starts looking for PCs and asks the paired ones again. The chip opens the profiles menu; a PC's context
/// menu makes it the default, wakes it or renames it.
struct StartScreen: View {
    let focus: FocusModel
    let profile: Profile?
    /// The current profile's default PC.
    let defaultPC: String?
    let actions: ShellActions
    let onPC: @MainActor (HostRecord) -> Void
    let onPair: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage

    /// The focus id of a PC's circle.
    static func pcID(_ hostID: String) -> String { "pc-\(hostID)" }

    /// The line under a paired PC (`pcStatus`): online, asleep (it can be woken: its MAC address is known) or offline,
    /// and whether it is the default one.
    nonisolated static func status(_ host: HostRecord, isDefault: Bool) -> String {
        let status = host.reachability == .online ? L("devices_status_online")
            : host.macAddress != nil ? L("devices_status_asleep_wakes") : L("devices_status_offline")
        return isDefault ? L("devices_status_with_default", status, L("devices_status_default")) : status
    }

    var body: some View {
        ZStack(alignment: .top) {
            circles.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let profile {
                FocusItem(
                    id: "profile", model: focus, menu: { actions.profilesMenu() },
                    action: { actions.layers.openContextMenu(of: focus) }
                ) { focused in
                    ProfileChip(profile: profile, focused: focused)
                }
                .tvFocusSection()
                .padding(.top, stage.px(44 + stage.safe.top))
            }
        }
        .onAppear { hosts.startDiscovery() }
        .task {
            let ids = hosts.paired.map(\.id)
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { await hosts.refresh(id) } }
            }
        }
    }

    private var circles: some View {
        let paired = hosts.paired.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return VStack(spacing: stage.px(48)) {
            Heading(
                title: profile.map { L("devices_start_greeting", $0.name) } ?? L("devices_start_welcome"),
                sub: paired.isEmpty ? L("devices_start_pair_note") : L("devices_start_choose_note")
            )
            .staggerEntrance()
            CircleRow {
                ForEach(paired, id: \.id) { host in
                    FocusItem(id: Self.pcID(host.id), model: focus, menu: { actions.startMenu(host.id) }, action: { onPC(host) }) { focused in
                        CircleItem(
                            icon: Symbols.desktopWindows, label: host.name, meta: Self.status(host, isDefault: host.id == defaultPC),
                            metaDot: host.reachability == .online ? .onlineGreen : nil, selected: host.id == defaultPC, focused: focused
                        )
                    }
                    .staggerEntrance()
                }
                FocusItem(id: "pair", model: focus, action: onPair) { focused in
                    CircleItem(
                        icon: Symbols.addLink,
                        label: L("devices_pair_new"),
                        meta: L("devices_pair_new_meta"),
                        focused: focused
                    )
                }
                .staggerEntrance()
            }
        }
        .entranceScope()
    }
}

/// The root of the interface: background, status bar and the current screen of the ``Navigator``, on the 1920 × 1080
/// stage. Without a profile it shows the first run; the appearance is the current profile's. It owns the one
/// `HostStore` and puts it, and the navigator, in the environment.
public struct DelosRoot: View {
    @State private var profiles: ProfileStore
    @State private var navigator: Navigator
    @State private var hosts: HostStore
    @State private var toasts: Toasts
    @State private var layers: Layers
    /// What the context menus and dialogs do.
    @State private var actions: ShellActions
    /// The library's artwork and the focused game's background.
    @State private var homeArt: HomeArt
    /// What the library knows about its games from the metadata service (off without one).
    @State private var metadata: GameMetadataModel
    @State private var appearance: Appearance
    @State private var input: MenuInput?
    @State private var feedback: Feedback?
    @State private var videoCoversBackdrop = false
    /// The side menu's focus while it is open.
    @State private var sideMenu: FocusModel?
    /// The battery and the network for the status bar.
    @State private var device = DeviceStatus()
    private let appearances = AppearanceStore()
    private let streamSettings = StreamSettingsStore()
    /// The tab Settings opens with (debug builds: `-DelosSettings <tab>`).
    private let settingsTab: SettingsTab?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if os(tvOS)
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus
    #endif

    public init() {
        let profiles = ProfileStore()
        let hosts = HostStore()
        let toasts = Toasts()
        let layers = Layers()
        _profiles = State(initialValue: profiles)
        _hosts = State(initialValue: hosts)
        _toasts = State(initialValue: toasts)
        _layers = State(initialValue: layers)
        let navigator = Navigator(root: .boot, focus: "begin")
        let homeArt = HomeArt(artwork: ArtworkStore())
        _homeArt = State(initialValue: homeArt)
        let metadata = GameMetadataModel()
        _metadata = State(initialValue: metadata)
        let actions = ShellActions(navigator: navigator, hosts: hosts, profiles: profiles, toasts: toasts, layers: layers, artwork: homeArt.artwork,
                                   metadata: metadata)
        _actions = State(initialValue: actions)
        if !profiles.isFirstRun { navigator.reset(to: .start, focus: actions.startFocus()) }
        var appearance = profiles.current.map { AppearanceStore().load(profile: $0.id) } ?? Appearance()
        var settingsTab: SettingsTab?
        #if DEBUG
        // Screenshots (docs/BUILDING.md): -DelosBackground <kind>, -DelosTheme light, -DelosPalette <name>,
        // -DelosScale <percent>, -DelosClock <system|h12|h24>, and -DelosSettings <tab> opens Settings on that tab,
        // focused on its first row or on -DelosFocus <row id>
        let defaults = UserDefaults.standard
        if let kind = defaults.string(forKey: "DelosBackground").flatMap(BackgroundKind.init(rawValue:)) {
            appearance.background = kind
        }
        if defaults.string(forKey: "DelosTheme") == "light" { appearance.dark = false }
        if let palette = defaults.string(forKey: "DelosPalette").flatMap(PaletteName.init(rawValue:)) {
            appearance.palette = palette
        }
        if defaults.object(forKey: "DelosScale") != nil { appearance.uiScale = defaults.integer(forKey: "DelosScale") }
        if let clock = defaults.string(forKey: "DelosClock").flatMap(ClockFormat.init(rawValue:)) { appearance.clock = clock }
        if let name = defaults.string(forKey: "DelosSettings"), let tab = SettingsTab.allCases.first(where: { "\($0)" == name }),
           !profiles.isFirstRun {
            settingsTab = tab
            navigator.openFromNavigation(.settings, focus: defaults.string(forKey: "DelosFocus") ?? SettingsScreen.firstRow(tab))
        }
        #endif
        _navigator = State(initialValue: navigator)
        _appearance = State(initialValue: appearance)
        self.settingsTab = settingsTab
    }

    private var colors: DelosColors {
        DelosColors(palette: Palette(rawValue: appearance.palette.rawValue) ?? .delos, dark: appearance.dark)
    }

    public var body: some View {
        StageReader(textScale: Double(appearance.uiScale) / 100) {
            ZStack {
                // The game background shows only behind the library (`ShellBackdrop`'s heroShown)
                if !videoCoversBackdrop { Backdrop(appearance: appearance, hero: showsLibrary ? homeArt.hero : nil) }
                let entry = navigator.stack[navigator.stack.count - 1]
                screen(entry)
                    .id(ObjectIdentifier(entry.focus))
                    .transition(ScreenMotion.transition(reduced: systemReduceMotion || appearance.reducedMotion))
                if case .stream = navigator.current {} else {
                    TopBar(
                        brand: navigator.current != .start, navigation: navigation(entry),
                        pc: navigator.current.showsNavigation ? connectedPC : nil, wifi: device.wifi, battery: device.battery,
                        clock: appearance.clock, onBack: navigator.canGoBack ? { go { navigator.back() } } : nil)
                        // The interface scale zooms the whole bar
                        .modifier(ZoomedBar())
                        // The navigation's buttons belong to the focus of the screen shown
                        .id(ObjectIdentifier(entry.focus))
                }
                if let sideMenu {
                    SideMenu(
                        profile: profiles.current, pc: connectedPC, focus: sideMenu, appearance: appearance, onStep: { id, direction in _ = quickStep(id, by: direction) },
                        onSettings: {
                            closeSideMenu(sound: nil)
                            go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) }
                        },
                        onClose: { closeSideMenu(sound: .back) })
                }
                LayerHost(layers: layers, navigator: navigator)
                ToastHost(toasts: toasts)
            }
        }
        .onPreferenceChange(VideoCoversBackdrop.self) { videoCoversBackdrop = $0 }
        .environment(hosts)
        .environment(homeArt)
        .environment(metadata)
        .environment(navigator)
        .environment(layers)
        .environment(toasts)
        .environment(\.modalFocus, sideMenu ?? (layers.isOpen ? layers.focus : nil))
        #if os(tvOS)
        // The focus engine keeps its focus on an item that can no longer take it until the next press: when the focus
        // owner changes (a layer opens or closes, another screen shows), it is asked to look for the preferred item,
        // once the items of the new owner exist
        .focusScope(focusScope)
        .environment(\.focusNamespace, focusScope)
        .task(id: ObjectIdentifier(sideMenu ?? (layers.isOpen ? layers.focus : navigator.focus))) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            resetFocus(in: focusScope)
        }
        #endif
        .environment(\.delosColors, colors)
        .environment(\.reducedMotion, systemReduceMotion || appearance.reducedMotion)
        .environment(\.matchGameColors, appearance.matchGameColors)
        .preferredColorScheme(colors.dark ? .dark : .light)
        .onChange(of: profiles.current?.id) { _, id in
            appearance = id.map { appearances.load(profile: $0) } ?? Appearance()
        }
        .onChange(of: appearance, initial: true) { _, now in
            feedback?.soundsEnabled = now.sounds
            feedback?.hapticsEnabled = now.haptics
        }
        .onAppear { device.start() }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        #if os(tvOS)
        // Menu is back (at the start screen the system's Home), Play/Pause the focused item's context menu; the
        // directions and select are the system focus engine's, a swipe or a direction also reaches `route`
        .onExitCommand(perform: handlesExit ? { route(.back, repeatCount: 0, fromRemote: true) } : nil)
        .onPlayPauseCommand { route(.options, repeatCount: 0, fromRemote: true) }
        .onMoveCommand { routeMove($0) }
        #endif
        .onAppear(perform: startInput)
    }

    /// Whether Menu is ours: a layer or the side menu is open, or there is a screen to go back to. At the first screen it
    /// is the system's (tvOS: Home).
    private var handlesExit: Bool { sideMenu != nil || layers.isOpen || navigator.canGoBack }

    /// The sounds, and the controllers' and keyboards' commands (on tvOS only the ones the system has no event for).
    private func startInput() {
        guard input == nil else { return }
        let feedback = Feedback()
        feedback.soundsEnabled = appearance.sounds
        feedback.hapticsEnabled = appearance.haptics
        self.feedback = feedback
        layers.feedback = feedback
        #if os(tvOS)
        let input = MenuInput(only: MenuInput.tvCommands) { command, repeatCount in route(command, repeatCount: repeatCount) }
        #else
        let input = MenuInput { command, repeatCount in route(command, repeatCount: repeatCount) }
        #endif
        input.start()
        self.input = input
    }

    #if os(tvOS)
    /// A swipe or a controller's direction: the focus engine moves the focus on its own; only a screen that takes
    /// over left and right (the value of a Settings row) gets them first.
    private func routeMove(_ direction: MoveCommandDirection) {
        if let sideMenu, direction == .left || direction == .right {
            adjustQuickSetting(of: sideMenu, direction == .right ? 1 : -1)
            return
        }
        guard sideMenu == nil, !layers.isOpen, !navigator.isEditingText, let capture = navigator.commandCapture else { return }
        switch direction {
        case .left: navigator.commandRepeat = 0; _ = capture(.left)
        case .right: navigator.commandRepeat = 0; _ = capture(.right)
        default: break
        }
    }
    #endif

    /// A controller, keyboard or remote command, to whoever owns it: the side menu, an open layer, the screen that
    /// captures the commands (the stream, Settings), a text field being typed in, else the screen's focus.
    /// [fromRemote]: the Siri Remote's Menu or Play/Pause.
    private func route(_ command: MenuCommand, repeatCount: Int, fromRemote: Bool = false) {
        guard let feedback else { return }
        navigator.commandRepeat = repeatCount
        navigator.commandFromRemote = fromRemote
        if let sideMenu {
            // The side menu takes every command while it is open
            switch command {
            case .back, .menu: closeSideMenu(sound: .back)
            case .accept: feedback.activate(sideMenu.acceptCue) { sideMenu.handle(.accept) }
            case .up, .down: if sideMenu.handle(command) { feedback.play(.move) }
            case .left, .right: adjustQuickSetting(of: sideMenu, command == .right ? 1 : -1)
            case .previousTab, .nextTab, .options, .toastAction: break
            }
            return
        }
        if layers.isOpen {
            // An open layer takes every command; the text field of a dialog takes the keys while it is typed in
            if navigator.isEditingText {
                if command == .back { navigator.isEditingText = false }
            } else if command == .toastAction {
                toasts.runAction()
            } else if command != .accept || !navigator.swallowsAccept() {
                layers.handle(command)
            }
            return
        }
        if let capture = navigator.commandCapture, capture(command) { return }
        if command == .menu, navigator.current.hasSideMenu {
            feedback.play(.open)
            withAnimation(.easeOut(duration: 0.3)) { self.sideMenu = FocusModel(initial: QuickSettings.ids[0]) }
            return
        }
        // While a text field is typed in, the keys belong to it; B and Escape stop typing
        if navigator.isEditingText {
            if command == .back { navigator.isEditingText = false }
            return
        }
        switch command {
        case .toastAction:
            toasts.runAction()
            return
        case .options:
            layers.openContextMenu(of: navigator.focus)
            return
        default:
            break
        }
        if command == .accept, navigator.swallowsAccept() { return }
        if command == .back {
            if navigator.canGoBack {
                feedback.play(.back)
                go { navigator.back() }
            }
            return
        }
        if command == .accept {
            // The item's own cue (a Cancel or Back goes BACK), unless its action played one
            feedback.activate(navigator.focus.acceptCue) { navigator.focus.handle(.accept) }
            return
        }
        guard navigator.focus.handle(command) else { return }
        feedback.play(.move)
    }

    @ViewBuilder private func screen(_ entry: Navigator.Entry) -> some View {
        switch entry.screen {
        case .boot:
            BootScreen(
                focus: entry.focus,
                onBegin: { go { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) } },
                onSkip: bootSkip)
        case .createProfile(let editing):
            CreateProfileScreen(
                editing: editing, initial: editing ? profiles.current : nil, focus: entry.focus, actions: actions
            ) { name, avatar in
                actions.profileDone(editing: editing, name: name, avatar: avatar)
            }
        case .start:
            StartScreen(
                focus: entry.focus, profile: profiles.current, defaultPC: profiles.startup.defaultPC, actions: actions,
                onPC: { host in go { navigator.openHome(hostID: host.id) } },
                onPair: { go { navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts)) } }
            )
        case .profile:
            if let profile = profiles.current {
                ProfileScreen(
                    profile: profile, count: profiles.profiles.all.count, focus: entry.focus, actions: actions,
                    onChangeAvatar: {
                        go { navigator.push(.createProfile(editing: true), focus: CreateProfileScreen.avatarID(Avatar.of(profile.avatar).index)) }
                    },
                    onAdd: { go { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) } }
                )
            }
        case .devices:
            DevicesScreen(
                focus: entry.focus, activeID: actions.libraryHostID, defaultPC: profiles.startup.defaultPC, actions: actions,
                onPair: { go { navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts)) } })
        case .pair:
            PairPCScreen(
                focus: entry.focus,
                onHost: { host in go { host.pin != nil ? navigator.openHome(hostID: host.id) : navigator.push(.pin(hostID: host.id), focus: "cancel") } },
                onCode: { host in actions.pairWithCode(hostID: host.id) },
                onAddress: { go { navigator.push(.pairAddress, focus: "field") } }
            )
        case .pairAddress:
            PairAddressScreen(focus: entry.focus, navigator: navigator, onSubmit: addAndPair)
        case .pin(let hostID):
            pinScreen(hostID: hostID, code: nil, entry: entry)
        case .pairCode(let hostID, let code):
            pinScreen(hostID: hostID, code: code, entry: entry)
        case .home(let hostID):
            HomeScreen(hostID: hostID, focus: entry.focus, actions: actions)
        case .stream(let hostID, let appID):
            StreamScreen(hostID: hostID, appID: appID, settings: streamSettings.load(profile: profiles.current?.id ?? ""))
        case .settings:
            SettingsScreen(
                profileID: profiles.current?.id ?? "", appearance: $appearance, focus: entry.focus, navigator: navigator,
                feedback: feedback, actions: actions, tab: settingsTab)
        }
    }

    private func pinScreen(hostID: String, code: OneTimeCode?, entry: Navigator.Entry) -> some View {
        PinScreen(
            hostID: hostID, code: code, focus: entry.focus, feedback: feedback,
            onPaired: { go { navigator.openHome(hostID: hostID) } },
            onFailed: { message in
                feedback?.play(.error)
                toasts.show(message, icon: Symbols.error)
                go { _ = navigator.back() }
            },
            onCancel: {
                feedback?.play(.back)
                go { _ = navigator.back() }
            }
            )
    }

    private var showsLibrary: Bool {
        if case .home = navigator.current { true } else { false }
    }

    /// The top navigation of the screen [entry] shows, if it has one.
    private func navigation(_ entry: Navigator.Entry) -> TopBar.Navigation? {
        guard entry.screen.showsNavigation else { return nil }
        let buttons = TopNav.buttons(
            current: entry.screen,
            onSettings: { go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) } },
            onProfile: { go { navigator.openFromNavigation(.profile, focus: "change-avatar") } },
            onDevices: { go { navigator.openFromNavigation(.devices, focus: actions.devicesFocus()) } })
        return TopBar.Navigation(buttons: buttons, focus: entry.focus)
    }

    /// "Skip to home" on the boot screen: only when PCs are paired already.
    private var bootSkip: (@MainActor () -> Void)? {
        guard !hosts.paired.isEmpty else { return nil }
        return { actions.skipBoot() }
    }

    /// The PC whose library is open below the current screen, for the side menu.
    private var connectedPC: (name: String, online: Bool)? {
        for entry in navigator.stack.reversed() {
            if case .home(let hostID) = entry.screen, let host = hosts.host(hostID) {
                return (host.name, host.reachability == .online)
            }
        }
        return nil
    }

    private func closeSideMenu(sound: Cue?) {
        if let sound { feedback?.play(sound) }
        withAnimation(.easeOut(duration: 0.24)) { sideMenu = nil }
    }

    /// A quick setting of the side menu stepped (the side menu's rows): applied at once and kept with the current
    /// profile's appearance. False when nothing changed.
    private func quickStep(_ id: String, by direction: Int) -> Bool {
        guard let profile = profiles.current?.id, let next = QuickSettings.step(id, by: direction, from: appearance) else { return false }
        appearance = next
        appearances.save(next, profile: profile)
        return true
    }

    /// Left or right on the side menu's focused row: a quick setting takes the next or the previous value.
    private func adjustQuickSetting(of menu: FocusModel, _ direction: Int) {
        guard let id = menu.focused as? String, quickStep(id, by: direction) else { return }
        feedback?.play(.move)
    }

    /// "Add PC" on the address screen (`addAndPair` of DELOS for Android): asks the address who it is, then pairs with
    /// it, or opens its library when it is paired already. What goes wrong is said in a toast.
    private func addAndPair(_ text: String) {
        let address: HostAddress
        switch AddressEntry(text) {
        case .empty:
            feedback?.play(.error)
            toasts.show(L("devices_address_required"), icon: Symbols.error)
            return
        case .invalid:
            feedback?.play(.error)
            toasts.show(L("devices_add_not_an_address", text.trimmingCharacters(in: .whitespacesAndNewlines)), icon: Symbols.error)
            return
        case .address(let typed):
            address = typed
        }
        navigator.isEditingText = false
        toasts.show(L("devices_address_looking", address.description), icon: Symbols.search)
        Task {
            do {
                let host = try await hosts.ask(address, typed: true)
                go {
                    if host.pin != nil {
                        navigator.openHome(hostID: host.id)
                    } else {
                        _ = navigator.back()
                        navigator.push(.pin(hostID: host.id), focus: "cancel")
                    }
                }
            } catch {
                feedback?.play(.error)
                toasts.show(L("devices_add_no_answer", address.description), icon: Symbols.error)
            }
        }
    }
}

/// Changes the screen with the shared screen transition (`.screen` of the prototype: a fade with a slight zoom).
@MainActor func go(_ change: () -> Void) {
    withAnimation(.easeOut(duration: 0.5), change)
}
