import DelosHost
import Foundation
import Observation

/// The last confirmed link test per PC and kind of network, with its date (`LinkTestStore`, LinkTester.kt). A result is
/// only ever shown and used for the recommendation, with its age; it is never applied by itself, and a PC or network
/// that was not tested has none. Stored as DELOS for Android stores it (`<pc>/<TRANSPORT>` → `LinkTest.encode()`).
/// [revision] changes with every write, so the screens that read a result draw again.
@MainActor
@Observable
final class LinkTestStore {
    static let shared = LinkTestStore()

    private(set) var revision = 0
    @ObservationIgnored private let defaults: UserDefaults
    private static let prefix = "delos_link_tests."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ hostID: String, _ transport: LinkTransport) -> String { "\(prefix)\(hostID)/\(transport.rawValue)" }

    func get(hostID: String, transport: LinkTransport) -> LinkTest? {
        _ = revision
        return LinkTest.decode(defaults.string(forKey: Self.key(hostID, transport)))
    }

    func put(hostID: String, test: LinkTest) {
        defaults.set(test.encode(), forKey: Self.key(hostID, test.transport))
        revision += 1
    }
}
