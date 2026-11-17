import Foundation

/// Where the stream loader is in its life (`LoaderPhase` of DELOS for Android); ``cancelled`` and ``gone`` are final.
enum LoaderPhase: Equatable, Sendable {
    /// Launching and connecting: the launch scene is up.
    case connecting
    /// The connection is up and the scene opens over the picture: the stream runs behind it, but is not the player's yet.
    case opening
    /// The player cancelled the loader.
    case cancelled
    /// The scene is over (or the attempt ended some other way).
    case gone
}

/// What cancelling the loader does. It only ends this client's attempt: the game keeps running on the PC (whether it ran
/// already or was started for this attempt), no result overlay is shown, and the library comes back.
struct CancelPlan: Equatable, Sendable {
    let stopConnection = true
    let quitGame = false
    let showResult = false
    let returnToLibrary = true
}

/// The loader's phases and its one-shot cancel request, valid while the scene is up: B, Escape and the Cancel pill all
/// ask through ``request()``, so one attempt is cancelled once however many of them arrive.
struct LoaderCancel: Equatable, Sendable {
    private(set) var phase = LoaderPhase.connecting

    /// The loader can still be cancelled: it is on screen and nobody has cancelled it yet.
    var cancellable: Bool { phase == .connecting || phase == .opening }

    /// The connection is up; the scene opens over the picture.
    mutating func connected() {
        if phase == .connecting { phase = .opening }
    }

    /// The scene is over. A cancelled loader stays cancelled.
    mutating func ended() {
        if phase != .cancelled { phase = .gone }
    }

    /// True exactly once while ``cancellable``; false afterwards and once the scene is gone.
    mutating func request() -> Bool {
        guard cancellable else { return false }
        phase = .cancelled
        return true
    }

    /// What a cancel does; the same in every phase.
    static let plan = CancelPlan()
}
