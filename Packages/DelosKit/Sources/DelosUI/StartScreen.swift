import DelosData
import DelosHost
import DelosInput
import SwiftUI

/// The start screen (`StartScreen` in DELOS for Android's DeviceScreens.kt): the greeting, the current profile's chip at
/// the top, every paired PC in a circle with its status, and the circle that pairs a new PC. Showing it starts looking
/// for PCs and asks the paired ones again. The default PC and the PCs' context menu are not ported yet.
///
/// On Android the chip opens the profiles context menu; until context menus exist it opens the profile screen.
struct StartScreen: View {
    let focus: FocusModel
    let profile: Profile?
    let onProfile: @MainActor () -> Void
    let onPC: @MainActor (HostRecord) -> Void
    let onPair: @MainActor () -> Void
    @Environment(HostStore.self) private var hosts
    @Environment(\.stage) private var stage

    /// The focus id of a PC's circle.
    static func pcID(_ hostID: String) -> String { "pc-\(hostID)" }

    /// The string name of the line under a paired PC: online, asleep (it can be woken: its MAC address is known) or
    /// offline.
    static func status(_ host: HostRecord) -> String {
        if host.reachability == .online { return "devices_status_online" }
        return host.macAddress != nil ? "devices_status_asleep" : "devices_status_offline"
    }

    var body: some View {
        ZStack(alignment: .top) {
            circles.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let profile {
                FocusItem(id: "profile", model: focus, action: onProfile) { focused in
                    ProfileChip(profile: profile, focused: focused)
                }
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
            CircleRow {
                ForEach(paired, id: \.id) { host in
                    FocusItem(id: Self.pcID(host.id), model: focus, action: { onPC(host) }) { focused in
                        CircleItem(
                            icon: Symbols.desktopWindows, label: host.name, meta: L(Self.status(host)),
                            metaDot: host.reachability == .online ? .onlineGreen : nil, focused: focused
                        )
                    }
                }
                FocusItem(id: "pair", model: focus, action: onPair) { focused in
                    CircleItem(
                        icon: Symbols.addLink,
                        label: L("devices_pair_new"),
                        meta: L("devices_pair_new_meta"),
                        focused: focused
                    )
                }
            }
        }
    }
}

/// The root of the interface: background, status bar and the current screen of the ``Navigator``, on the 1920 × 1080
/// stage. Without a profile it shows the first run; the appearance is the current profile's. It owns the one
/// `HostStore` and puts it, and the navigator, in the environment.
public struct DelosRoot: View {
    @State private var profiles: ProfileStore
    @State private var navigator: Navigator
    @State private var hosts: HostStore
    @State private var toasts = Toasts()
    @State private var appearance: Appearance
    @State private var input: MenuInput?
    @State private var feedback: Feedback?
    /// The side menu's focus while it is open.
    @State private var sideMenu: FocusModel?
    private let appearances = AppearanceStore()
    private let streamSettings = StreamSettingsStore()

    public init() {
        let profiles = ProfileStore()
        let hosts = HostStore()
        _profiles = State(initialValue: profiles)
        _hosts = State(initialValue: hosts)
        _navigator = State(initialValue: profiles.isFirstRun
            ? Navigator(root: .boot, focus: "begin") : Navigator(root: .start, focus: Self.startFocus(hosts)))
        var appearance = profiles.current.map { AppearanceStore().load(profile: $0.id) } ?? Appearance()
        #if DEBUG
        // Screenshots of each background and theme (docs/BUILDING.md): -DelosBackground <kind>, -DelosTheme light
        let defaults = UserDefaults.standard
        if let kind = defaults.string(forKey: "DelosBackground").flatMap(BackgroundKind.init(rawValue:)) {
            appearance.background = kind
        }
        if defaults.string(forKey: "DelosTheme") == "light" { appearance.dark = false }
        #endif
        _appearance = State(initialValue: appearance)
    }

    private var colors: DelosColors {
        DelosColors(palette: Palette(rawValue: appearance.palette.rawValue) ?? .delos, dark: appearance.dark)
    }

    public var body: some View {
        StageReader {
            ZStack {
                Backdrop(kind: appearance.background)
                let entry = navigator.stack[navigator.stack.count - 1]
                screen(entry)
                    .id(ObjectIdentifier(entry.focus))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.035)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
                if case .stream = navigator.current {} else {
                    TopBar(
                        brand: navigator.current != .start, navigation: navigation(entry),
                        onBack: navigator.canGoBack ? { go { navigator.back() } } : nil)
                        // The navigation's buttons belong to the focus of the screen shown
                        .id(ObjectIdentifier(entry.focus))
                }
                if let sideMenu {
                    SideMenu(
                        profile: profiles.current, pc: connectedPC, focus: sideMenu,
                        onSettings: {
                            closeSideMenu(sound: nil)
                            go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) }
                        },
                        onClose: { closeSideMenu(sound: .back) })
                }
                ToastOverlay(toasts: toasts)
            }
        }
        .environment(hosts)
        .environment(navigator)
        .environment(\.delosColors, colors)
        .preferredColorScheme(colors.dark ? .dark : .light)
        .onChange(of: profiles.current?.id) { _, id in
            appearance = id.map { appearances.load(profile: $0) } ?? Appearance()
        }
        .onChange(of: appearance, initial: true) { _, now in
            feedback?.soundsEnabled = now.sounds
            feedback?.hapticsEnabled = now.haptics
        }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        #if os(tvOS)
        .onExitCommand(perform: navigator.canGoBack ? { go { navigator.back() } } : nil)
        #else
        .onAppear {
            let feedback = Feedback()
            feedback.soundsEnabled = appearance.sounds
            feedback.hapticsEnabled = appearance.haptics
            self.feedback = feedback
            let input = MenuInput { [navigator, feedback] command, repeatCount in
                navigator.commandRepeat = repeatCount
                if let sideMenu {
                    // The side menu takes every command while it is open
                    switch command {
                    case .back, .menu: closeSideMenu(sound: .back)
                    case .up, .down, .accept: if sideMenu.handle(command) { feedback.play(command == .accept ? .select : .move) }
                    case .left, .right, .previousTab, .nextTab: break
                    }
                    return
                }
                if let capture = navigator.commandCapture, capture(command) { return }
                if command == .menu, navigator.current.hasSideMenu {
                    feedback.play(.open)
                    withAnimation(.easeOut(duration: 0.3)) { self.sideMenu = FocusModel(initial: SideMenu.settingsID) }
                    return
                }
                // While a text field is typed in, the keys belong to it; B and Escape stop typing
                if navigator.isEditingText {
                    if command == .back { navigator.isEditingText = false }
                    return
                }
                if command == .accept, navigator.swallowsAccept() { return }
                if command == .back {
                    if navigator.canGoBack {
                        feedback.play(.back)
                        go { navigator.back() }
                    }
                    return
                }
                guard navigator.focus.handle(command) else { return }
                feedback.play(command == .accept ? .select : .move)
            }
            input.start()
            self.input = input
        }
        #endif
    }

    @ViewBuilder private func screen(_ entry: Navigator.Entry) -> some View {
        switch entry.screen {
        case .boot:
            BootScreen(focus: entry.focus, onBegin: { go { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) } })
        case .createProfile(let editing):
            CreateProfileScreen(
                editing: editing, initial: editing ? profiles.current : nil, focus: entry.focus, navigator: navigator,
                feedback: feedback
            ) { name, avatar in
                profileDone(editing: editing, name: name, avatar: avatar)
            }
        case .start:
            StartScreen(
                focus: entry.focus, profile: profiles.current,
                onProfile: { go { navigator.push(.profile, focus: "change-avatar") } },
                onPC: { host in go { navigator.openHome(hostID: host.id) } },
                onPair: { go { navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts)) } }
            )
        case .profile:
            if let profile = profiles.current {
                ProfileScreen(
                    profile: profile, count: profiles.profiles.all.count, focus: entry.focus,
                    onChangeAvatar: {
                        go { navigator.push(.createProfile(editing: true), focus: CreateProfileScreen.avatarID(Avatar.of(profile.avatar).index)) }
                    },
                    onAdd: { go { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) } },
                    onDelete: {
                        // Choosing Delete is the confirmation; without a profile left the first run starts again
                        let another = profiles.remove(profile.id)
                        go { another ? navigator.reset(to: .start, focus: Self.startFocus(hosts)) : navigator.reset(to: .boot, focus: "begin") }
                    }
                )
            }
        case .pair:
            PairPCScreen(
                focus: entry.focus,
                onHost: { host in go { host.pin != nil ? navigator.openHome(hostID: host.id) : navigator.push(.pin(hostID: host.id), focus: "cancel") } },
                onAddress: { go { navigator.push(.pairAddress, focus: "field") } }
            )
        case .pairAddress:
            PairAddressScreen(focus: entry.focus, navigator: navigator, onSubmit: addAndPair)
        case .pin(let hostID):
            PinScreen(
                hostID: hostID, focus: entry.focus, feedback: feedback,
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
        case .home(let hostID):
            HomeScreen(hostID: hostID, focus: entry.focus) { app in
                go { navigator.openStream(hostID: hostID, appID: app.id) }
            }
        case .stream(let hostID, let appID):
            StreamScreen(hostID: hostID, appID: appID, settings: streamSettings.load(profile: profiles.current?.id ?? ""))
        case .settings:
            SettingsScreen(profileID: profiles.current?.id ?? "", focus: entry.focus, navigator: navigator, feedback: feedback)
        }
    }

    /// The top navigation of the screen [entry] shows, if it has one.
    private func navigation(_ entry: Navigator.Entry) -> TopBar.Navigation? {
        guard entry.screen.showsNavigation else { return nil }
        let buttons = TopNav.buttons(
            current: entry.screen,
            onSettings: { go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) } },
            onProfile: { go { navigator.openFromNavigation(.profile, focus: "change-avatar") } })
        return TopBar.Navigation(buttons: buttons, focus: entry.focus)
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

    /// The start screen's first focus: the first paired PC that is online, else the first one, else "Pair a new PC".
    static func startFocus(_ hosts: HostStore) -> String {
        let paired = hosts.paired.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return (paired.first { $0.reachability == .online } ?? paired.first).map { StartScreen.pcID($0.id) } ?? "pair"
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

    /// Create / Save on the profile page. A profile made in the first run goes on to pairing (the start screen below
    /// it); one added or changed from the profile screen returns there.
    private func profileDone(editing: Bool, name: String, avatar: Int) {
        if editing {
            if let id = profiles.current?.id { profiles.update(id, name: name, avatar: avatar) }
            go { navigator.back() }
            return
        }
        profiles.create(name: name, avatar: avatar)
        go {
            if navigator.stack.first?.screen == .boot {
                navigator.reset(to: .start, focus: Self.startFocus(hosts))
                navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts))
            } else {
                navigator.back()
            }
        }
    }
}

/// Changes the screen with the shared screen transition (`.screen` of the prototype: a fade with a slight zoom).
@MainActor private func go(_ change: () -> Void) {
    withAnimation(.easeOut(duration: 0.5), change)
}

/// The status bar: the brand at the top left, 72 stage pixels from the side, in a 104 px high bar, and on the screens of
/// the top navigation its buttons in the middle. The start screen leaves the brand out: the profile chip is at the top
/// there.
struct TopBar: View {
    /// The buttons of the top navigation and the focus they belong to.
    struct Navigation {
        let buttons: [NavButton]
        let focus: FocusModel
    }

    var brand = true
    var navigation: Navigation?
    /// Shown on iPhone and iPad when the screen can go back: a touch user has no B button and the system has no back
    /// gesture of its own (on Android the system's back does it, so DELOS for Android has no such button).
    var onBack: (() -> Void)?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors

    var body: some View {
        VStack {
            ZStack {
                HStack(spacing: stage.px(24)) {
                    #if os(iOS)
                    if let onBack {
                        Button(action: onBack) {
                            SymbolView(symbol: Symbols.arrowBack, size: 34, color: colors.text)
                                .frame(width: stage.px(68), height: stage.px(68))
                                .background(GlassShape(Circle(), tint: colors.surface))
                                .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L("shell_hint_back"))
                    }
                    #endif
                    if brand { Brand() }
                    Spacer()
                }
                if let navigation { TopNav(buttons: navigation.buttons, focus: navigation.focus) }
            }
            .frame(height: stage.px(104))
            .padding(.top, stage.px(stage.safe.top))
            .padding(.leading, stage.px(72 + stage.safe.leading))
            .padding(.trailing, stage.px(72 + stage.safe.trailing))
            Spacer()
        }
    }
}
