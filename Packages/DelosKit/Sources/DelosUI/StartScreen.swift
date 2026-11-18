import DelosCore
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
    @Environment(\.statusBarEdges) private var statusEdges

    private var initialPC: String {
        let paired = hosts.paired.sorted { $0.name.lowercased() < $1.name.lowercased() }
        let host = paired.first { $0.id == defaultPC } ?? paired.first { $0.reachability == .online } ?? paired.first
        return host.map { Self.pcID($0.id) } ?? "pair"
    }

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
                .modifier(ProfileChipPosition(stage: stage, rightStart: statusEdges?.rightStart))
            }
        }
        .onAppear { hosts.startDiscovery() }
        .onChange(of: initialPC) { _, next in focus.focus(next) }
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
    /// Who the controller's and keyboard's commands belong to, and the side menu they may open.
    @State private var router: ShellRouter
    /// The battery and the network for the status bar.
    @State private var device = DeviceStatus()
    @State private var statusEdges = StatusBarEdges()
    private let appearances = AppearanceStore()
    private let streamSettings = StreamSettingsStore()
    /// The tab Settings opens with (debug builds: `-DelosSettings <tab>`).
    private let settingsTab: SettingsTab?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    #if os(tvOS)
    @Namespace private var focusScope
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @Environment(\.scenePhase) private var scenePhase

    public init() {
        #if DEBUG
        // -DelosDemo: a separate suite, so the app's own profiles and PCs are never read or written
        let profiles = DemoHarness.on ? ProfileStore(suiteName: DemoHarness.suite) : ProfileStore()
        let hosts = DemoHarness.on ? HostStore(defaults: UserDefaults(suiteName: DemoHarness.suite) ?? .standard) : HostStore()
        if DemoHarness.on { DemoHarness.seed(hosts: hosts, profiles: profiles) }
        #else
        let profiles = ProfileStore()
        let hosts = HostStore()
        #endif
        let toasts = Toasts()
        let layers = Layers()
        _profiles = State(initialValue: profiles)
        _hosts = State(initialValue: hosts)
        _toasts = State(initialValue: toasts)
        _layers = State(initialValue: layers)
        let navigator = Navigator(root: .boot, focus: "begin")
        #if DEBUG
        let homeArt = HomeArt(artwork: DemoHarness.on ? DemoHarness.artwork() : ArtworkStore())
        #else
        let homeArt = HomeArt(artwork: ArtworkStore())
        #endif
        _homeArt = State(initialValue: homeArt)
        #if DEBUG
        let metadata = DemoHarness.on ? GameMetadataModel(store: DemoHarness.metadataStore()) : GameMetadataModel()
        #else
        let metadata = GameMetadataModel()
        #endif
        _metadata = State(initialValue: metadata)
        let actions = ShellActions(navigator: navigator, hosts: hosts, profiles: profiles, toasts: toasts, layers: layers, artwork: homeArt.artwork,
                                   metadata: metadata)
        _actions = State(initialValue: actions)
        _router = State(initialValue: ShellRouter(navigator: navigator, layers: layers, toasts: toasts, actions: actions))
        if !profiles.isFirstRun { navigator.reset(to: .start, focus: actions.startFocus()) }
        #if DEBUG
        if DemoHarness.on {
            DemoHarness.navigate(navigator, actions: actions)
            DemoHarness.forceInput()
        }
        #endif
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
        // -DelosScreen create | profile opens the screen of a profile (Profile needs a profile): screenshots of its layout
        switch defaults.string(forKey: "DelosScreen") {
        case "create": navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0))
        case "profile" where !profiles.isFirstRun: navigator.openFromNavigation(.profile, focus: "change-avatar")
        default: break
        }
        #endif
        _navigator = State(initialValue: navigator)
        _appearance = State(initialValue: appearance)
        self.settingsTab = settingsTab
    }

    /// The side menu's focus while it is open.
    private var sideMenu: FocusModel? { router.sideMenu }
    /// The side menu's opening progress while a touch drag owns it (nil: the panel and the scrim run their transitions).
    private var sideProgress: Double? { router.sideDrag.engaged ? router.sideDrag.progress : nil }

    /// The palette's colors, or the system's with Material You colors (Mac).
    private var colors: DelosColors { DelosColors(appearance) }

    public var body: some View {
        StageReader(textScale: Double(appearance.uiScale) / 100) {
            ZStack {
                ZStack {
                    // The game background shows only behind the library (`ShellBackdrop`'s heroShown)
                    // The library's filter sheet is a layer of Android's shell: its scrim covers the bar too (the screen is raised
                    // while the sheet is open) and the backdrop and the bar blur under it like the screen does
                    if !videoCoversBackdrop {
                        // An animated game background pauses while the portal into a PC is up (`animate`)
                        ShellBackdrop(appearance: appearance, showsLibrary: showsLibrary, animate: actions.connection.portal == nil)
                            .modifier(LayerBackdropBlur(active: librarySheetOpen))
                    }
                    let entry = navigator.stack[navigator.stack.count - 1]
                    screen(entry)
                        .id(ObjectIdentifier(entry.focus))
                        .transition(ScreenMotion.transition(reduced: systemReduceMotion || appearance.reducedMotion))
                        .zIndex(librarySheetOpen ? 1 : 0)
                    if !navigator.current.hidesChrome {
                        TopBar(
                            brand: navigator.current != .start, navigation: navigation(entry),
                            pc: navigator.current.showsNavigation ? connectedPC : nil, wifi: device.wifi, battery: device.battery,
                            clock: appearance.clock, onBack: navigator.canGoBack ? { feedback?.play(.back); go { navigator.back() } } : nil)
                            // The interface scale zooms the whole bar
                            .modifier(ZoomedBar())
                            .modifier(LayerBackdropBlur(active: librarySheetOpen))
                            // The navigation's buttons belong to the focus of the screen shown
                            .id(ObjectIdentifier(entry.focus))
                    }
                }
                .modifier(PortalBackdropBlur(active: actions.connection.portal.map { !$0.arriving } ?? false))
                // The scrim of the side menu or a dialog blurs the screen under it; while a touch drag moves the side menu, by
                // its progress
                .modifier(LayerBackdropBlur(active: sideMenu != nil || layers.blursScreen, progress: sideProgress))
                #if os(iOS)
                // Touch: a drag in from the left edge opens the side menu (the controller's left menu button) and the panel
                // follows the finger
                if router.sideSwipeOpens {
                    SideMenuEdgeStrip(router: router)
                }
                #endif
                if let sideMenu {
                    // A group, not a stack: the scrim and the panel keep their own transitions
                    Group {
                        LayerScrim(progress: sideProgress, onTap: { router.closeSideMenu(sound: .back) })
                        SideMenu(
                            profile: profiles.current, pc: sidePC, playtime: router.sidePlaytime, focus: sideMenu, appearance: appearance, onStep: { id, direction in _ = quickStep(id, by: direction) },
                            onSettings: {
                                router.closeSideMenu(sound: nil)
                                go { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) }
                            },
                            hidden: actions.hiddenRow(pcName: connectedPC?.name), progress: sideProgress)
                    }
                    #if os(iOS)
                    // Touch: a drag to the left on the open menu closes it, the panel following the finger
                    .modifier(SideMenuSwipeGesture(opening: false, router: router))
                    #endif
                }
                LayerHost(layers: layers, navigator: navigator)
                // A problem of the last run or a failed stream: the offer to report it, on the start and home screens
                ProblemOfferCard(
                    offers: ProblemOffers.shared, shown: offerShown,
                    onReport: { mode in
                        ProblemOffers.shared.report(
                            mode, export: DiagnosticsExport(hosts: hosts, profiles: profiles, artwork: homeArt.artwork), toasts: toasts,
                            feedback: feedback)
                    },
                    onDismiss: { ProblemOffers.shared.dismiss() })
                // Downloading artwork or looking up metadata: above the button hints on every screen (`ArtworkProgressBar`)
                ShellProgressPill(shown: ShellProgress.shown(
                    artwork: actions.artwork.progress.map { ShellProgress(done: $0.done, total: $0.total) }, metadata: metadata.progress))
                // The hint bar is above the scrim and the layers, crisp (Android's `HintBar` follows `Scrim` in `Shell`)
                // Over a stream only the result of a failed one has hints (`hints` while `shell.result` is up); the controls' preview has none
                if case .stream = navigator.current, !navigator.screenHints.streamResult {} else if navigator.current == .oscPreview {} else {
                    ShellHintBar(
                        hints: hints, note: libraryNote, noteLabel: libraryNote == nil ? nil : L("shell_hint_library_label"),
                        libraryRow: showsLibraryRow,
                        // The only tappable hint is the library's Filter: the screen's own Y
                        onTap: { _ in _ = navigator.commandCapture?(.toastAction) })
                }
                ZStack {
                    if let portal = actions.connection.portal {
                        PortalOverlay(portal: portal, burst: actions.connection.burst, focus: router.portalFocus, onCancel: { actions.connection.cancel() })
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: portal.arriving ? PortalLook.fadeInArriving : PortalLook.fadeIn)),
                                removal: .opacity.animation(.easeOut(duration: PortalLook.fadeOut))))
                    }
                }
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
        .environment(\.statusBarEdges, statusEdges)
        .environment(\.modalFocus, router.modalFocus)
        #if os(tvOS)
        // The focus engine keeps its focus on an item that can no longer take it until the next press: when the focus
        // owner changes (a layer opens or closes, another screen shows), it is asked to look for the preferred item,
        // once the items of the new owner exist
        .focusScope(focusScope)
        .environment(\.focusNamespace, focusScope)
        .task(id: ObjectIdentifier(router.modalFocus ?? navigator.focus)) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            resetFocus(in: focusScope)
        }
        #endif
        .environment(\.delosColors, colors)
        .environment(\.reducedMotion, systemReduceMotion || appearance.reducedMotion)
        .environment(\.shellCoversArt, sideMenu != nil || actions.connection.portal != nil)
        // Material You colors leave the game's colors out, as on Android
        .environment(\.matchGameColors, appearance.matchGameColors && !colors.materialYou)
        .onChange(of: systemReduceMotion || appearance.reducedMotion, initial: true) { _, now in
            actions.connection.reducedMotion = now
            router.reducedMotion = now
        }
        .preferredColorScheme(colors.dark ? .dark : .light)
        .onChange(of: profiles.current?.id) { _, id in
            appearance = id.map { appearances.load(profile: $0) } ?? Appearance()
        }
        .onChange(of: appearance, initial: true) { _, now in
            feedback?.soundsEnabled = now.sounds
            feedback?.hapticsEnabled = now.haptics
        }
        .onAppear {
            device.start()
            // A crash, hang or unclean exit of the last run: one card offers the report, once per problem
            ProblemOffers.shared.detect()
        }
        // "Skip the start screen": straight into the default PC, once, when DELOS opens
        .task { await actions.skipStartIfChosen() }
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        #if os(tvOS)
        // Menu is back (at the start screen the system's Home), Play/Pause the focused item's context menu; the
        // directions and select are the system focus engine's, a swipe or a direction also reaches `route`
        .onExitCommand(perform: router.handlesExit ? { router.route(.back, repeatCount: 0, fromRemote: true) } : nil)
        .onPlayPauseCommand { router.route(.options, repeatCount: 0, fromRemote: true) }
        .onMoveCommand { router.routeMove($0) }
        #endif
        .onAppear(perform: startInput)
        #if DEBUG
        .task {
            for step in DemoHarness.script {
                try? await Task.sleep(for: .seconds(step.wait))
                if step.command == "toast-undo" { toasts.show("Profile deleted", icon: Symbols.delete, action: ToastAction(label: "Undo") {}); continue }
                if DemoHarness.input(step.command) { continue }
                if await DemoHarness.sideDrag(step.command, router: router) { continue }
                if let command = DemoHarness.command(step.command) { router.route(command, repeatCount: 0) }
            }
        }
        #endif
        // The keys that scroll or move the system focus (arrows, Space, Page, Home, End) are the interface's alone
        .ownsMenuKeys(typing: navigator.isEditingText)
        // A touch or the pointer changes the kind of input the hints and the back arrow are drawn for
        .tracksInputKind()
        // An "up" of a key may never come after the app lost the keyboard
        .onChange(of: scenePhase, initial: true) { _, now in
            if now != .active { input?.forgetDown() }
            // A process the system ends while the app is in front is an unclean exit (Apple TV's only signal of one)
            CrashReporter.setForeground(now == .active)
        }
    }

    /// The sounds, and the controllers' and keyboards' commands (on tvOS only the ones the system has no event for).
    private func startInput() {
        guard input == nil else { return }
        ControllerGlyphs.shared.start()
        let feedback = Feedback()
        feedback.soundsEnabled = appearance.sounds
        feedback.hapticsEnabled = appearance.haptics
        self.feedback = feedback
        layers.feedback = feedback
        router.feedback = feedback
        router.stepQuickSetting = { id, direction in quickStep(id, by: direction) }
        router.problemCard = { [navigator, layers, actions, weak router] in
            ProblemOffers.shared.shown(
                screen: navigator.current, layerOpen: layers.isOpen, sideMenu: router?.sideMenu != nil, portal: actions.connection.portal != nil)
                ? ProblemOffers.shared.focus : nil
        }
        router.dismissProblem = { ProblemOffers.shared.dismiss() }
        #if os(tvOS)
        let input = MenuInput(only: MenuInput.tvCommands) { command, repeatCount in router.route(command, repeatCount: repeatCount) }
        #else
        let input = MenuInput { command, repeatCount in router.route(command, repeatCount: repeatCount) }
        #endif
        input.start()
        self.input = input
        navigator.cancelRepeats = { [weak input] in input?.cancelRepeats() }
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
                onPC: { host in actions.connect(host.id) },
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
                focus: entry.focus, activeID: actions.libraryHostID, actions: actions,
                onPair: { go { navigator.push(.pair, focus: PairPCScreen.firstFocus(hosts.hosts)) } })
        case .pair:
            PairPCScreen(
                focus: entry.focus,
                onHost: { host in host.pin != nil ? actions.connect(host.id) : go { navigator.push(.pin(hostID: host.id), focus: "cancel") } },
                onCode: { host in actions.pairWithCode(hostID: host.id) },
                onAddress: { addByAddress() }
            )
        case .pin(let hostID):
            pinScreen(hostID: hostID, code: nil, entry: entry)
        case .pairCode(let hostID, let code):
            pinScreen(hostID: hostID, code: code, entry: entry)
        case .home(let hostID):
            HomeScreen(hostID: hostID, focus: entry.focus, actions: actions)
        case .artwork(let hostID, let appID):
            if let app = hosts.apps[hostID]?.first(where: { $0.id == appID }) {
                ArtworkScreen(hostID: hostID, app: app, focus: entry.focus, navigator: navigator, actions: actions)
            }
        case .appSettings(let hostID, let appID):
            if let app = hosts.apps[hostID]?.first(where: { $0.id == appID }) {
                GameSettingsScreen(
                    hostID: hostID, app: app, focus: entry.focus, navigator: navigator, actions: actions, profileID: profiles.current?.id ?? "")
            }
        case .stream(let hostID, let appID):
            StreamScreen(
                hostID: hostID, appID: appID, profileID: profiles.current?.id, settings: actions.streamSettings(hostID: hostID, appID: appID),
                palette: Palette(rawValue: appearance.palette.rawValue) ?? .delos,
                keepStatisticsOverlay: { actions.keepStatisticsOverlay($0) }, keepOnScreenOpacity: { actions.keepOnScreenOpacity($0) })
        case .settings:
            SettingsScreen(
                profileID: profiles.current?.id ?? "", appearance: $appearance, focus: entry.focus, navigator: navigator,
                feedback: feedback, actions: actions, tab: settingsTab)
        case .oscPreview:
            OnScreenControlsPreview(
                profileID: profiles.current?.id ?? "", palette: Palette(rawValue: appearance.palette.rawValue) ?? .delos,
                onBack: { feedback?.play(.back); go { navigator.back() } })
        case .debugInfo:
            DebugInfoScreen(
                profileID: profiles.current?.id ?? "", focus: entry.focus, navigator: navigator, feedback: feedback, actions: actions)
        }
    }

    private func pinScreen(hostID: String, code: OneTimeCode?, entry: Navigator.Entry) -> some View {
        PinScreen(
            hostID: hostID, code: code, focus: entry.focus, feedback: feedback,
            onPaired: { actions.connect(hostID) },
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

    /// The problem card shows (`offerShown`): on the start and home screens with nothing over them.
    private var offerShown: Bool {
        ProblemOffers.shared.shown(screen: navigator.current, layerOpen: layers.isOpen, sideMenu: sideMenu != nil, portal: actions.connection.portal != nil)
    }

    /// The library's game background shows behind the library only (``Screen/showsGameBackground``).
    private var showsLibrary: Bool { navigator.current.showsGameBackground }

    /// The library's row of covers is on the screen (the hint bar centres itself below it).
    private var showsLibraryRow: Bool {
        if case .home = navigator.current { true } else { false }
    }

    /// The library's filter sheet is open. The Artwork screen's sheet is part of that screen, under the bar, as on Android.
    private var librarySheetOpen: Bool { showsLibraryRow && navigator.screenHints.sheetOpen }

    /// The button hints of the screen, layer and side menu in front (``ShellHints``).
    private var hints: [Hint] {
        var layer: ShellHints.Layer?
        switch layers.layer {
        case .context?: layer = .context(root: layers.menuPath.isEmpty)
        case .dialog?: layer = .dialog
        // The recording of the stream menu's buttons keeps the screen's hints, as Android's capture layer does
        case .buttonCapture?, nil: break
        }
        let focus = layers.isOpen ? layers.focus : navigator.focus
        return ShellHints.hints(ShellHints.Context(
            screen: navigator.current, layer: layer, sideMenu: sideMenu != nil,
            portalCancellable: actions.connection.portal.map(\.cancellable), canGoBack: navigator.canGoBack,
            hasContextMenu: focus.focusedHasMenu, screenHints: navigator.screenHints))
    }

    /// The library's note on the hint bar: how many apps the PC has, of how many while a filter is on (the home screen with
    /// nothing open).
    private var libraryNote: String? {
        guard case .home(let hostID) = navigator.current, !layers.isOpen, sideMenu == nil,
              let apps = hosts.apps[hostID], let host = hosts.hosts.first(where: { $0.id == hostID }) else { return nil }
        let filters = metadata.enabled ? actions.libraryFilters.filters(hostID: hostID) : MetadataFilters()
        guard filters.active else { return ShellHints.libraryNote(apps: apps.count, pc: host.name) }
        let listed = actions.libraryOrder(hostID: hostID, apps: apps)
        let shown = LibraryFilter.apply(filters, to: listed) { metadata.data(for: $0) }.count
        return LibraryFilter.filteredNote(shown: shown, total: listed.count, pc: host.name)
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

    /// The PC whose library is open below the current screen, for the status bar's pill and the side menu.
    private var connectedHost: HostRecord? {
        for entry in navigator.stack.reversed() {
            if case .home(let hostID) = entry.screen, let host = hosts.host(hostID) { return host }
        }
        return nil
    }

    private var connectedPC: (name: String, online: Bool)? {
        connectedHost.map { ($0.name, $0.reachability == .online) }
    }

    /// The side menu header's PC: its name and live state.
    private var sidePC: SidePC? {
        connectedHost.map { SidePC(name: $0.name, state: .of($0, connecting: actions.connection.isActive)) }
    }

    /// A quick setting of the side menu stepped (the side menu's rows): applied at once and kept with the current
    /// profile's appearance. False when nothing changed.
    private func quickStep(_ id: String, by direction: Int) -> Bool {
        if id == SideMenu.hiddenID {
            actions.hiding.showHidden.toggle()
            return true
        }
        guard let profile = profiles.current?.id, let next = QuickSettings.step(id, by: direction, from: appearance) else { return false }
        appearance = next
        appearances.save(next, profile: profile)
        return true
    }

    /// "Enter address" on the pairing screen (`addByAddress` of DELOS for Android): a dialog for the address.
    private func addByAddress() {
        layers.openDialog(DialogSpec(
            title: L("devices_address_title"), note: L("devices_address_note"),
            fields: [DialogField(icon: Symbols.mapPin, placeholder: "192.168.1.20", maxLength: 64, address: true)],
            confirm: L("devices_address_action")
        ) { addAndPair($0[0]) })
    }

    /// "Add PC" in the address dialog (`addAndPair` of DELOS for Android): asks the address who it is, then pairs with
    /// it, or opens its library when it is paired already. What goes wrong is said in a toast; the dialog stays on a
    /// wrong address.
    private func addAndPair(_ text: String) -> Bool {
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
        toasts.show(L("devices_address_looking", address.description), icon: Symbols.search)
        Task {
            do {
                let host = try await hosts.ask(address, typed: true)
                let added = await PairStateWait.until(timeout: 5, clock: SystemConnectClock()) { hosts.host(host.id) != nil }
                guard !Task.isCancelled else { return }
                guard added else {
                    feedback?.play(.error)
                    toasts.show(L("devices_address_not_added", address.description), icon: Symbols.error)
                    return
                }
                go {
                    if host.pin != nil {
                        actions.connect(host.id)
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
}

/// Changes the screen with the shared screen transition (`.screen` of the prototype: a fade with a slight zoom).
@MainActor func go(_ change: () -> Void) {
    withAnimation(.easeOut(duration: 0.5), change)
}
