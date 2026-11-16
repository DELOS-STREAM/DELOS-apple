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
                title: String(localized: "Welcome", bundle: .module),
                sub: String(localized: "Pair a PC to start playing.", bundle: .module)
            )
            HStack(alignment: .top, spacing: stage.px(56)) {
                FocusItem(id: "pair", model: focus, action: {}) { focused in
                    CircleItem(
                        icon: Symbols.addLink,
                        label: String(localized: "Pair a new PC", bundle: .module),
                        meta: String(localized: "Vibepollo, Apollo or Sunshine", bundle: .module),
                        focused: focused
                    )
                }
                FocusItem(id: "settings", model: focus, action: {}) { focused in
                    CircleItem(
                        icon: Symbols.settings,
                        label: String(localized: "Settings", bundle: .module),
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
