import DelosInput
import SwiftUI

/// The start screen (docs/GUI.md of DELOS for Android): the greeting, the paired PCs in circles and the circle that
/// pairs a new PC. So far it has no PCs: it shows the greeting and the pairing circle, plus a second circle that only
/// exists to try out moving the focus between two items with a controller (removed when PCs exist).
struct StartScreen: View {
    let focus: FocusModel
    @Environment(\.stage) private var stage

    var body: some View {
        VStack(spacing: stage.px(48)) {
            Heading(
                title: L("devices_start_welcome"),
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

/// The root of the interface: background, status bar and the current screen, on the 1920 × 1080 stage.
public struct DelosRoot: View {
    @State private var focus = FocusModel(initial: AnyHashable("pair"))
    @State private var input: MenuInput?
    @State private var colors = DelosColors(palette: .delos, dark: true)

    public init() {}

    public var body: some View {
        StageReader {
            ZStack {
                Backdrop()
                StartScreen(focus: focus)
                TopBar()
            }
        }
        .environment(\.delosColors, colors)
        .preferredColorScheme(colors.dark ? .dark : .light)
        #if os(iOS)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        #endif
        #if !os(tvOS)
        .onAppear {
            let input = MenuInput { [focus] command in focus.handle(command) }
            input.start()
            self.input = input
        }
        #endif
    }
}

/// The status bar: the brand at the top left, 72 stage pixels from the side, in a 104 px high bar.
struct TopBar: View {
    @Environment(\.stage) private var stage

    var body: some View {
        VStack {
            HStack {
                Brand()
                Spacer()
            }
            .frame(height: stage.px(104))
            .padding(.horizontal, stage.px(72))
            Spacer()
        }
    }
}
