import Foundation

/// The games a profile hid on a PC (`hiddenAppsKey` of DELOS for Android: the ids kept with the profile, per PC). A hidden
/// game is left out of the library until "Show hidden apps" is switched on in the side menu.
public struct HiddenGames: Sendable {
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String, _ hostID: String) -> String { "hidden.\(profile).\(hostID)" }

    /// The app ids hidden on the PC in the profile.
    public func ids(profile: String, hostID: String) -> Set<Int> {
        Set((defaults.array(forKey: key(profile, hostID)) as? [Int]) ?? [])
    }

    public func set(_ hidden: Bool, appID: Int, profile: String, hostID: String) {
        var ids = ids(profile: profile, hostID: hostID)
        if hidden { ids.insert(appID) } else { ids.remove(appID) }
        if ids.isEmpty {
            defaults.removeObject(forKey: key(profile, hostID))
        } else {
            defaults.set(ids.sorted(), forKey: key(profile, hostID))
        }
    }

    /// Forgets a removed profile's hidden games.
    public func remove(profile: String) {
        let prefix = "hidden.\(profile)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) { defaults.removeObject(forKey: key) }
    }
}
