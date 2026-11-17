#if os(macOS)
@testable import DelosData
import DelosHost
import DelosInput
import SwiftUI
import Testing
@testable import DelosUI

/// The D-pad graph of every screen and layer, from the real views laid out on every shape of screen: every item is reachable
/// from the first focus, none is a dead end, none overlaps another or lies outside the window unless it scrolls, and the
/// edges that matter go where Android's go. Set `DELOS_DUMP=<name>` to print a screen's edges.
@MainActor
@Suite struct NavigationGraphTests {
    /// One screen to audit: what it shows and where the focus starts.
    struct Case {
        var name: String
        var initial: String?
        var minItems = 1
        /// Items of a list or a row that scrolls: they may lie outside the window.
        var scrolled: (String) -> Bool = { _ in false }
        /// Items another button reaches (Y opens Settings' search; the D-pad does not).
        var byButton: Set<String> = []
        var allowOverlap: (String, String) -> Bool = { _, _ in false }
        /// A screen with nothing to focus (every button is switched off): the graph has no items, and the way back is B.
        var nothingToFocus = false
    }

    private func audit(
        _ c: Case, on d: TestDevice, pcs: [(id: String, name: String, online: Bool)]? = nil, metadataOn: Bool = true, key: String? = nil,
        apps: [HostApp] = ShellFixture.library, build: (ShellFixture) -> FocusModel = { _ in FocusModel() },
        seed: (ShellFixture) -> Void = { _ in }, waitFor: String? = nil,
        @ViewBuilder _ content: @escaping (ShellFixture, FocusModel) -> some View
    ) async -> [String] {
        let started = ContinuousClock.now
        defer { print("TIMING \(c.name) on \(d.name): \(ContinuousClock.now - started)") }
        let fx = pcs.map { ShellFixture(pcs: $0, apps: apps, key: key, metadataOn: metadataOn) }
            ?? ShellFixture(apps: apps, key: key, metadataOn: metadataOn)
        seed(fx)
        let model = build(fx)
        let host = ScreenHost(size: d.size, safeArea: d.safe) { fx.environment(ZStack { content(fx, model) }) }
        if let waitFor { await host.until { model.registeredFrames[waitFor] != nil } }
        let frames = await host.settle(model, atLeast: c.minItems)
        let graph = FocusGraph(model: model, frames: frames)
        if c.nothingToFocus { return frames.isEmpty ? [] : ["\(c.name) on \(d.name): \(frames.keys) should not be focusable"] }
        if ProcessInfo.processInfo.environment["DELOS_DUMP"] == c.name { print("DUMP \(c.name) on \(d.name)\n\(graph.dump)") }
        let initial: AnyHashable? = model.focused ?? c.initial.map { AnyHashable($0) }
        var problems = graph.problems(
            initial: initial, bounds: CGRect(origin: .zero, size: host.size), scrolled: { c.scrolled("\($0)") },
            allowOverlap: { c.allowOverlap("\($0)", "\($1)") })
        // What a button reaches is not the D-pad's to reach
        problems.removeAll { line in c.byButton.contains { line.contains("not reachable") && line.contains("\"\($0)\"") } }
        return problems.map { "\(c.name) on \(d.name): \($0)" }
    }

    private func report(_ problems: [String]) {
        for line in problems {
            print("PROBLEM", line)
            Issue.record(Comment(rawValue: line))
        }
    }

    // MARK: The first run, start, devices, profile, pairing

    @Test(arguments: TestDevice.all) func theFirstRunScreens(_ d: TestDevice) async {
        report(await audit(Case(name: "boot", initial: "begin", minItems: 2), on: d, build: { _ in FocusModel(initial: "begin") }) { _, focus in
            BootScreen(focus: focus, onBegin: {}, onSkip: {})
        })
        report(await audit(Case(name: "boot without skip", initial: "begin"), on: d, build: { _ in FocusModel(initial: "begin") }) { _, focus in
            BootScreen(focus: focus, onBegin: {}, onSkip: nil)
        })
        for editing in [false, true] {
            report(await audit(
                Case(name: "create profile editing=\(editing)", initial: "\(CreateProfileScreen.avatarID(0))", minItems: 18), on: d,
                build: { _ in FocusModel(initial: CreateProfileScreen.avatarID(0)) }
            ) { fx, focus in
                CreateProfileScreen(editing: editing, initial: editing ? fx.profiles.current : nil, focus: focus, actions: fx.actions) { _, _ in }
                fx.topBar(for: .createProfile(editing: editing), focus: focus)
            })
        }
    }

    @Test(arguments: TestDevice.all) func theStartScreenWithNoOneOneAndManyPCs(_ d: TestDevice) async {
        let many = (1...4).map { (id: "PC-\($0)", name: "Gaming PC \($0)", online: $0 % 2 == 1) }
        let sets: [(String, [(id: String, name: String, online: Bool)])] = [("none", []), ("one", [(ShellFixture.hostID, "Meiton-PC", true)]), ("many", many)]
        for (label, pcs) in sets {
            report(await audit(
                Case(name: "start with \(label) PCs", initial: nil, minItems: 2, scrolled: { $0.hasPrefix("pc-") || $0 == "pair" }), on: d, pcs: pcs,
                build: { FocusModel(initial: $0.actions.startFocus()) }
            ) { fx, focus in
                StartScreen(focus: focus, profile: fx.profiles.current, defaultPC: nil, actions: fx.actions, onPC: { _ in }, onPair: {})
                fx.topBar(for: .start, focus: focus)
            })
            report(await audit(
                Case(name: "devices with \(label) PCs", initial: nil, minItems: 2, scrolled: { $0.hasPrefix("pc-") || $0 == "pair" }), on: d, pcs: pcs,
                build: { FocusModel(initial: $0.actions.devicesFocus()) }
            ) { fx, focus in
                DevicesScreen(focus: focus, activeID: pcs.first?.id, actions: fx.actions, onPair: {})
                fx.topBar(for: .devices, focus: focus)
            })
        }
    }

    @Test(arguments: TestDevice.all) func theProfileAndPairingScreens(_ d: TestDevice) async {
        report(await audit(
            Case(name: "profile", initial: "change-avatar", minItems: 8, scrolled: { ["change-avatar", "rename", "switch", "add", "delete"].contains($0) }),
            on: d, build: { _ in FocusModel(initial: "change-avatar") }
        ) { fx, focus in
            ProfileScreen(profile: fx.profiles.current!, count: 1, focus: focus, actions: fx.actions, onChangeAvatar: {}, onAdd: {})
            fx.topBar(for: .profile, focus: focus)
        })
        report(await audit(
            Case(name: "pair", initial: "address", minItems: 3, scrolled: { $0 == "address" || $0 == "search" || $0.hasPrefix("host-") }), on: d,
            build: { _ in FocusModel(initial: "address") }
        ) { fx, focus in
            PairPCScreen(focus: focus, onHost: { _ in }, onCode: { _ in }, onAddress: {})
            fx.topBar(for: .pair, focus: focus)
        })
        report(await audit(Case(name: "pin", initial: "cancel"), on: d, build: { _ in FocusModel(initial: "cancel") }) { fx, focus in
            PinScreen(hostID: "none", code: nil, focus: focus, feedback: nil, onPaired: {}, onFailed: { _ in }, onCancel: {})
            fx.topBar(for: .pin(hostID: "none"), focus: focus)
        })
    }

    // MARK: The library

    private func home(_ d: TestDevice, _ name: String, apps: [HostApp] = ShellFixture.library, metadataOn: Bool = true, seeded: Bool = false,
                      minItems: Int, initial: String? = "app-1", filtered: Bool = false) async -> [String] {
        await audit(
            Case(name: name, initial: initial, minItems: minItems, scrolled: { $0.hasPrefix("app-") }), on: d, metadataOn: metadataOn, apps: apps,
            build: { _ in FocusModel(initial: HomeScreen.initialFocus) },
            seed: { fx in
                if seeded { fx.seedMetadata() }
                if filtered { fx.actions.libraryFilters.set(MetadataFilters(genreID: 999), hostID: ShellFixture.hostID) }
            }
        ) { fx, focus in
            HomeScreen(hostID: ShellFixture.hostID, focus: focus, actions: fx.actions)
            fx.topBar(for: .home(hostID: ShellFixture.hostID), focus: focus)
        }
    }

    @Test(arguments: TestDevice.all) func theLibraryInEveryState(_ d: TestDevice) async {
        report(await home(d, "library with the filter", seeded: true, minItems: 15))
        report(await home(d, "library without a metadata service", metadataOn: false, minItems: 14))
        report(await home(d, "library with one game", apps: [HostApp(id: 10, title: "Hades")], minItems: 5, initial: "app-10"))
        report(await home(d, "library with a filter that leaves nothing", seeded: true, minItems: 4, initial: LibraryFilterIDs.emptyReset, filtered: true))
        // Nothing to focus but the navigation: the focus must still be on something the D-pad can use
        report(await home(d, "library with no games", apps: [], minItems: 3, initial: nil))
    }

    // MARK: Layers

    private func layer(_ d: TestDevice, _ name: String, minItems: Int, initial: String, byButton: Set<String> = [],
                       open: @escaping (ShellFixture) -> Void, @ViewBuilder _ content: @escaping (ShellFixture, FocusModel) -> some View) async -> [String] {
        await audit(Case(name: name, initial: initial, minItems: minItems, byButton: byButton), on: d, build: { fx in
            open(fx)
            return fx.layers.focus
        }, content)
    }

    @Test(arguments: TestDevice.all) func theMenusDialogsAndSideMenu(_ d: TestDevice) async {
        let anchor = CGRect(x: 120, y: 400, width: 200, height: 300)
        // A game's menu: not running, running here, another game running; a built-in entry has no artwork or metadata rows
        for (label, app, running) in [("idle game", 2, 0), ("running game", 2, 12), ("other game running", 3, 12), ("built-in entry", 0, 0)] {
            report(await layer(d, "game menu of an \(label)", minItems: 3, initial: "\(Layers.rowID(running == 12 && app == 3 ? 1 : 0))", open: { fx in
                if running != 0, var record = fx.hosts.host(ShellFixture.hostID) {
                    record.runningAppID = ShellFixture.library[2].id
                    fx.hosts.store(record)
                }
                fx.layers.openContextMenu(fx.actions.gameMenu(hostID: ShellFixture.hostID, app: ShellFixture.library[app])!, anchor: anchor)
            }) { fx, _ in
                ContextMenuLayer(layers: fx.layers, menu: fx.actions.gameMenu(hostID: ShellFixture.hostID, app: ShellFixture.library[app])!, anchor: anchor)
            })
        }
        report(await layer(d, "profiles menu", minItems: 3, initial: "\(Layers.rowID(0))", open: { fx in
            fx.layers.openContextMenu(fx.actions.profilesMenu(), anchor: CGRect(x: 600, y: 30, width: 150, height: 50))
        }) { fx, _ in
            ContextMenuLayer(layers: fx.layers, menu: fx.actions.profilesMenu(), anchor: CGRect(x: 600, y: 30, width: 150, height: 50))
        })
        let spec = DialogSpec(title: "Rename", note: "Name it", fields: [DialogField(icon: Symbols.edit, initial: "A")], confirm: "OK") { _ in true }
        report(await layer(d, "dialog with a field", minItems: 3, initial: "\(DialogLayer.fieldID(0))", open: { $0.layers.openDialog(spec) }) { fx, _ in
            DialogLayer(layers: fx.layers, spec: spec, navigator: fx.navigator)
        })
        let question = DialogSpec(title: "Sure?", note: "Really", fields: [], confirm: "Yes") { _ in true }
        report(await layer(d, "dialog without a field", minItems: 2, initial: "\(DialogLayer.confirmID)", open: { $0.layers.openDialog(question) }) { fx, _ in
            DialogLayer(layers: fx.layers, spec: question, navigator: fx.navigator)
        })
        for hidden in [false, true] {
            report(await audit(
                Case(name: "side menu hidden-row=\(hidden)", initial: QuickSettings.ids[0], minItems: hidden ? 6 : 5, scrolled: { _ in d.size.height < 600 }), on: d,
                build: { _ in FocusModel(initial: QuickSettings.ids[0]) }
            ) { fx, focus in
                SideMenu(profile: fx.profiles.current, pc: SidePC(name: "Meiton-PC", state: .online), focus: focus, appearance: Appearance(), onStep: { _, _ in },
                         onSettings: {}, hidden: hidden ? SideMenu.HiddenRow(showing: false, note: "2 hidden on Meiton-PC") : nil)
            })
        }
    }

    @Test(arguments: TestDevice.all) func theLibraryFilterSheet(_ d: TestDevice) async {
        let fx = ShellFixture()
        fx.seedMetadata()
        let games = ShellFixture.library.map { fx.metadata.data(for: $0) }
        let state = LibraryFilterState(filters: MetadataFilters(), games: games, matching: games.count)
        let start = LibraryFilterIDs.start(MetadataFilters(), genres: LibraryFilter.genres(games))
        report(await audit(
            Case(name: "library filter sheet", initial: start, minItems: 10, scrolled: { _ in true }), on: d,
            build: { _ in FocusModel(initial: start) }
        ) { _, focus in
            LibraryFilterSheet(state: state, focus: focus, onChange: { _ in }, onReset: {}, onClose: {})
        })
    }

    // MARK: Settings

    @Test(arguments: TestDevice.all) func everyTabOfSettings(_ d: TestDevice) async {
        for tab in SettingsTab.availableCases {
            report(await audit(
                Case(name: "settings \(tab)", initial: SettingsScreen.firstRow(tab), minItems: 3,
                     scrolled: { !$0.hasPrefix("nav-") && $0 != SettingsScreen.searchID }, byButton: [SettingsScreen.searchID]), on: d,
                build: { _ in FocusModel(initial: SettingsScreen.firstRow(tab)) }
            ) { fx, focus in
                SettingsHost(fx: fx, focus: focus, tab: tab)
                fx.topBar(for: .settings, focus: focus)
            })
        }
    }

    @Test(arguments: TestDevice.all) func theAppSettingsOfAGame(_ d: TestDevice) async {
        report(await audit(
            Case(name: "app settings", initial: GameSettingsScreen.firstFocus(), minItems: 3,
                 scrolled: { $0 != GameSettingsScreen.resetAllID && !$0.hasPrefix("nav-") }), on: d,
            build: { _ in FocusModel(initial: GameSettingsScreen.firstFocus()) }
        ) { fx, focus in
            GameSettingsScreen(hostID: ShellFixture.hostID, app: ShellFixture.library[2], focus: focus, navigator: fx.navigator, actions: fx.actions,
                               profileID: fx.profiles.current!.id)
            fx.topBar(for: .appSettings(hostID: ShellFixture.hostID, appID: 11), focus: focus)
        })
    }

    // MARK: Artwork

    @Test(arguments: TestDevice.all) func theArtworkScreen(_ d: TestDevice) async {
        report(await audit(
            Case(name: "artwork grid", initial: ArtworkScreen.firstFocus, minItems: 6, scrolled: { $0.hasPrefix("art-") && $0 != ArtworkScreen.searchID && $0 != ArtworkScreen.filterID }),
            on: d, key: "key", build: { _ in FocusModel(initial: ArtworkScreen.firstFocus) }, waitFor: ArtworkScreen.tileID(1)
        ) { fx, focus in
            ArtworkScreen(hostID: ShellFixture.hostID, app: ShellFixture.library[2], focus: focus, navigator: fx.navigator, actions: fx.actions)
            fx.topBar(for: .artwork(hostID: ShellFixture.hostID, appID: 11), focus: focus)
        })
    }
}
#endif
