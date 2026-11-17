import DelosHost
import Foundation
import Observation

/// What a live bitrate change came to (`BitrateResult`, StreamMenuHost.kt:13-17).
enum BitrateResult: Equatable, Sendable {
    /// The host applied the bitrate asked for (or more).
    case accepted(kbps: Int)
    /// The host applied less than was asked for.
    case limited(kbps: Int)
    case failed(BitrateFailure)
}

/// Why a bitrate change failed, as the Apply row's help says it (`BitrateFailure`, StreamMenuLayout.kt:623-640).
struct BitrateFailure: Equatable, Sendable {
    /// The string's name and its one argument, if any.
    let name: String
    let detail: String?

    static let notConnected = BitrateFailure(name: "stream_menu_bitrate_not_connected", detail: nil)
    static let unsupported = BitrateFailure(name: "stream_menu_bitrate_unsupported", detail: nil)
    static let denied = BitrateFailure(name: "stream_menu_bitrate_denied", detail: nil)
    static let unconfirmed = BitrateFailure(name: "stream_menu_bitrate_unconfirmed", detail: nil)

    /// The host answered with an error of its own; its [detail] is cut so the sentence still fits (59 characters and an
    /// ellipsis beyond 60).
    static func rejected(_ detail: String?) -> BitrateFailure {
        let clean = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !clean.isEmpty else { return BitrateFailure(name: "stream_menu_bitrate_rejected", detail: nil) }
        return BitrateFailure(name: "stream_menu_bitrate_rejected_detail", detail: clean.count > 60 ? String(clean.prefix(59)) + "\u{2026}" : clean)
    }

    /// How DELOS for Android reads a failed request (StreamMenu.kt:325-329): the host has no such command (404), it did
    /// not allow it (403), it refused with a message of its own, or the change went unconfirmed (anything else: no
    /// answer, a malformed one, a bitrate out of range).
    static func of(_ error: any Error) -> BitrateFailure {
        switch error {
        case HostError.httpStatus(404): .unsupported
        case HostError.hostStatus(code: 403, _): .denied
        case HostError.hostStatus: .rejected(HostErrorMessage.of(error, url: ""))
        default: .unconfirmed
        }
    }

    /// The sentence in the app's language.
    var text: String { detail.map { L(name, $0) } ?? L(name) }
}

/// The live bitrate of the running stream: the Apply of the stream menu's Bitrate page (`applyBitrate`,
/// StreamMenu.kt:308-331) asks the host for a bitrate through Vibepollo's paired HTTPS command, never the streaming core
/// (``HostClient/setRuntimeBitrate(_:pin:)``). One change runs at a time.
@MainActor
@Observable
final class StreamBitrate {
    /// A change runs.
    private(set) var busy = false
    /// What the last change came to; nil before any and while one runs.
    private(set) var result: BitrateResult?
    /// The bitrate the host applied last in this stream (Android writes it to `prefConfig.bitrate` for the rest of the
    /// stream); nil while the stream has the one it started with.
    private(set) var appliedKbps: Int?

    /// What the Apply row says on its right (`bitrateStatusText`, StreamMenuLayout.kt:613-620); nil before anything was
    /// applied.
    var statusText: String? {
        if busy { return L("stream_menu_bitrate_applying") }
        switch result {
        case .accepted(let kbps): return L("stream_menu_bitrate_accepted", kbps / 1000)
        case .limited(let kbps): return L("stream_menu_bitrate_limited", kbps / 1000)
        case .failed: return L("stream_menu_bitrate_failed")
        case nil: return nil
        }
    }

    /// The failure the Apply row's help explains instead of its own text (StreamMenuLayout.kt:601); nil without one.
    var failureText: String? {
        if case .failed(let failure) = result { failure.text } else { nil }
    }

    /// Asks for [requested] kbps through [change] (it returns what the host applied). [connected] says whether the stream
    /// runs: before the request (a stream that does not run fails at once) and after it (an answer that arrives once the
    /// stream has ended is dropped). Nil when nothing was started: a change runs already, or the stream does not run.
    @discardableResult
    func apply(
        _ requested: Int, connected: @escaping @MainActor () -> Bool, change: @escaping @MainActor (Int) async throws -> Int
    ) -> Task<Void, Never>? {
        guard !busy else { return nil }
        guard connected() else {
            result = .failed(.notConnected)
            return nil
        }
        busy = true
        result = nil
        return Task {
            defer { busy = false }
            do {
                let applied = try await change(requested)
                guard connected() else { return }
                appliedKbps = applied
                result = applied < requested ? .limited(kbps: applied) : .accepted(kbps: applied)
            } catch is CancellationError {
                return
            } catch {
                result = .failed(.of(error))
            }
        }
    }
}
