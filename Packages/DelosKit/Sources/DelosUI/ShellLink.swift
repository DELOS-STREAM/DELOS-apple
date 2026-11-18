import Foundation
import Observation

/// What a link or a file from outside the app asks DELOS to do (`ShellLink` of DELOS for Android): `art://` links, as the
/// classic AddComputerManually and ShortcutTrampoline read them, and opened `.art` shortcut files. Links can come from any
/// web page or app, so pairing and starting a game ask first (`shell_link_*` dialogs).
enum ShellLink: Equatable, Sendable {
    /// `art://host[:port]?pin=…&passphrase=…[&name=…]`: add the PC and pair it (with the one-time code, if both are given).
    case pair(address: String, name: String?, code: OneTimeCode?)
    /// `art://launch?host_uuid=…&host_name=…&app_uuid=…&app_id=…&app_name=…`, or an opened `.art` file: open a PC or start
    /// one of its games.
    case launch(LaunchLink)
    /// An opened `.art` file DELOS cannot use (unreadable, or naming no valid PC): the string name of the error toast.
    case rejected(String)

    /// The link [url] stands for; nil when it is not an `art://` link DELOS reads.
    init?(_ url: URL) {
        guard url.scheme?.lowercased() == "art", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if components.port == nil, components.host == "launch" {
            self = .launch(LaunchLink(
                hostUUID: value("host_uuid"), hostName: value("host_name"),
                appUUID: value("app_uuid"), appID: value("app_id"), appName: value("app_name")))
            return
        }
        // The authority as written (host and port, IPv6 in brackets): what the address dialog would have been given
        let text = url.absoluteString
        guard let start = text.range(of: "://")?.upperBound else { return nil }
        let authority = String(text[start...].prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !authority.isEmpty else { return nil }
        let pin = value("pin"), passphrase = value("passphrase")
        self = .pair(
            address: authority, name: value("name"),
            code: pin.flatMap { pin in passphrase.map { OneTimeCode(pin: pin, passphrase: $0) } })
    }

    /// An opened `.art` file's [data] (ShortcutTrampoline's file branch): unreadable or partial, nothing of it is used; a
    /// file naming no valid PC is refused at once, anything else asks like an `art://launch` link (`askInDelos`).
    init(artFile data: Data?) {
        guard let data, let values = ArtFile.parse(data) else {
            self = .rejected("scut_art_unreadable")
            return
        }
        let link = LaunchLink(
            hostUUID: values["host_uuid"], hostName: values["host_name"],
            appUUID: values["app_uuid"], appID: values["app_id"], appName: values["app_name"])
        if let key = link.hostError {
            self = .rejected(key)
        } else {
            self = .launch(link)
        }
    }
}

/// Reader of `.art` shortcut files (`ArtFile` of DELOS for Android): lines of `[key] value`, `#` comments. The file comes
/// from outside the app, so it is read whole or not at all and never beyond [maxBytes].
enum ArtFile {
    /// A shortcut file holds five short values; anything larger is not one.
    static let maxBytes = 64 * 1024

    /// The keys and values of the file; nil when it is too large or a line is malformed.
    static func parse(_ data: Data) -> [String: String]? {
        guard data.count <= maxBytes else { return nil }
        var values: [String: String] = [:]
        let lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false) {
            $0 == "\n" || $0 == "\r" || $0 == "\r\n"
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard line.hasPrefix("[") else { return nil }
            // A line without a value after its key is skipped, as Android does
            guard let space = line.firstIndex(of: " "), space > line.startIndex, line.index(after: space) < line.endIndex else { continue }
            let key = line[..<space].trimmingCharacters(in: .whitespaces)
            guard key.hasSuffix("]") else { return nil }
            values[String(key.dropFirst().dropLast())] = line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

/// The values of an `art://launch` link, unchecked: they are validated once the player agreed (ShortcutTrampoline's
/// `validateHostInput` / `validateAppInput`).
struct LaunchLink: Equatable, Sendable {
    var hostUUID: String?
    var hostName: String?
    var appUUID: String?
    var appID: String?
    var appName: String?

    /// The game's name to show, if the link has one.
    var shownGame: String? { appName.flatMap { $0.isEmpty ? nil : $0 } }
    /// The PC's name to show, if the link has one.
    var shownHost: String? { hostName.flatMap { $0.isEmpty ? nil : $0 } }

    /// The confirmation dialog's title and message (`Shell.kt`'s `ShellLink.Launch` branch).
    var prompt: (title: String, message: String) {
        let game = shownGame, host = shownHost
        let title = game.map { L("shell_link_start_title", $0) } ?? L("shell_link_start_title_unnamed")
        let message = switch (game, host) {
        case let (game?, host?): L("shell_link_start_message", game, host)
        case let (game?, nil): L("shell_link_start_message_game", game)
        case let (nil, host?): L("shell_link_start_message_host", host)
        case (nil, nil): L("shell_link_start_message_unnamed")
        }
        return (title, message)
    }

    /// What the link names, once checked: the PC (by its id, else its name) and the game (by its UUID, id or name; none
    /// opens the PC's games), or the string name of what is wrong.
    enum Target: Equatable {
        case host(id: String?, name: String?, app: AppRef?)
        case invalid(String)
    }

    /// How the link names the game.
    enum AppRef: Equatable {
        case uuid(String)
        case id(Int)
        case name(String)
    }

    /// The string name of what is wrong with the PC the link names (`validateHostInput`); nil when it names one.
    var hostError: String? {
        if let uuid = hostUUID, !uuid.isEmpty {
            UUID(uuidString: uuid) == nil ? "scut_invalid_uuid" : nil
        } else {
            shownHost == nil ? "scut_invalid_uuid" : nil
        }
    }

    var target: Target {
        if let key = hostError { return .invalid(key) }
        let uuid = hostUUID.flatMap { $0.isEmpty ? nil : $0 }
        var app: AppRef?
        if let appUUID, !appUUID.isEmpty {
            guard UUID(uuidString: appUUID) != nil else { return .invalid("scut_invalid_app_id") }
            app = .uuid(appUUID)
        } else if let appID, !appID.isEmpty {
            guard let id = Int(appID) else { return .invalid("scut_invalid_app_id") }
            app = .id(id)
        } else if let name = shownGame {
            app = .name(name)
        }
        return .host(id: uuid, name: uuid == nil ? shownHost : nil, app: app)
    }
}

/// Links and files that arrived (the app's `onOpenURL`) and wait for the shell: the first launch keeps them until a profile
/// exists.
@MainActor @Observable
public final class ShellLinkInbox {
    private(set) var pending: ShellLink?

    public init() {}

    /// A URL opened with DELOS: an `art://` link or an `.art` file; anything else is ignored.
    public func receive(_ url: URL) {
        if url.isFileURL {
            guard url.pathExtension.lowercased() == "art" else { return }
            pending = ShellLink(artFile: Self.read(url))
        } else if let link = ShellLink(url) {
            pending = link
        }
    }

    /// The waiting link, now handled.
    func take() -> ShellLink? {
        defer { pending = nil }
        return pending
    }

    /// The file's bytes, at most one more than a shortcut file may have; nil when it cannot be read.
    private static func read(_ url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: ArtFile.maxBytes + 1) ?? Data()
    }
}
