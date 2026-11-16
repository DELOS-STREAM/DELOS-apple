import DelosData
import DelosInput
import DelosMedia
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// A stream of one app of one PC (`DelosStreamActivity` of DELOS for Android, as far as P4 goes): the loader while it
/// connects, the video full screen with the controllers, keyboard, mouse and touch going to the PC, a minimal stream
/// menu (Resume, Disconnect, Quit app), and the result overlay when the stream failed. The statistics overlay is not
/// ported yet.
///
/// The stream menu opens like on Android by default: L3 + R3 held together on a controller (``MenuShortcut``), or a
/// swipe up from the bottom edge of the touch screen (``MenuSwipe``).
struct StreamScreen: View {
    let hostID: String
    let appID: Int
    /// The current profile's stream settings.
    let settings: StreamSettings
    @Environment(HostStore.self) private var hosts
    @Environment(Navigator.self) private var navigator
    @State private var controller: StreamController?
    @State private var renderer: DisplayLayerRenderer?

    init(hostID: String, appID: Int, settings: StreamSettings) {
        self.hostID = hostID
        self.appID = appID
        self.settings = settings
    }

    var body: some View {
        ZStack {
            if let controller, let renderer {
                StreamContent(controller: controller, renderer: renderer, focus: navigator.focus)
            }
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        .onChange(of: controller?.phase) { _, phase in
            if phase == .ended { navigator.back() }
        }
        #if os(iOS)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        #endif
    }

    private func begin() {
        guard controller == nil else { return }
        let renderer = DisplayLayerRenderer()
        let controller = StreamController { [hosts, hostID, appID, settings] in
            LiveStream(hosts: hosts, hostID: hostID, appID: appID, settings: settings, renderer: renderer)
        }
        self.renderer = renderer
        self.controller = controller
        navigator.commandCapture = { [navigator] command in
            Self.capture(command, controller: controller, focus: navigator.focus)
        }
        IdleTimer.disabled = true
    }

    private func end() {
        navigator.commandCapture = nil
        IdleTimer.disabled = false
        // Leaving the screen any other way than through the menu disconnects (the app keeps running on the PC)
        if let controller { Task { await controller.leave(quit: false) } }
    }

    /// Who gets a controller or keyboard command: the PC while the stream runs (``GameInput`` sends it), the stream
    /// menu or the result overlay while they are shown (through the screen's focus); B closes the menu, leaves the
    /// result overlay (Back to library) and stops a stream that is still connecting.
    static func capture(_ command: MenuCommand, controller: StreamController, focus: FocusModel) -> Bool {
        switch controller.phase {
        case .streaming:
            guard controller.menuOpen else { return true }
            if command == .back {
                controller.closeMenu()
                return true
            }
            return false
        case .failed:
            if command == .back {
                controller.dismiss()
                return true
            }
            return false
        case .connecting:
            if command == .back { Task { await controller.leave(quit: false) } }
            return true
        case .leaving, .ended:
            return true
        }
    }
}

/// What the stream screen shows in each phase.
struct StreamContent: View {
    let controller: StreamController
    let renderer: DisplayLayerRenderer
    let focus: FocusModel

    var body: some View {
        ZStack {
            // Black under the video and the exit; the loader and the result overlay lie on DELOS's background
            Color.black.ignoresSafeArea().opacity(showsBlack ? 1 : 0)
            VideoSurface(
                layer: renderer.layer,
                onDisplay: { controller.start(display: $0) },
                onTouch: { id, phase, point, height, time in
                    controller.touch(id, phase, at: point, height: height, time: time)
                },
                ignoresPointer: { controller.hasMouse }
            )
            .ignoresSafeArea()
            .opacity(controller.phase == .streaming ? 1 : 0)
            switch controller.phase {
            case .connecting:
                StreamLoader(greeting: controller.greeting, line: controller.line, progress: controller.progress)
            case .streaming:
                if controller.menuOpen {
                    StreamMenu(focus: focus, controller: controller)
                }
            case .leaving(let text):
                StreamLoader(greeting: text, line: "", progress: nil)
            case .failed(let text):
                StreamResultLayer(
                    text: text, focus: focus,
                    onRetry: { controller.retry() },
                    onBack: { controller.dismiss() })
            case .ended:
                EmptyView()
            }
        }
    }

    private var showsBlack: Bool {
        switch controller.phase {
        case .streaming, .leaving, .ended: true
        case .connecting, .failed: false
        }
    }
}

/// The loader while the stream connects (`StreamLoader` of DELOS for Android, without the launch tunnel and the game
/// card, which come with the launch scene): "Calling up <PC>", the line of the current stage and the progress.
private struct StreamLoader: View {
    let greeting: String
    let line: String
    /// Nil: no bar (leaving).
    let progress: Double?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(28)) {
            Text(greeting)
                .font(DelosFonts.unbounded(stage.px(stage.compact ? 42 : 52)))
                .foregroundStyle(colors.text.color)
                .multilineTextAlignment(.center)
            if !line.isEmpty {
                Text(line)
                    .font(DelosFonts.figtree(stage.px(28)))
                    .foregroundStyle(colors.text2.color)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.25), value: line)
            }
            if let progress {
                Capsule()
                    .fill(colors.surface2.color)
                    .frame(width: stage.px(600), height: stage.px(8))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(colors.accent.color)
                            .frame(width: stage.px(600 * progress), height: stage.px(8))
                            .animation(.easeOut(duration: 0.6), value: progress)
                    }
                    .padding(.top, stage.px(12))
            }
        }
        .padding(.horizontal, stage.px(96))
    }
}

/// The stream menu, minimal: Resume, Disconnect and Quit app as circles on a dark band at the bottom (the dock of
/// DELOS for Android's stream menu; its other tiles are not ported yet). The focus starts on Resume.
private struct StreamMenu: View {
    let focus: FocusModel
    let controller: StreamController
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.clear, colors.scrim.color, colors.scrim.color], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.closeMenu() }
            HStack(alignment: .top, spacing: stage.px(64)) {
                FocusItem(id: "stream-resume", model: focus, action: { controller.closeMenu() }) { focused in
                    CircleItem(icon: Symbols.resume, label: L("stream_menu_tile_resume"), big: false, focused: focused)
                }
                FocusItem(id: "stream-disconnect", model: focus, action: { Task { await controller.leave(quit: false) } }) { focused in
                    CircleItem(icon: Symbols.logout, label: L("stream_menu_tile_disconnect"), big: false, focused: focused)
                }
                FocusItem(id: "stream-quit", model: focus, action: { Task { await controller.leave(quit: true) } }) { focused in
                    CircleItem(icon: Symbols.powerSettingsNew, label: L("stream_menu_tile_quit"), big: false, focused: focused)
                }
            }
            .padding(.bottom, stage.px(72) + stage.safe.bottom)
        }
        .onAppear { focus.focus("stream-resume") }
        .transition(.opacity)
    }
}

/// The result overlay (`StreamResultLayer` of DELOS for Android): a sad face, the title, one sentence, Try again
/// (focused first) and Back to library, and the technical details behind Details, never open at first. B is Back
/// to library.
private struct StreamResultLayer: View {
    let text: ResultText
    let focus: FocusModel
    let onRetry: @MainActor () -> Void
    let onBack: @MainActor () -> Void
    @State private var expanded = false
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack {
            colors.scrim.color.ignoresSafeArea()
            VStack(spacing: stage.px(24)) {
                ZStack {
                    Circle().fill(colors.accent.opacity(0.16).color)
                        .overlay(Circle().strokeBorder(colors.accent.opacity(0.42).color, lineWidth: stage.px(2)))
                    SymbolView(symbol: Symbols.sentimentDissatisfied, size: 128, color: colors.accent, filled: true)
                }
                .frame(width: stage.px(220), height: stage.px(220))
                Text(text.title)
                    .font(DelosFonts.unbounded(stage.px(stage.compact ? 42 : 52)))
                    .foregroundStyle(colors.text.color)
                    .multilineTextAlignment(.center)
                    .padding(.top, stage.px(8))
                if !text.sentence.isEmpty {
                    Text(text.sentence)
                        .font(DelosFonts.figtree(stage.px(28)))
                        .foregroundStyle(colors.text2.color)
                        .multilineTextAlignment(.center)
                        .lineSpacing(stage.px(28) * 0.4)
                        .frame(maxWidth: stage.px(1000))
                }
                HStack(spacing: stage.px(24)) {
                    FocusItem(id: "result-retry", model: focus, action: onRetry) { focused in
                        PillButton(label: L("stream_result_try_again"), icon: Symbols.refresh, primary: true, focused: focused)
                    }
                    FocusItem(id: "result-back", model: focus, action: onBack) { focused in
                        PillButton(label: L("stream_result_back_to_library"), icon: Symbols.library, focused: focused)
                    }
                }
                .padding(.top, stage.px(12))
                if let details = text.details, !details.isEmpty {
                    FocusItem(id: "result-details", model: focus, action: { expanded.toggle() }) { focused in
                        HStack(spacing: stage.px(8)) {
                            Text(L("stream_result_details"))
                                .font(DelosFonts.figtree(stage.px(22), .semibold))
                                .foregroundStyle(colors.text2.color)
                            SymbolView(symbol: expanded ? Symbols.expandLess : Symbols.expandMore, size: 26, color: colors.text2)
                        }
                        .padding(.horizontal, stage.px(26))
                        .padding(.vertical, stage.px(12))
                        .focusLook(focused, scale: 1.06, ring: 3, glowBlur: 0, glowY: 0)
                    }
                    if expanded {
                        ScrollView {
                            Text(details)
                                .font(DelosFonts.figtree(stage.px(22)))
                                .foregroundStyle(colors.text2.color)
                                .lineSpacing(stage.px(22) * 0.4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, stage.px(32))
                                .padding(.vertical, stage.px(22))
                        }
                        .frame(maxWidth: stage.px(1100), maxHeight: stage.px(stage.compact ? 200 : 280))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(colors.surface.color, in: RoundedRectangle(cornerRadius: stage.px(28)))
                        .overlay(RoundedRectangle(cornerRadius: stage.px(28)).strokeBorder(colors.line.color, lineWidth: stage.px(1)))
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, stage.px(48))
            .animation(.easeOut(duration: 0.25), value: expanded)
        }
        .onAppear { focus.focus("result-retry") }
    }
}

/// Keeps the screen on during a stream (`UIApplication.isIdleTimerDisabled`).
@MainActor
private enum IdleTimer {
    static var disabled: Bool {
        get {
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled
            #else
            false
            #endif
        }
        set {
            #if os(iOS) || os(tvOS)
            UIApplication.shared.isIdleTimerDisabled = newValue
            #endif
        }
    }
}
