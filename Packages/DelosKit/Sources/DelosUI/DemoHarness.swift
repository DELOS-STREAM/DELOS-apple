#if DEBUG
import CoreGraphics
import DelosData
import DelosHost
import DelosInput
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// DEBUG only (compiled out of Release): the demo harness, `-DelosDemo YES`. A fake paired PC with games (one of them running),
/// generated artwork and fake SteamGridDB answers, fake game metadata and a command script that drives the real command
/// router, so every screen can be opened with real-looking content in a simulator. Nothing here touches the network, the
/// client identity or the real pairing data: the PC has no address, the stores are a separate suite, the artwork a temporary directory.
///   -DelosDemo YES                      the fake PC and its library, a profile
///   -DelosScreen <name>                 (with -DelosDemo) start (default), home, devices, profile, pair, settings:<tab>, artwork, appsettings, osc
///   -DelosDemoCommands "w1 menu w1 down accept"   commands routed like a controller's: up down left right accept back menu options toast prevtab nexttab, w<seconds>;
///                                       over a stream: streammenu (opens or closes the stream menu, as a controller's Home tap; then
///                                       the directions, accept and back drive the dock, its pages and Quit game);
///                                       every command waits until something can take it (the library loaded, no PC being woken);
///                                       input kinds: touch (a finger begins a touch, through the window's probe), click (the pointer's), pad (a controller's button);
///                                       rightclick (a secondary click at the middle of the focused item, through the router's pointer entry);
///                                       tap (the focused item's own tap, a click after `click`: its press and its action)
///   -DelosDemoApps <n>                  how many apps (default 16; 0 empty)
///   -DelosDemoInput controller|touch|keyboard|pointer   the kind of input the hints and the back arrow start with (controller: a pad counts as connected)
enum DemoHarness {
    static var on: Bool { UserDefaults.standard.bool(forKey: "DelosDemo") }
    static let hostID = "demo-pc"
    static var appCount: Int { UserDefaults.standard.object(forKey: "DelosDemoApps") != nil ? UserDefaults.standard.integer(forKey: "DelosDemoApps") : 16 }

    static var apps: [HostApp] {
        let titles = ["Desktop", "Starfall Odyssey: Definitive Edition", "Hades", "Celeste", "Portal 2", "Hollow Knight: Silksong",
                      "Stardew Valley", "Disco Elysium - The Final Cut", "Control", "Outer Wilds", "Tunic", "Cyberpunk 2077",
                      "Doom Eternal", "Baldur's Gate 3", "Elden Ring", "Remote Input"]
        return titles.prefix(appCount).enumerated().map { HostApp(id: $0.offset + 1, title: $0.element, isHDRSupported: $0.offset % 3 == 0) }
    }

    struct Secrets: SecretStorage {
        func read(account: String) throws -> Data? { Data("fake-key".utf8) }
        func write(_ data: Data, account: String) throws {}
        func delete(account: String) throws {}
    }

    @MainActor static func artwork() -> ArtworkStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "delos-demo-art-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: "delos-demo-art-\(UUID().uuidString)")!
        return ArtworkStore(secrets: Secrets(), defaults: defaults, matches: dir,
                            cache: DiskCache(directory: dir.appending(path: "cache"), budget: 256 << 20, maxEntryBytes: 32 << 20),
                            transport: transport)
    }

    struct Providers: MetadataProviders {
        let available = true
        static let genres = [GameGenre(id: 5, name: "Shooter"), GameGenre(id: 31, name: "Adventure"), GameGenre(id: 12, name: "RPG"),
                             GameGenre(id: 9, name: "Puzzle")]
        func search(_ title: String) async throws -> [MetadataCandidate] {
            let n = abs(title.hashValue % 7)
            return [MetadataCandidate(id: Int64(n + 1), name: title, year: 2018 + n, steamAppIDs: [], genres: [Self.genres[n % 4]],
                                      summary: "A fake game.", platformIDs: [6], ratingCount: 100,
                                      themes: [GameGenre(id: 1 + n % 3, name: ["Fantasy", "Sci-fi", "Horror"][n % 3])])]
        }
        func game(_ id: Int64) async throws -> MetadataCandidate? { nil }
        func hdr(steamAppIDs: [Int64], name: String) async throws -> HDREvidence { HDREvidence(support: name.count % 2 == 0 ? .hdr : .sdr) }
        func completion(steamAppIDs: [Int64], name: String) async throws -> CompletionTime? {
            CompletionTime(id: 1, name: name, seconds: Int64(name.count) * 3600, url: "")
        }
        func steamTags(_ steamAppIDs: [Int64]) async throws -> [String] { [] }
    }

    static func metadataStore() -> MetadataStore {
        let dir = FileManager.default.temporaryDirectory.appending(path: "delos-demo-meta-\(UUID().uuidString)", directoryHint: .isDirectory)
        return MetadataStore(providers: Providers(), cache: DiskCache(directory: dir, budget: 1 << 20, maxEntryBytes: 1 << 16))
    }

    /// The separate suite the demo's profiles and PCs live in: the app's own data is never read or written.
    static let suite = "io.github.meitoncz.delos.demo"

    @MainActor static func seed(hosts: HostStore, profiles: ProfileStore) {
        if profiles.isFirstRun { _ = profiles.create(name: "Player", avatar: 3) }
        hosts.demoInstall(id: hostID, name: "Meiton-PC", online: true, apps: apps, running: apps.count > 3 ? apps[3].id : 0)
        hosts.demoInstall(id: "demo-pc-2", name: "Living room PC", online: false, apps: [], running: 0)
        profiles.setDefaultPC(hostID)
    }

    /// -DelosDemoInput: the kind of input the hints are drawn for at launch. Once only: the root view is made again whenever
    /// the app's body is (and that body, having read the kind here, is when the kind changes), and forcing it again would
    /// undo every touch or key after it.
    @MainActor static func forceInput() {
        guard !inputForced, let name = UserDefaults.standard.string(forKey: "DelosDemoInput") else { return }
        inputForced = true
        let kinds: [String: InputKind] = ["controller": .controller, "touch": .touch, "keyboard": .keyboard, "pointer": .pointer]
        if let kind = kinds[name] { ControllerGlyphs.shared.debugForce(kind) }
    }

    @MainActor private static var inputForced = false

    /// Opens the screen named by -DelosFakeScreen.
    @MainActor static func navigate(_ navigator: Navigator, actions: ShellActions) {
        let screen = UserDefaults.standard.string(forKey: "DelosScreen") ?? "start"
        switch screen {
        case "home": navigator.openHome(hostID: hostID)
        case "devices": navigator.openHome(hostID: hostID); navigator.openFromNavigation(.devices, focus: actions.devicesFocus())
        case "profile": navigator.openHome(hostID: hostID); navigator.openFromNavigation(.profile, focus: "change-avatar")
        case "pair": navigator.push(.pair, focus: "address")
        case "artwork":
            navigator.openHome(hostID: hostID)
            navigator.push(.artwork(hostID: hostID, appID: 2), focus: ArtworkScreen.firstFocus)
        case "appsettings":
            navigator.openHome(hostID: hostID)
            navigator.push(.appSettings(hostID: hostID, appID: 2), focus: GameSettingsScreen.firstFocus())
        case "osc":
            // The on-screen controls' preview, as Settings → Controls opens it
            navigator.openHome(hostID: hostID)
            navigator.openFromNavigation(.settings, focus: SettingsScreen.firstRow(.controls))
            navigator.push(.oscPreview)
        default:
            if screen.hasPrefix("settings"), let tab = SettingsTab.allCases.first(where: { "\($0)" == screen.split(separator: ":").last.map(String.init) }) {
                navigator.openHome(hostID: hostID)
                navigator.openFromNavigation(.settings, focus: SettingsScreen.firstRow(tab))
            }
        }
    }

    /// The commands of -DelosFakeCommands, with the seconds to wait before each.
    @MainActor static var script: [(wait: Double, command: String)] {
        guard let text = UserDefaults.standard.string(forKey: "DelosDemoCommands") else { return [] }
        var wait = 1.0
        var out: [(Double, String)] = []
        for token in text.split(separator: " ") {
            if token.hasPrefix("w"), let seconds = Double(token.dropFirst()) { wait = seconds; continue }
            out.append((wait, String(token)))
            // The stream menu ignores what comes before it has been open a moment (``StreamController/menuGrace``)
            wait = token == "streammenu" ? StreamController.menuGrace + 0.2 : 0.4
        }
        return out
    }

    /// The input commands of the script: `touch` and `click` begin a touch of a finger or of the pointer through the
    /// recognizer the window holds (``TouchKindRecognizer``, so it also shows that the probe is installed), `pad` is a
    /// controller's button press as ``MenuInput`` notes it. True when [name] was one.
    @MainActor static func input(_ name: String) -> Bool {
        switch name {
        case "touch", "click":
            #if os(iOS)
            TouchKindRecognizer.debugBegin(indirect: name == "click")
            #endif
            return true
        case "pad":
            ControllerGlyphs.shared.note(.controller)
            return true
        default:
            return false
        }
    }

    /// `swipe-open` (a drag in from the edge to 70 % of the panel, released slowly), `swipe-peek` (to 30 %: springs back) and
    /// `swipe-close` (to the left by 70 %): a finger's drag of the side menu fed to the router's drag handling at 60 Hz, as
    /// the edge strip and the open menu give it (the simulator has no scripted touch drag). True when [name] was one.
    @MainActor static func sideDrag(_ name: String, router: ShellRouter) async -> Bool {
        let (opening, share): (Bool, Double)
        switch name {
        case "swipe-open": (opening, share) = (true, 0.7)
        case "swipe-peek": (opening, share) = (true, 0.3)
        case "swipe-close": (opening, share) = (false, -0.7)
        default: return false
        }
        let travel = router.sideWidth * share, steps = 30
        router.beginSideDrag(opening: opening)
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(16))
            router.moveSideDrag(travel: travel * Double(step) / Double(steps))
        }
        router.endSideDrag(opening: opening, travel: travel, velocity: 0)
        return true
    }

    /// `rightclick`: a right click (or a two-finger click) at the middle of the focused item of whoever has the pointer
    /// (``ShellRouter/secondaryClick(at:)``), as the window's probe sends it. True when [name] was one.
    @MainActor static func secondaryClick(_ name: String, router: ShellRouter) async -> Bool {
        guard name == "rightclick" else { return false }
        ControllerGlyphs.shared.note(.pointer)
        if let focus = router.pointerFocus, let id = focus.focused, let frame = focus.registeredFrames[id] {
            await router.secondaryClick(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        return true
    }

    /// Posted by `tap` with the focused item's id (`userInfo["id"]`): that ``FocusItem`` runs its own tap, as a finger's or
    /// the pointer's (after `touch` or `click`) would.
    static let tapNotification = Notification.Name("DelosDemoTap")

    /// `tap`: a tap (a click after `click`) on the focused item of whoever has the commands: an open layer or the side menu,
    /// else the screen. True when [name] was one.
    @MainActor static func tap(_ name: String, navigator: Navigator, router: ShellRouter) -> Bool {
        guard name == "tap" else { return false }
        if let id = (router.modalFocus ?? navigator.focus).focused {
            NotificationCenter.default.post(name: tapNotification, object: nil, userInfo: ["id": id])
        }
        return true
    }

    /// Waits (up to 15 s) until the router has a target for a command: a stream's input over a stream, else no PC being
    /// woken (its portal holds every command) and a focused item on the screen. A command sent before the library has
    /// loaded would be lost.
    @MainActor static func waitForTarget(navigator: Navigator, actions: ShellActions) async {
        for _ in 0..<300 {
            if navigator.commandCapture != nil { return }
            if !actions.connection.isActive, navigator.focus.focused != nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `streammenu` over a stream: the stream menu opens (or closes) through the stream's own input path, as the Siri
    /// Remote's menu command does there, the same ``StreamController/openMenu()`` a controller's Home tap calls. True when
    /// [name] was one.
    @MainActor static func streamMenu(_ name: String, navigator: Navigator, router: ShellRouter) -> Bool {
        guard name == "streammenu" else { return false }
        if case .stream = navigator.current { router.route(.options, repeatCount: 0, fromRemote: true) }
        return true
    }

    static func command(_ name: String) -> MenuCommand? {
        switch name {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        case "accept": .accept
        case "back": .back
        case "menu": .menu
        case "options": .options
        case "toast": .toastAction
        case "prevtab": .previousTab
        case "nexttab": .nextTab
        default: nil
        }
    }

    static let transport: SteamGridDB.Transport = { request in
        let url = request.url!
        let ok = { (data: Data) in (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        if url.host() == "cdn.example" {
            let seed = Int(url.lastPathComponent.split(separator: ".")[0]) ?? 1
            let kind = url.pathComponents[1]
            // The animated choices, and every image of about a third of the games (so the library plays some), are APNGs
            let animated = url.pathExtension == "apng" || (seed / 100) % 3 == 0
            return ok(animated ? apng(seed: seed, kind: kind) : png(seed: seed, kind: kind))
        }
        let path = String(url.path().dropFirst("/api/v2/".count))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if path.hasPrefix("search/autocomplete/") {
            let name = path.dropFirst("search/autocomplete/".count).removingPercentEncoding ?? ""
            return ok(Data(#"{"success":true,"data":[{"id":\#(1000 + abs(name.hashValue % 900)),"name":"\#(name)","release_date":1600000000}]}"#.utf8))
        }
        let game = Int(path.split(separator: "/").last ?? "1") ?? 1
        let kind = path.hasPrefix("heroes") ? "hero" : path.hasPrefix("logos") ? "logo" : "cover"
        let styles = kind == "logo" ? ["official", "white", "black", "custom"] : ["alternate", "blurred", "white_logo", "material", "no_logo"]
        let sizes = kind == "hero" ? ["1920x620", "3840x1240"] : ["600x900", "660x930", "342x482"]
        var list: [String] = []
        let animated = param("types") == "animated"
        for id in 1...(animated ? 6 : 24) {
            let style = styles[id % styles.count]
            if let wanted = param("styles"), wanted != style { continue }
            if param("styles") == "material" { continue }
            let size = sizes[id % sizes.count]
            if let wanted = param("dimensions"), !wanted.split(separator: ",").contains(Substring(size)) { continue }
            let gid = game * 100 + id + (animated ? 1000 : 0)
            let parts = size.split(separator: "x")
            let file = "\(gid).\(animated ? "apng" : "png")"
            list.append(#"{"id":\#(gid),"url":"https://cdn.example/\#(kind)/\#(file)","thumb":"https://cdn.example/\#(kind)/\#(file)","width":\#(parts[0]),"height":\#(parts[1]),"style":"\#(style)","score":\#(id * 3 % 40),"author":{"name":"Author \#(id % 7)"},"date":\#(1_700_000_000 + id * 86400),"mime":"image/png"}"#)
        }
        return ok(Data(#"{"success":true,"data":[\#(list.joined(separator: ","))]}"#.utf8))
    }

    static func png(seed: Int, kind: String) -> Data {
        encode([frame(seed: seed, kind: kind, phase: 0.25)], type: .png, delay: nil)
    }

    /// An animated PNG of 16 frames, 120 ms each (a 1.92 s loop, long enough for a game background's cross-faded loop): the
    /// light circle of ``png(seed:kind:)`` travels across the picture.
    static func apng(seed: Int, kind: String) -> Data {
        encode((0..<16).map { frame(seed: seed, kind: kind, phase: Double($0) / 16) }, type: .png, delay: 0.12)
    }

    private static func frame(seed: Int, kind: String, phase: Double) -> CGImage {
        let (w, h) = kind == "hero" ? (960, 310) : kind == "logo" ? (500, 250) : (400, 600)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = Double(seed * 37 % 360) / 360
        func color(_ h: Double, _ b: Double) -> CGColor {
            CGColor(red: min(1, abs(h * 6 - 3) - 1) * b, green: min(1, 2 - abs(h * 6 - 2)) * b, blue: min(1, 2 - abs(h * 6 - 4)) * b, alpha: 1)
        }
        let gradient = CGGradient(colorsSpace: space, colors: [color(hue, 0.9), color((hue + 0.3).truncatingRemainder(dividingBy: 1), 0.5)] as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        context.setFillColor(CGColor(gray: 1, alpha: 0.35))
        let size = min(w, h) / 2
        context.fillEllipse(in: CGRect(x: Double(w - size) * phase, y: Double(h) / 4, width: Double(size), height: Double(size)))
        return context.makeImage()!
    }

    private static func encode(_ frames: [CGImage], type: UTType, delay: Double?) -> Data {
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, frames.count, nil)!
        if delay != nil {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]] as CFDictionary)
        }
        for frame in frames {
            let properties = delay.map { [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: $0]] as CFDictionary }
            CGImageDestinationAddImage(destination, frame, properties)
        }
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}
#endif
