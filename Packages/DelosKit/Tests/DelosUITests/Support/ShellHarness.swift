#if os(macOS)
import DelosData
import DelosHost
import DelosInput
import SwiftUI
@testable import DelosUI

/// The shell without the app: the real screens, the real top bar, side menu and layers, laid out in a window that is never
/// shown, with the real ``ShellRouter`` giving the commands to whoever owns them. A test presses buttons with
/// ``press(_:)`` and reads where the focus is.
@MainActor
final class ShellHarness {
    let fx: ShellFixture
    let router: ShellRouter
    let host: ScreenHost

    init(device: TestDevice = TestDevice.all[0], root: Screen = .start, pcs: [(id: String, name: String, online: Bool)]? = nil,
         apps: [HostApp] = ShellFixture.library, key: String? = nil, metadataOn: Bool = true) {
        let fixture = pcs.map { ShellFixture(pcs: $0, apps: apps, key: key, metadataOn: metadataOn) }
            ?? ShellFixture(apps: apps, key: key, metadataOn: metadataOn)
        fx = fixture
        router = ShellRouter(navigator: fixture.navigator, layers: fixture.layers, toasts: fixture.toasts, actions: fixture.actions)
        router.transition = { $0() }
        router.animate = { _, change in change() }
        fixture.navigator.reset(to: root, focus: fixture.actions.startFocus())
        let router = router
        host = ScreenHost(size: device.size, safeArea: device.safe) {
            HarnessRoot(fx: fixture, router: router)
        }
    }

    var navigator: Navigator { fx.navigator }
    var layers: Layers { fx.layers }
    /// The focused item of the screen shown.
    var focused: String? { navigator.focus.focused as? String }

    /// Waits until the screen shown has registered [id].
    @discardableResult
    func waitFor(_ id: AnyHashable) async -> Bool {
        await host.until { self.navigator.focus.registeredFrames[id] != nil }
    }

    /// Waits until the open layer has registered [id].
    @discardableResult
    func waitForLayer(_ id: AnyHashable) async -> Bool {
        await host.until { self.layers.focus.registeredFrames[id] != nil }
    }

    /// A press of [command], as a controller's button or a key gives it. Returns nothing: read the state after it.
    func press(_ command: MenuCommand, repeatCount: Int = 0) {
        router.route(command, repeatCount: repeatCount)
    }

    func pressAll(_ commands: MenuCommand...) {
        for command in commands { press(command) }
    }

    /// Lets the accept gates of a screen change or an opening pass, as time does.
    func letGatesPass() {
        navigator.armInputGate(at: .distantPast)
    }

    func open(_ screen: Screen, focus: AnyHashable? = nil) async {
        navigator.push(screen, focus: focus)
        _ = await host.until { self.navigator.focus.registeredFrames.count > 1 }
    }
}

/// What the root view of the app shows, without its state: the current screen, the top bar, the side menu and the layers.
struct HarnessRoot: View {
    let fx: ShellFixture
    let router: ShellRouter
    @State private var appearance = Appearance()

    var body: some View {
        let navigator = fx.navigator
        let entry = navigator.stack[navigator.stack.count - 1]
        fx.environment(
            ZStack {
                screen(entry).id(ObjectIdentifier(entry.focus))
                if case .stream = entry.screen {} else {
                    TopBar(
                        brand: entry.screen != .start,
                        navigation: entry.screen.showsNavigation ? TopBar.Navigation(
                            buttons: TopNav.buttons(
                                current: entry.screen, onSettings: { navigator.openFromNavigation(.settings, focus: SettingsScreen.initialFocus) },
                                onProfile: { navigator.openFromNavigation(.profile, focus: "change-avatar") },
                                onDevices: { navigator.openFromNavigation(.devices, focus: fx.actions.devicesFocus()) }),
                            focus: entry.focus) : nil,
                        pc: entry.screen.showsNavigation ? (name: "Meiton-PC", online: true) : nil,
                        onBack: navigator.canGoBack ? { _ = navigator.back() } : nil)
                        .id(ObjectIdentifier(entry.focus))
                }
                if let sideMenu = router.sideMenu {
                    SideMenu(profile: fx.profiles.current, pc: SidePC(name: "Meiton-PC", state: .online), playtime: router.sidePlaytime, focus: sideMenu, appearance: appearance,
                             onStep: { _, _ in }, onSettings: {}, hidden: fx.actions.hiddenRow(pcName: "Meiton-PC"))
                }
                LayerHost(layers: fx.layers, navigator: navigator)
                // The portal into a PC, as the root shows it: the start screen's PC connects through it
                if let portal = fx.actions.connection.portal {
                    PortalOverlay(portal: portal, burst: fx.actions.connection.burst, focus: router.portalFocus, onCancel: { fx.actions.connection.cancel() })
                }
            }
            .environment(\.modalFocus, router.modalFocus))
    }

    @ViewBuilder private func screen(_ entry: Navigator.Entry) -> some View {
        let navigator = fx.navigator
        switch entry.screen {
        case .boot: BootScreen(focus: entry.focus, onBegin: {}, onSkip: {})
        case .createProfile(let editing):
            CreateProfileScreen(editing: editing, initial: editing ? fx.profiles.current : nil, focus: entry.focus, actions: fx.actions) { _, _ in }
        case .start:
            StartScreen(focus: entry.focus, profile: fx.profiles.current, defaultPC: nil, actions: fx.actions, onPC: { fx.actions.connect($0.id) },
                        onPair: { navigator.push(.pair, focus: PairPCScreen.firstFocus(fx.hosts.hosts)) })
        case .profile:
            ProfileScreen(profile: fx.profiles.current!, count: 1, focus: entry.focus, actions: fx.actions,
                          onChangeAvatar: { navigator.push(.createProfile(editing: true), focus: CreateProfileScreen.avatarID(0)) },
                          onAdd: { navigator.push(.createProfile(editing: false), focus: CreateProfileScreen.avatarID(0)) })
        case .devices:
            DevicesScreen(focus: entry.focus, activeID: fx.actions.libraryHostID, actions: fx.actions,
                          onPair: { navigator.push(.pair, focus: PairPCScreen.firstFocus(fx.hosts.hosts)) })
        case .pair:
            PairPCScreen(focus: entry.focus, onHost: { _ in }, onCode: { _ in }, onAddress: {})
        case .home(let hostID): HomeScreen(hostID: hostID, focus: entry.focus, actions: fx.actions)
        case .settings:
            SettingsScreen(profileID: fx.profiles.current?.id ?? "", appearance: $appearance, focus: entry.focus, navigator: navigator,
                           feedback: nil, actions: fx.actions, tab: nil)
        case .artwork(let hostID, let appID):
            if let app = fx.hosts.apps[hostID]?.first(where: { $0.id == appID }) {
                ArtworkScreen(hostID: hostID, app: app, focus: entry.focus, navigator: navigator, actions: fx.actions)
            }
        case .appSettings(let hostID, let appID):
            if let app = fx.hosts.apps[hostID]?.first(where: { $0.id == appID }) {
                GameSettingsScreen(hostID: hostID, app: app, focus: entry.focus, navigator: navigator, actions: fx.actions,
                                   profileID: fx.profiles.current?.id ?? "")
            }
        case .oscPreview:
            OnScreenControlsPreview(profileID: fx.profiles.current?.id ?? "", palette: .delos, onBack: { navigator.back() })
        case .debugInfo:
            DebugInfoScreen(profileID: fx.profiles.current?.id ?? "", focus: entry.focus, navigator: navigator, feedback: nil, actions: fx.actions)
        case .pin, .pairCode, .stream: Color.clear
        }
    }
}
#endif
