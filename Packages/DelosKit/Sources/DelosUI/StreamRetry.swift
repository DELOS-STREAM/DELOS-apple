import DelosData
import DelosHost
import Foundation

/// Try again on the result of a failed stream (`retryStream` in DELOS for Android's `Shell.kt`): the same game on the same
/// PC, once the PC is paired and online (waited for up to 4 s) and the game is still in its library (up to 5 s). Otherwise
/// the result closes, back to the library, with an ERROR cue and a toast that says why.
enum StreamRetry {
    /// How long the PC may take to answer, and its library to load.
    static let pcWait = Duration.seconds(4)
    static let libraryWait = Duration.seconds(5)

    enum Decision: Equatable {
        /// The game is there: the stream tries again.
        case retry
        /// The game is there under another id (the PC's list changed): that one starts.
        case start(appID: Int)
        /// The PC did not answer as a paired PC.
        case unreachable(pcName: String)
        /// The PC answered, the game is gone.
        case gameMissing(appName: String, pcName: String)

        /// The toast of a decision that stops (nil: the stream goes on).
        var toast: String? {
            switch self {
            case .retry, .start: nil
            case .unreachable(let pc): L("shell_retry_unreachable", pc)
            case .gameMissing(let app, let pc):
                app.isEmpty ? L("shell_retry_game_missing_unnamed", pc) : L("shell_retry_game_missing", app, pc)
            }
        }
    }

    /// What the PC's state says, once asked: [host] is the record after the wait, [apps] its list (nil: it did not load).
    static func decide(host: HostRecord?, apps: [HostApp]?, appID: Int, appName: String, pcName: String) -> Decision {
        guard let host, host.pin != nil, host.reachability == .online else { return .unreachable(pcName: pcName) }
        guard let apps else { return .gameMissing(appName: appName, pcName: host.name) }
        if apps.contains(where: { $0.id == appID }) { return .retry }
        if !appName.isEmpty, let renamed = apps.first(where: { $0.title == appName }) { return .start(appID: renamed.id) }
        return .gameMissing(appName: appName, pcName: host.name)
    }

    /// The streams whose check runs: a second press of Try again meanwhile does nothing.
    @MainActor private static var checking: Set<ObjectIdentifier> = []

    /// Asks the PC, then tries again, starts the game under its new id or closes the result with the reason.
    @MainActor static func run(
        controller: StreamController, hosts: HostStore?, navigator: Navigator?, toasts: Toasts?, feedback: Feedback?,
        hostID: String, appID: Int
    ) {
        guard let hosts, checking.insert(ObjectIdentifier(controller)).inserted else { return }
        let pcName = hosts.host(hostID)?.name ?? ""
        let appName = hosts.apps[hostID]?.first { $0.id == appID }?.title ?? ""
        Task { @MainActor in
            defer { checking.remove(ObjectIdentifier(controller)) }
            _ = await within(pcWait) { await hosts.refresh(hostID) }
            var apps: [HostApp]?
            if hosts.host(hostID)?.reachability == .online {
                apps = await within(libraryWait) { try? await hosts.loadApps(hostID) } ?? nil
            }
            let decision = decide(host: hosts.host(hostID), apps: apps, appID: appID, appName: appName, pcName: pcName)
            switch decision {
            case .retry:
                controller.retry()
            case .start(let other):
                controller.dismiss()
                // The failed stream's screen leaves first (its phase ends it), then the game starts under its new id
                try? await Task.sleep(for: .milliseconds(400))
                navigator?.openStream(hostID: hostID, appID: other)
            case .unreachable:
                feedback?.play(.error)
                controller.dismiss()
                toasts?.show(decision.toast ?? "", icon: Symbols.wifiOff)
            case .gameMissing:
                feedback?.play(.error)
                controller.dismiss()
                toasts?.show(decision.toast ?? "", icon: Symbols.error)
            }
        }
    }

    /// [work]'s result, or nil when it takes longer than [limit] (the work then goes on unawaited).
    @MainActor static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @MainActor () async -> T) async -> T? {
        let (results, sink) = AsyncStream.makeStream(of: T?.self, bufferingPolicy: .bufferingNewest(1))
        Task { @MainActor in sink.yield(await work()) }
        let timer = Task {
            try? await Task.sleep(for: limit)
            sink.yield(nil)
        }
        var first: T?
        for await value in results {
            first = value
            break
        }
        timer.cancel()
        sink.finish()
        return first
    }
}
