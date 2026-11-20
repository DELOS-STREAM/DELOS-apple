import DelosData
import SwiftUI

extension OscOptions {
    /// The on-screen controls' settings of a profile (or of a game's settings over it), by DELOS for Android's keys.
    init(_ settings: StreamSettings) {
        self.init(
            onlyL3R3: settings.bool(.onlyShowL3R3), showGuide: settings.bool(.showGuideButton),
            flipFaceButtons: settings.bool(.flipFaceButtons), freeSticks: settings.bool(.freeAnalogStick),
            opacity: settings.int(.oscOpacity), freeStickOpacity: settings.int(.freeAnalogStickOpacity),
            pressHaptics: settings.bool(.vibrateKeyboard), deviceRumble: settings.bool(.vibrateOsc))
    }
}

extension OscOutput {
    /// The layout of [profile] in ``OnScreenControlsStore``.
    mutating func storing(profile: String, store: OnScreenControlsStore = OnScreenControlsStore()) {
        readLayout = { store.read(profile: profile) }
        writeLayout = { store.write($0, profile: profile) }
    }
}

/// The on-screen controls without a stream (`OscPreviewScreen` of DELOS for Android, Settings → Controls → Preview on-screen
/// controls; Android has it in Debug info): the profile's layout over a dark backdrop like a game, every button, the D-pad and
/// the sticks reacting to touch, nothing sent anywhere. The gear in the corner edits the layout as in a stream (turn controls
/// on or off, move, resize), and the layout is saved. B goes back; a finger, which has no B, has the back arrow beside the note.
struct OnScreenControlsPreview: View {
    let profileID: String
    let palette: Palette
    let onBack: @MainActor () -> Void
    @State private var controls: OnScreenControls?
    @Environment(Toasts.self) private var toasts: Toasts?
    @Environment(\.stage) private var stage
    @Environment(\.delosColors) private var colors
    #if os(iOS)
    @State private var haptics = OscPressHaptics()
    #endif

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(.sRGB, red: 0x2A / 255, green: 0x34 / 255, blue: 0x46 / 255), Color(.sRGB, red: 0x07 / 255, green: 0x09 / 255, blue: 0x0E / 255)],
                center: .center, startRadius: 0, endRadius: stage.px(1600))
            .ignoresSafeArea()
            if let controls {
                OnScreenControlsCanvas(controls: controls, palette: palette)
                    .ignoresSafeArea()
                #if os(iOS)
                OscTouchSurface(controls: controls)
                    .ignoresSafeArea()
                #endif
            }
            VStack {
                HStack(spacing: stage.px(24)) {
                    #if os(iOS) || os(macOS)
                    Button(action: onBack) {
                        SymbolView(symbol: Symbols.arrowBack, size: 34, color: colors.text)
                            .frame(width: stage.px(68), height: stage.px(68))
                            .background(GlassShape(Circle(), tint: colors.surface))
                            .overlay(Circle().strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                    }
                    .pressButton()
                    .accessibilityLabel(L("shell_hint_back"))
                    .inputKindVisibility(.withoutController)
                    #endif
                    Text(L("settings_osc_preview_note", "B"))
                        .font(DelosFonts.figtree(stage.tpx(20)))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, stage.px(40))
                Spacer()
            }
        }
        .onAppear(perform: start)
        .onDisappear { controls?.releaseAll() }
    }

    private func start() {
        guard controls == nil else { return }
        var output = OscOutput()
        output.storing(profile: profileID)
        output.announce = { [toasts] text in toasts?.show(text, icon: Symbols.settings) }
        #if os(iOS)
        output.vibrate = { [haptics] in haptics.play($0) }
        #endif
        let settings = StreamSettingsStore().load(profile: profileID)
        controls = OnScreenControls(options: OscOptions(settings), enabled: true, followsGamepad: false, output: output)
    }
}
