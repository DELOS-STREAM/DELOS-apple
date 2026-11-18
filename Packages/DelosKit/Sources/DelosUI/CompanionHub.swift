import DelosData
import Observation
import SwiftUI

/*
 * What the companion screen shows and where it comes from (`CompanionState.kt`, `CompanionPublisher.kt` and
 * `CompanionSession.kt` of DELOS for Android): the shell's screens publish pages, the shell publishes the context of the
 * fallback card, a running stream binds its controller, and the companion window (``CompanionRoot``, on the screen the
 * display host chose) reads them. State goes one way; commands come back only through the closures a page carries, which
 * run the controller's own paths. Nothing here starts anything by itself.
 */

/// One thing the companion window can show of the shell (`CompanionPage`, CompanionPage.kt:32-49): immutable data and the
/// closures of its touch buttons, drawn by [content] inside the companion's own stage.
struct CompanionPage: Equatable {
    /// The identity: another key crossfades, the same key is an update of the same page (a value, a clock) and does not.
    let key: String
    var priority = PagePriority.screen
    /// Stays bright however long nobody touches it (a launch that is still going: the page that is waited at).
    var keepsAwake = false
    /// What the page shows: an equal revision draws the same, so a publisher that runs again changes nothing.
    let revision: AnyHashable
    /// The page's settings help: while the window shows it, the settings screens leave out their own description.
    var isSettingsHelp = false
    let content: @MainActor () -> AnyView

    init(
        key: String, priority: Int = PagePriority.screen, keepsAwake: Bool = false, revision: AnyHashable, isSettingsHelp: Bool = false,
        @ViewBuilder content: @escaping @MainActor () -> some View
    ) {
        self.key = key
        self.priority = priority
        self.keepsAwake = keepsAwake
        self.revision = revision
        self.isSettingsHelp = isSettingsHelp
        self.content = { AnyView(content()) }
    }

    static func == (a: CompanionPage, b: CompanionPage) -> Bool {
        a.key == b.key && a.priority == b.priority && a.keepsAwake == b.keepsAwake && a.revision == b.revision && a.isSettingsHelp == b.isSettingsHelp
    }
}

/// A button of the main screen's hint bar as the companion lists it (`CompanionHint`): the button and its word.
struct CompanionHint: Hashable, Sendable {
    let button: HintButton
    let label: String
}

/// The PC the shell is connected to, for the fallback card: its name, its status as a word and the game running on it.
struct CompanionHostLine: Hashable, Sendable {
    let name: String
    let status: String
    let runningGame: String?
}

/// What the fallback and the welcome card know of the main screen (`ShellContext`, CompanionPage.kt:57-71): its title and
/// one-line purpose, the entries of the hint bar (the very list the bar draws), the connected PC and whether any PC is paired.
struct ShellContext: Hashable, Sendable {
    var title: String
    var purpose: String
    var hints: [CompanionHint]
    var host: CompanionHostLine?
    /// No PC is paired: the welcome card instead of the status card.
    var welcome: Bool

    static let empty = ShellContext(title: "", purpose: "", hints: [], host: nil, welcome: false)
}

/// How the companion window looks: the current profile's colors, reduced motion, interface scale and clock (`CompanionTheme`).
struct CompanionLook: Equatable {
    var colors = DelosColors(palette: .delos, dark: true)
    var reducedMotion = false
    var textScale = 1.0
    var clock = ClockFormat.system
}

/// The stream the companion serves (`CompanionState.Stream`): its controller, which every tile and key goes through.
struct CompanionStream {
    let controller: StreamController
    let pcName: String
    let gameName: String
    let pcID: String
    /// The profile's Fully External Display Mode: the stream goes to a monitor or TV (``ScreenPlanner``).
    let fullExternal: Bool
    /// The requested picture ("1920 × 1080 · HEVC · 120 FPS") for the loader page, set by the stream once it knows its display.
    var requested: String?
}

/// The one exchange between the shell, a stream and the companion window. Lives as long as the app.
@MainActor
@Observable
public final class CompanionHub {
    public static let shared = CompanionHub()

    /// The shell's published pages, by publisher.
    private(set) var published: [UUID: (order: Int, page: CompanionPage)] = [:]
    @ObservationIgnored private var nextOrder = 0
    /// The context of the fallback card, published by the shell.
    var context: ShellContext?
    /// The running stream, bound by its screen while it is shown.
    var stream: CompanionStream? {
        didSet { if (oldValue == nil) != (stream == nil) || oldValue?.fullExternal != stream?.fullExternal { planInputsChanged?() } }
    }
    var look = CompanionLook()
    /// A companion window is on a screen now (set by the display host): only then do the screens build their pages.
    public internal(set) var shown = false
    /// The two screens are a pair (``ScreenPlanner/paired(second:role:)``): Settings offers Main screen and the dimming.
    public internal(set) var paired = false
    /// The window shows a settings help page now (`CompanionSession.showsHelp`): the settings screens leave out their
    /// description and give the list its room.
    var showsHelp = false
    /// The display host listens: whether a stream runs changes where the windows go (``ScreenPlanner``).
    @ObservationIgnored var planInputsChanged: (@MainActor () -> Void)?
    /// The display host lost the screen a stream was on (`DelosStreamActivity.listenForExternalDisplayRemoval`): the stream
    /// is left, as Android finishes it, and the shell comes back on the device's own screen.
    func secondScreenLost() {
        guard let stream, stream.fullExternal else { return }
        stream.controller.closeMenu()
        Task { await stream.controller.leave(quit: false) }
    }

    /// The device's battery for the fallback card's line (the status bar's), published by the shell.
    var battery: BatteryStatus?

    init() {}

    /// Keeps [page] for [token] (nil removes it). The same page again changes nothing.
    func publish(_ token: UUID, _ page: CompanionPage?) {
        guard let page else {
            if published[token] != nil { published[token] = nil }
            return
        }
        if let old = published[token] {
            if old.page != page { published[token] = (old.order, page) }
        } else {
            nextOrder += 1
            published[token] = (nextOrder, page)
        }
    }

    /// The page the shell's window shows (`chooseShellPage`, CompanionPage.kt:73-77): the published one of the highest
    /// priority (the first published on a tie), else the welcome card (no PC paired) or the fallback card.
    var shellPage: CompanionPage {
        Self.choose(published.values.map { ($0.order, $0.page) }, context: context)
    }

    /// The best published page of overlay priority (a stream's result or problem), nil when none: it shows over a stream too.
    var overlayPage: CompanionPage? {
        published.values.filter { $0.page.priority >= PagePriority.overlay }
            .max { a, b in a.page.priority != b.page.priority ? a.page.priority < b.page.priority : a.order > b.order }?.page
    }

    static func choose(_ pages: [(order: Int, page: CompanionPage)], context: ShellContext?) -> CompanionPage {
        let best = pages.max { a, b in a.page.priority != b.page.priority ? a.page.priority < b.page.priority : a.order > b.order }
        if let best { return best.page }
        let context = context ?? .empty
        return context.welcome ? WelcomePage.page(context) : FallbackPage.page(context)
    }
}

extension View {
    /// Publishes the page [make] builds to the companion window while one is shown (`PublishCompanionPage`,
    /// CompanionPublisher.kt:117-128): kept live, nil publishes nothing, and the view leaving removes it. Every publisher
    /// has a token of its own, so a screen that is being replaced clears only what it published.
    func companionPage(_ make: @escaping @MainActor () -> CompanionPage?) -> some View {
        modifier(PublishCompanionPage(make: make))
    }
}

private struct PublishCompanionPage: ViewModifier {
    let make: @MainActor () -> CompanionPage?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        let hub = CompanionHub.shared
        let page = hub.shown ? make() : nil
        content
            .onChange(of: page, initial: true) { _, now in hub.publish(token, now) }
            .onAppear { hub.publish(token, page) }
            .onDisappear { hub.publish(token, nil) }
    }
}
