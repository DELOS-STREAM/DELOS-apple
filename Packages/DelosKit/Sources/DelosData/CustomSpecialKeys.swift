import Foundation

/// The custom key combinations of a profile (Settings → Controls → Import Custom Keys, `import_special_button_file` of
/// DELOS for Android): a JSON file with a `data` array, as moonlight-android's custom special keys format describes it.
/// The stream menu's Send keys page lists them (with Android's defaults unless `checkbox_enable_clear_default_special_button`
/// clears those). Kept per profile in `UserDefaults` as the imported text.
public struct CustomSpecialKeys: Sendable {
    /// Why a file was not imported (`settings_actions_*` of DELOS for Android).
    public enum ImportError: Error, Equatable, Sendable {
        /// Larger than 1 MB.
        case tooLarge
        /// Not a JSON object with a `data` array.
        case noShortcutData
        /// Not JSON.
        case invalid
    }

    /// Android reads at most 1 MiB of the file.
    public static let maxBytes = 1_048_576

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    private func key(_ profile: String) -> String { "specialkeys.\(profile)" }

    /// The profile's imported file, nil when it has none.
    public func load(profile: String) -> String? { defaults.string(forKey: key(profile)) }

    /// Checks [data] and keeps it as the profile's custom keys, replacing what was there.
    public func importFile(_ data: Data, profile: String) throws(ImportError) {
        guard data.count <= Self.maxBytes else { throw .tooLarge }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw .invalid }
        guard let root = object as? [String: Any] else { throw .invalid }
        guard root["data"] is [Any] else { throw .noShortcutData }
        guard let text = String(data: data, encoding: .utf8) else { throw .invalid }
        defaults.set(text, forKey: key(profile))
    }

    /// Forgets a removed profile's custom keys.
    public func remove(profile: String) {
        defaults.removeObject(forKey: key(profile))
    }

    /// A new profile starts with a copy of the current one's custom keys, like its other settings.
    public func copy(from source: String, to target: String) {
        if let text = load(profile: source) { defaults.set(text, forKey: key(target)) }
    }
}
