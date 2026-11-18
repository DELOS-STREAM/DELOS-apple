import Foundation

/// The key combinations of a custom key file (`GameMenu.specialKeyOptions` of DELOS for Android, GameMenu.java:110-146): a
/// JSON object whose `data` array holds `{ "name": …, "keys": ["VK_LCONTROL", "0x43", …] }`. A key is a `VK_` name of
/// ``VirtualKeyNames`` or a hexadecimal code after `0x`.
public enum CustomKeyCombos {
    /// What a file gave: the combinations read before the first one that could not be read, and whether one could not
    /// (Android then shows `wrong_import_format` and keeps the ones it had read).
    public struct Result: Equatable, Sendable {
        public var options: [SpecialKeys.Option]
        public var failed: Bool
    }

    private struct File: Decodable {
        let data: [Shortcut]?
    }

    private struct Shortcut: Decodable {
        let name: String?
        let keys: [String]?
    }

    /// The combinations of [text]; an empty text has none and is no failure.
    public static func parse(_ text: String) -> Result {
        guard !text.isEmpty else { return Result(options: [], failed: false) }
        guard let data = text.data(using: .utf8), let file = try? JSONDecoder().decode(File.self, from: data) else {
            return Result(options: [], failed: true)
        }
        var options: [SpecialKeys.Option] = []
        for shortcut in file.data ?? [] {
            var keys: [UInt8] = []
            for name in shortcut.keys ?? [] {
                guard let key = code(name) else { return Result(options: options, failed: true) }
                keys.append(key)
            }
            options.append(SpecialKeys.Option(label: shortcut.name ?? "", combo: KeyCombo(keys)))
        }
        return Result(options: options, failed: false)
    }

    /// One key of the file: `0x`… in hexadecimal or a `VK_` name; nil for anything else (or a code beyond 0xFF, which is no
    /// virtual key).
    static func code(_ name: String) -> UInt8? {
        if name.hasPrefix("0x") {
            return Int(name.dropFirst(2), radix: 16).flatMap(UInt8.init(exactly:))
        }
        if name.hasPrefix("VK_") {
            return VirtualKeyNames.codes[name].flatMap(UInt8.init(exactly:))
        }
        return nil
    }
}
