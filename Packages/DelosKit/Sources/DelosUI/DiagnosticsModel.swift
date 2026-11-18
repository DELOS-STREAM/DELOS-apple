import DelosCore
import DelosData
import DelosHost
import Foundation
import Metal
import Network
import Observation
import SwiftUI
import Synchronization
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The diagnostics of the app (docs/DIAGNOSTICS.md): the rolling log, the crash capture and the system's crash and hang
/// records, started once when the app launches (`DiagLog.init` and `CrashReporter.install` of DELOS for Android's
/// `DelosApplication`).
public enum Diagnostics {
    #if canImport(MetricKit) && !os(tvOS)
    @MainActor private static var systemExits: SystemExitDiagnostics?
    #endif
    @MainActor private static var observers: [NSObjectProtocol] = []

    @MainActor public static func start() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        DiagLog.start(processLine: "Process started: Delos \(version) (\(DeviceFacts.buildType)), build \(build), pid \(getpid())")
        CrashReporter.install()
        #if canImport(MetricKit) && !os(tvOS)
        // Diagnostics of earlier runs can arrive after the start: they are offered as soon as they come
        systemExits = SystemExitDiagnostics { Task { @MainActor in ProblemOffers.shared.detect() } }
        #endif
        logDisplays()
    }

    /// One line per display at the start and whenever one is connected or removed (tag `Display`, `DisplayInventory` of DELOS
    /// for Android); the names are the system's, never the user's.
    @MainActor private static func logDisplays() {
        for line in DisplayFacts.all().map(\.logLine) { DiagLog.i("Display", "Display present: \(line)") }
        #if os(iOS) || os(tvOS)
        let names: [Notification.Name] = [UIScene.willConnectNotification, UIScene.didDisconnectNotification, UIScreen.modeDidChangeNotification]
        #else
        let names: [Notification.Name] = [NSApplication.didChangeScreenParametersNotification]
        #endif
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let what = note.name.rawValue
                MainActor.assumeIsolated {
                    DiagLog.i("Display", "Displays changed (\(what)): " + DisplayFacts.all().map(\.logLine).joined(separator: "; "))
                }
            })
        }
    }
}

/// What a display is, for the Debug info rows and the log (`DisplayInventory` of DELOS for Android): the screen of this device
/// or of the Mac, an external display (AirPlay or a cable), never anything the user named.
struct DisplayFacts: Equatable {
    enum Role { case main, external }
    let id: String
    let name: String
    let role: Role
    let details: String

    var logLine: String { "\(name), \(role == .main ? "main" : "external"), \(details.replacingOccurrences(of: "\n", with: ", "))" }

    @MainActor static func all() -> [DisplayFacts] {
        #if os(iOS) || os(tvOS)
        // The screens of the connected scenes, this device's own first (UIScreen.screens is deprecated)
        var screens = [UIScreen.main]
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where !screens.contains(scene.screen) { screens.append(scene.screen) }
        return screens.enumerated().map { index, screen in
            let size = screen.nativeBounds.size
            let details = "size: \(Int(size.width))x\(Int(size.height)) px\nscale: \(screen.nativeScale)\nrefresh: \(screen.maximumFramesPerSecond) Hz"
            return DisplayFacts(id: "\(index)", name: index == 0 ? DeviceFacts.kind : "External display \(index)",
                                role: screen == UIScreen.main ? .main : .external, details: details)
        }
        #else
        return NSScreen.screens.enumerated().map { index, screen in
            let scale = screen.backingScaleFactor
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "\(index)"
            let builtIn = CGDisplayIsBuiltin(CGDirectDisplayID(UInt32(id) ?? 0)) != 0
            let details = "size: \(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale)) px\nscale: \(scale)\n"
                + "refresh: \(screen.maximumFramesPerSecond) Hz\nbuilt-in: \(builtIn ? "yes" : "no")"
            return DisplayFacts(id: id, name: screen.localizedName, role: screen == NSScreen.main ? .main : .external, details: details)
        }
        #endif
    }
}

/// The facts of this device for the report and Debug info (`DeviceInfoCollector` of DELOS for Android).
enum DeviceFacts {
    static var buildType: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    /// "iPhone", "iPad", "Apple TV" or "Mac".
    static var kind: String {
        #if os(tvOS)
        "Apple TV"
        #elseif os(macOS)
        "Mac"
        #else
        MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
        #endif
    }

    /// The model identifier ("iPhone17,1", "Mac16,10"); in the simulator the one it simulates.
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(macOS)
        return sysctl("hw.model") ?? "unknown"
        #else
        return sysctl("hw.machine") ?? "unknown"
        #endif
    }

    /// "iOS 26.1".
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if os(tvOS)
        let name = "tvOS"
        #elseif os(macOS)
        let name = "macOS"
        #else
        let name = MainActor.assumeIsolated { UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS" }
        #endif
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "\(name) \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    static var systemBuild: String { sysctl("kern.osversion") ?? "unknown" }

    /// The Darwin kernel's version ("25.1.0") and its whole line.
    static var kernel: (version: String, full: String) {
        (sysctl("kern.osrelease") ?? "unknown", sysctl("kern.version") ?? "unknown")
    }

    /// The Metal device's name ("Apple A18 Pro GPU").
    static var gpu: String { MTLCreateSystemDefaultDevice()?.name ?? "unknown" }

    /// The chip: the CPU's own name on a Mac, else the GPU's without "GPU" (iOS does not name its chip otherwise).
    static var chip: String {
        if let brand = sysctl("machdep.cpu.brand_string") { return brand }
        let gpu = gpu
        return gpu.hasSuffix(" GPU") ? String(gpu.dropLast(4)) : gpu
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    /// The main display's size, refresh rate and scale.
    @MainActor static var screen: String {
        #if os(macOS)
        guard let screen = NSScreen.main else { return "unknown" }
        let scale = screen.backingScaleFactor
        return "\(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale)) at \(screen.maximumFramesPerSecond) Hz, scale \(scale)"
        #else
        let screen = UIScreen.main
        return "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height)) at \(screen.maximumFramesPerSecond) Hz, scale \(screen.nativeScale)"
        #endif
    }

    /// The kind of the network in use, never its name.
    static func network() async -> String {
        let monitor = NWPathMonitor()
        let once = Mutex(false)
        let kind: String = await withCheckedContinuation { continuation in
            @Sendable func finish(_ text: String) {
                if once.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: text) }
            }
            monitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return finish("none") }
                if path.usesInterfaceType(.wiredEthernet) { return finish("Ethernet") }
                if path.usesInterfaceType(.wifi) { return finish("Wi-Fi") }
                if path.usesInterfaceType(.cellular) { return finish("cellular") }
                finish("other")
            }
            monitor.start(queue: DispatchQueue(label: "DiagNetwork"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { finish("unknown") }
        }
        monitor.cancel()
        return kind
    }

    /// The device block of a report: the facts and the stream settings of [profileID].
    @MainActor static func info(profileID: String?) async -> DeviceInfo {
        let bundle = Bundle.main
        let screen = screen
        let kind = kind
        let settings = StreamSettingsSnapshot.read(StreamSettingsStore().load(profile: profileID ?? ""))
        let network = await network()
        return DeviceInfo(
            delosVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?", buildType: buildType,
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", deviceKind: kind, model: model,
            system: system, systemBuild: systemBuild, chip: chip, architecture: architecture, gpu: gpu, screen: screen, network: network,
            locale: Locale.current.identifier(.bcp47), timeZone: DeviceInfo.utcOffset(TimeZone.current.secondsFromGMT()), settings: settings)
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// The values the scrubber removes by value (`ScrubContextCollector` of DELOS for Android): the PCs (their names, the names
/// given in DELOS, their addresses and ids), the profiles, this device's own name and its user, the client id and the
/// SteamGridDB key, read at export time so a PC added or renamed a minute ago is covered.
enum ScrubFacts {
    @MainActor static func context(hosts: HostStore, profiles: ProfileStore, artwork: ArtworkStore) -> ScrubContext {
        var pcNames: [String] = [], addresses: [String] = [], names: [String] = [], identifiers: [String] = []
        for host in hosts.hosts {
            pcNames.append(host.serverName)
            if let custom = host.customName { pcNames.append(custom) }
            identifiers.append(host.id)
            if let mac = host.macAddress { addresses.append(mac) }
            for address in [host.localAddress, host.remoteAddress, host.manualAddress, host.activeAddress] {
                if let address { addresses.append(address.host) }
            }
        }
        for profile in profiles.profiles.all {
            names.append(profile.name)
            identifiers.append(profile.id)
        }
        #if os(macOS)
        if let computer = Host.current().localizedName { names.append(computer) }
        names.append(NSUserName())
        names.append(NSFullUserName())
        #else
        names.append(UIDevice.current.name)
        #endif
        if let uniqueID = ClientIdentityStore().storedUniqueID() { identifiers.append(uniqueID) }
        func clean(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return ScrubContext(pcNames: clean(pcNames), hostAddresses: clean(addresses), names: clean(names), identifiers: clean(identifiers),
                            secrets: clean([artwork.apiKey]))
    }
}

/// What a report or Debug info hands to the user (`DiagExport` and `ProblemReporter` of DELOS for Android): the report is built
/// and scrubbed off the main thread from the PC list as it is now, and leaves the device only through the share sheet, the
/// clipboard, a saved file or the report service, each started by the user.
@MainActor
struct DiagnosticsExport {
    let hosts: HostStore
    let profiles: ProfileStore
    let artwork: ArtworkStore

    /// Where a saved report goes on this platform: the app's Documents folder, which the Files app shows as DELOS (iPhone,
    /// iPad), or Downloads (Mac); Apple TV cannot save one.
    nonisolated static var saveFolder: URL? {
        #if os(tvOS)
        nil
        #elseif os(macOS)
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        #endif
    }

    /// The English words for that folder, for the issue draft.
    nonisolated static var saveFolderWords: String {
        #if os(macOS)
        "the Downloads folder"
        #else
        "the DELOS folder of the Files app"
        #endif
    }

    /// The device and the PCs as they are now; built on the main actor (the stores live there).
    private func facts() async -> (DeviceInfo, LogScrubber) {
        let context = ScrubFacts.context(hosts: hosts, profiles: profiles, artwork: artwork)
        let info = await DeviceFacts.info(profileID: profiles.current?.id)
        return (info, LogScrubber(context: context))
    }

    /// The scrubbed report of the whole log, exactly as Share sends it.
    func report() async -> DiagnosticReport { await prepare(problem: nil).report }

    /// The scrubbed device block and the newest 100 lines, for the clipboard.
    func summary() async -> DiagnosticReport {
        let (info, scrubber) = await facts()
        return await Task.detached(priority: .utility) {
            DiagnosticReports.summary(info: info, rawLog: DiagLog.readAll(), scrubber: scrubber, generated: DiagnosticReports.generated())
        }.value
    }

    /// The report of [problem] (nil: started from Debug info, no problem section) and the way to its prefilled address.
    func prepare(problem: Problem?) async -> PreparedReport {
        let (info, scrubber) = await facts()
        return await Task.detached(priority: .utility) {
            let generated = DiagnosticReports.generated()
            let sections = problem.map { [("Problem", ProblemIssue.section($0, detectedAt: generated))] } ?? []
            let report = DiagnosticReports.build(info: info, rawLog: DiagLog.readAll(), scrubber: scrubber, generated: generated, sections: sections)
            return PreparedReport(report: report, fileName: DiagnosticReports.fileName(), folder: Self.saveFolderWords) { attachment in
                let draft = problem.map { ProblemIssue.draft($0, info: info, attachment: attachment) }
                    ?? ProblemIssue.manualDraft(info: info, attachment: attachment)
                return IssueURL.build(draft, scrub: scrubber.scrub)
            }
        }.value
    }

    /// The whole report: upload, or save, and the address of the draft.
    func submit(problem: Problem?, mode: ReportMode) async -> ReportResult {
        let prepared = await prepare(problem: problem)
        return await ReportSubmission.run(prepared, mode: mode, uploader: .shared) { report, name in
            await Self.save(report, name: name)
        }
    }

    /// Writes [report] into the platform's save folder as [name]; false when that failed or there is none.
    nonisolated static func save(_ report: DiagnosticReport, name: String) async -> Bool {
        guard let folder = saveFolder else { return false }
        return await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(report.text.utf8).write(to: folder.appendingPathComponent(name), options: .atomic)
                return true
            } catch {
                DiagLog.w("Report", "The log could not be saved: \(type(of: error))")
                return false
            }
        }.value
    }

    /// The folder of shared copies (`cache/diagnostics`): an earlier copy is removed before a new one is written.
    nonisolated static var shareFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("diagnostics", isDirectory: true)
    }

    nonisolated static func writeForSharing(_ report: DiagnosticReport) throws -> URL {
        let folder = shareFolder
        clearShared()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(DiagnosticReports.fileName())
        try Data(report.text.utf8).write(to: file, options: .atomic)
        return file
    }

    nonisolated static func clearShared() {
        for file in (try? FileManager.default.contentsOfDirectory(at: shareFolder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// The system's share sheet with the file at [url]; false when there is nothing to show it from.
    static func share(_ url: URL) -> Bool {
        #if os(iOS)
        guard let root = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else {
            return false
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // An iPad shows the sheet as a popover: from the middle of the screen, without an arrow
        sheet.popoverPresentationController?.sourceView = top.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        sheet.popoverPresentationController?.permittedArrowDirections = []
        top.present(sheet, animated: true)
        return true
        #elseif os(macOS)
        guard let view = NSApp.keyWindow?.contentView else { return false }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
        return true
        #else
        return false
        #endif
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// The browser with [address]; false when it cannot be opened (Apple TV has no browser).
    static func openIssue(_ address: String) async -> Bool {
        guard let url = URL(string: address) else { return false }
        #if os(iOS)
        return await UIApplication.shared.open(url)
        #elseif os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    /// Apple TV cannot save, share or copy, nor open a browser.
    static var canHandOver: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }
}

/// The toasts of a report in the user's language (`ReportOutcomeText`): what happened to the log and, after a failed upload, why.
enum ReportOutcomeText {
    static var uploading: String { L("report_uploading") }

    static func text(_ result: ReportResult) -> String {
        switch result {
        case .uploaded(_, let link, _):
            return uploaded(link)
        case let .saved(_, name, failure?):
            #if os(iOS)
            return L("report_upload_failed_saved_files", reason(failure), name)
            #else
            return L("report_upload_failed_saved", reason(failure), name)
            #endif
        case .saved(_, let name, nil):
            #if os(iOS)
            return L("shell_report_saved_files", name)
            #else
            return L("shell_report_saved", name)
            #endif
        case .notSaved(_, let failure?):
            return L("report_upload_failed_not_saved", reason(failure))
        case .notSaved(_, nil):
            return L("shell_report_save_failed")
        }
    }

    /// Apple TV cannot open the draft, so its toast shows the link itself.
    private static func uploaded(_ link: String) -> String {
        #if os(tvOS)
        L("report_uploaded_tv", link)
        #else
        L("report_uploaded")
        #endif
    }

    static func reason(_ failure: UploadFailure) -> String {
        switch failure {
        case .offline: L("report_reason_offline")
        case .timeout: L("report_reason_timeout")
        case .rateLimited, .dailyLimit: L("report_reason_busy")
        case .tooLarge: L("report_reason_too_large")
        case .serviceError, .rejected, .malformed: L("report_reason_service")
        }
    }

    /// The label of "Save the log … instead" here.
    static var saveLabel: String {
        #if os(iOS)
        L("report_save_files")
        #else
        L("report_save_downloads")
        #endif
    }

    /// The card's note: what Report does in this build on this device.
    static var cardNote: String {
        let uploads = ReportUploader.shared.enabled
        #if os(tvOS)
        return uploads ? L("shell_problem_note_upload_tv") : L("shell_problem_note_tv")
        #elseif os(iOS)
        return uploads ? L("shell_problem_note_upload") : L("shell_problem_note_files")
        #else
        return uploads ? L("shell_problem_note_upload") : L("shell_problem_note")
        #endif
    }
}

/// A problem of an earlier run, or a failed stream, to offer a report for (`shell.problem` of DELOS for Android): it stays until
/// the user reports or dismisses it, and each problem is offered once (``ProblemMonitor``).
@MainActor
@Observable
final class ProblemOffers {
    static let shared = ProblemOffers()

    static let reportID = "problem-report"
    static let dismissID = "problem-dismiss"
    static let saveID = "problem-save"

    private(set) var problem: Problem? {
        didSet { if problem != nil, problem?.id != oldValue?.id { focus = FocusModel(initial: Self.reportID) } }
    }
    /// The card's own focus: it starts on Report this problem.
    private(set) var focus = FocusModel(initial: ProblemOffers.reportID)

    /// Looks for a problem of an earlier run (at the start, and when the system delivers diagnostics later).
    func detect() {
        Task {
            let found = await Task.detached(priority: .utility) { ProblemMonitor.detect() }.value
            if let found, problem == nil { show(found) }
        }
    }

    /// A stream failed: the card follows once the result has been answered (it shows on the start and home screens only).
    func streamFailed(title: String, details: String?) {
        Task {
            let found = await Task.detached(priority: .utility) { ProblemMonitor.streamFailed(title: title, details: details) }.value
            if let found, problem == nil { show(found) }
        }
    }

    private func show(_ found: Problem) {
        withAnimation(.easeOut(duration: 0.3)) { problem = found }
    }

    /// Whether the card shows now (`offerShown`): on the start and home screens, with no layer, side menu or portal up.
    func shown(screen: Screen, layerOpen: Bool, sideMenu: Bool, portal: Bool) -> Bool {
        guard problem != nil, !layerOpen, !sideMenu, !portal else { return false }
        if case .home = screen { return true }
        return screen == .start
    }

    /// Whether Report does something here: Apple TV cannot save the log or open the draft, so only an upload can report.
    static var canReport: Bool { DiagnosticsExport.canHandOver || ReportUploader.shared.enabled }

    /// Dismiss: the problem is resolved, the screen keeps its focus.
    func dismiss() {
        guard let problem else { return }
        withAnimation(.easeOut(duration: 0.25)) { self.problem = nil }
        ProblemMonitor.resolve(problem)
    }

    /// Report this problem: upload the cleaned log and open the prefilled GitHub draft with its link; when the upload is off,
    /// fails or the user chose to save it, save the log and let the user attach it (docs/DIAGNOSTICS.md).
    func report(_ mode: ReportMode, export: DiagnosticsExport, toasts: Toasts, feedback: Feedback?) {
        guard let problem else { return }
        withAnimation(.easeOut(duration: 0.25)) { self.problem = nil }
        Task {
            if mode == .upload, ReportUploader.shared.enabled { toasts.show(ReportOutcomeText.uploading, icon: Symbols.reportIssue) }
            let result = await export.submit(problem: problem, mode: mode)
            ProblemMonitor.resolve(problem)
            toasts.show(ReportOutcomeText.text(result), icon: result.succeeded ? Symbols.checkCircle : Symbols.warning, durationMs: 6_500)
            guard DiagnosticsExport.canHandOver else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if await !DiagnosticsExport.openIssue(result.issueURL) {
                feedback?.play(.error)
                toasts.show(L("shell_report_no_browser"), icon: Symbols.error)
            }
        }
    }
}
