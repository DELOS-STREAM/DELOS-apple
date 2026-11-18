import DelosData
import DelosHost
import Foundation

/// How a link test of the UI ended (`LinkTestResult` of DELOS for Android).
enum LinkTestRun: Equatable {
    /// [jitter]: it passed with a little jitter.
    case done(LinkTest, jitter: Bool)
    case failed(LinkFailure)
    /// The search found no rate that holds: [last] is the final probe, [bestPassKbps] the highest rate that passed once.
    case noRate(last: ProbeScore?, bestPassKbps: Int)
    case cancelled

    /// Why it failed, in a sentence (`LinkTestResult.Failed.text`); nil when it did not fail.
    var failureText: String? {
        switch self {
        case .failed(let failure): failure.text
        case .noRate(let last, let best): linkNoRateText(last: last, bestPassKbps: best)
        case .done, .cancelled: nil
        }
    }
}

/// Runs a link test from the shell (`LinkTester` of DELOS for Android): a fresh `/serverinfo` of the paired PC, then the
/// host document's search. Never applies anything.
@MainActor
enum LinkTester {
    /// Starts at [startKbps] (the selected bitrate). Cancelling the calling task stops the probe and tears down its
    /// request and UDP socket.
    static func run(
        hosts: HostStore, hostID: String, startKbps: Int, transport: LinkTransport, onStep: @escaping @MainActor (LinkStep) -> Void
    ) async -> LinkTestRun {
        do {
            let (client, _, pin) = try hosts.pairedClient(hostID)
            let info = try await client.serverInfo(pin: pin).info.pyroWave
            guard info.supportsLinkTest else { return .failed(info.linkTestNeedsNewerClient ? .needsNewerClient : .hostUnsupported) }
            switch try await runLinkTest(
                host: HostLinkProbe(client: client, pin: pin), info: info, startKbps: startKbps, transport: transport,
                onStep: { onStep($0) })
            {
            case .done(let test, let jitter): return .done(test, jitter: jitter)
            case .noRate(let last, let best): return .noRate(last: last, bestPassKbps: best)
            case .cancelled: return .cancelled
            }
        } catch {
            return Task.isCancelled ? .cancelled : result(of: error)
        }
    }

    /// A thrown error as the result the screens word (LinkTester.kt's catch clauses): the probe's own reason, 403 of the
    /// PC as a refusal, another answer of the PC as its error, anything else as a network failure.
    static func result(of error: any Error) -> LinkTestRun {
        switch error {
        case is CancellationError: .cancelled
        case let error as LinkTestError: .failed(error.failure)
        case HostError.httpStatus(403), HostError.hostStatus(code: 403, _): .failed(.denied)
        case HostError.httpStatus, HostError.hostStatus: .failed(.hostError)
        default: .failed(.network)
        }
    }
}
