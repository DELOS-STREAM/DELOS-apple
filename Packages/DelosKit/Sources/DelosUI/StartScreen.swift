import DelosData
import DelosInput
import SwiftUI

/// The start screen (docs/GUI.md of DELOS for Android): the greeting, the current profile's chip at the top, the paired
/// PCs in circles and the circle that pairs a new PC. So far it has no PCs: it shows the greeting and the pairing circle,
/// plus a second circle that only exists to try out moving the focus between two items with a controller (removed when
/// PCs exist).
///
/// On Android the chip opens the profiles context menu; until context menus exist it opens the profile screen.
struct StartScreen: View {
    let focus: FocusModel
    let profile: Profile?
    let onProfile: @MainActor () -> Void
    @Environment(\.stage) private var stage

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
    }

    private var circles: some View {
        VStack(spacing: stage.px(48)) {
            Heading(
                title: profile.map { L("devices_start_greeting", $0.name) } ?? L("devices_start_welcome"),
                sub: L("devices_start_pair_note")
            )
            HStack(alignment: .top, spacing: stage.px(56)) {
                FocusItem(id: "pair", model: focus, action: {}) { focused in
                    CircleItem(
                        icon: Symbols.addLink,
                        label: L("devices_pair_new"),
                        meta: L("devices_pair_new_meta"),
                        focused: focused
                    )
                }
                FocusItem(id: "settings", model: focus, action: {}) { focused in
                    CircleItem(
                        icon: Symbols.settings,
                        label: L("shell_nav_settings"),
                        focused: focused
                    )
                }
            }
        }
    }
}

/// The root of the interface: background, status bar and the current screen of the ``Navigator``, on the 1920 × 1080
/// stage. Without a profile it shows the first run; the appearance is the current profile's.
public struct DelosRoot: View {
    @State private var profiles: ProfileStore
    @State private var navigator: Navigator
    @State private var appearance: Appearance
    @State private var input: MenuInput?
    @State private var feedback: Feedback?
    private let appearances = AppearanceStore()

    public init() {
        let profiles = ProfileStore()
        _profiles = State(initialValue: profiles)
        _navigator = State(initialValue: profiles.isFirstRun ? Navigator(root: .boot, focus: "begin") : Navigator(root: .start, focus: "pair"))
        _appearance = State(initialValue: profiles.current.map { AppearanceStore().load(profile: $0.id) } ?? Appearance())
    }

    private var colors: DelosColors {
        DelosColors(palette: Palette(rawValue: appearance.palette.rawValue) ?? .delos, dark: appearance.dark)
    }

    public var body: some View {
        StageReader {
            ZStack {
                Backdrop()
                let entry = navigator.stack[navigator.stack.count - 1]
                screen(entry)
                    .id(ObjectIdentifier(entry.focus))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.035)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))
                    ))
                TopBar(brand: navigator.current != .start)
            }
        }
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
            let input = MenuInput { [navigator, feedback] command in
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
            StartScreen(focus: entry.focus, profile: profiles.current) {
                go { navigator.push(.profile, focus: "change-avatar") }
            }
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
                        go { another ? navigator.reset(to: .start, focus: "pair") : navigator.reset(to: .boot, focus: "begin") }
                    }
                )
            }
        }
    }

    /// Create / Save on the profile page. A profile made in the first run goes on to the start screen (Android goes on
    /// to pairing, which does not exist here yet); one added or changed from the profile screen returns there.
    private func profileDone(editing: Bool, name: String, avatar: Int) {
        if editing {
            if let id = profiles.current?.id { profiles.update(id, name: name, avatar: avatar) }
            go { navigator.back() }
            return
        }
        profiles.create(name: name, avatar: avatar)
        go {
            if navigator.stack.first?.screen == .boot { navigator.reset(to: .start, focus: "pair") } else { navigator.back() }
        }
    }
}

/// Changes the screen with the shared screen transition (`.screen` of the prototype: a fade with a slight zoom).
@MainActor private func go(_ change: () -> Void) {
    withAnimation(.easeOut(duration: 0.5), change)
}

/// The status bar: the brand at the top left, 72 stage pixels from the side, in a 104 px high bar. The start screen
/// leaves the brand out: the profile chip is at the top there.
struct TopBar: View {
    var brand = true
    @Environment(\.stage) private var stage

    var body: some View {
        VStack {
            HStack {
                if brand { Brand() }
                Spacer()
            }
            .frame(height: stage.px(104))
            .padding(.top, stage.px(stage.safe.top))
            .padding(.leading, stage.px(72 + stage.safe.leading))
            .padding(.trailing, stage.px(72 + stage.safe.trailing))
            Spacer()
        }
    }
}
