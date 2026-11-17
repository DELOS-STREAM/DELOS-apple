import DelosData
import DelosHost
import Foundation
#if os(iOS)
import UIKit
import UniformTypeIdentifiers
#elseif os(macOS)
import AppKit
#endif

/// Clipboard sync between this device and the PC during a stream (`StreamClipboardSync` of DELOS for Android): the Send
/// and Get clipboard actions of the stream menu, and with Smart Clipboard Sync (`checkbox_smart_clipboard_sync`) this
/// device's clipboard sent when the stream starts and the PC's fetched on Disconnect. Each transfer reports in a toast
/// when `checkbox_smart_clipboard_sync_toast` is on; a clip from the PC is marked concealed while
/// `checkbox_hide_clipboard_content` is on.
///
/// Clips DELOS put on the clipboard itself, or already read, carry its mark and are not sent again unless the player asks
/// (Send clipboard). The network calls run in tasks; the clipboard and the toasts are touched on the main actor only.
@MainActor
final class ClipboardSync {
    /// The three switches of Settings → Controls that the sync reads (PreferenceConfiguration.java:105-107).
    struct Options: Equatable, Sendable {
        var smartSync: Bool
        var toast: Bool
        var hideContent: Bool

        init(smartSync: Bool = false, toast: Bool = true, hideContent: Bool = true) {
            self.smartSync = smartSync
            self.toast = toast
            self.hideContent = hideContent
        }

        init(_ settings: StreamSettings) {
            self.init(
                smartSync: settings.bool(.smartClipboardSync), toast: settings.bool(.smartClipboardSyncToast),
                hideContent: settings.bool(.hideClipboardContent))
        }
    }

    private let options: Options
    private let host: any ClipboardHost
    private let pasteboard: any StreamPasteboard
    private let toast: @MainActor (String, ToastKind) -> Void
    /// A Get runs; another one started meanwhile does nothing (`clipboardSyncRunning`).
    private var getRunning = false

    init(
        options: Options, host: any ClipboardHost, pasteboard: any StreamPasteboard = SystemPasteboard.shared,
        toast: @escaping @MainActor (String, ToastKind) -> Void
    ) {
        self.options = options
        self.host = host
        self.pasteboard = pasteboard
        self.toast = toast
    }

    /// The stream gained ([hasFocus]) or lost the player (`handleFocusChange`, StreamClipboardSync.java:52-62): with Smart
    /// Clipboard Sync and a [connected] stream, this device's clipboard is sent, or the PC's fetched. DELOS for Android
    /// calls it with true once the connection has started (DelosStreamActivity.java:1808-1809). Nil when nothing runs.
    @discardableResult
    func handleFocusChange(_ hasFocus: Bool, connected: Bool) -> Task<Void, Never>? {
        guard connected, options.smartSync else { return nil }
        return hasFocus ? send(force: false) : get()
    }

    /// Disconnect (DelosStreamActivity.java:2086-2091): with Smart Clipboard Sync the PC's clipboard comes along. The
    /// transfer outlives the stream, as Android's thread outlives the finished activity.
    @discardableResult
    func disconnecting() -> Task<Void, Never>? {
        options.smartSync ? get() : nil
    }

    /// The clipboard's text to send (`getClipboardContent`, StreamClipboardSync.java:64-108): nil without a clip, for a
    /// clip that has DELOS's mark unless [force], and for a clip without text. A clip read here gets the mark.
    func content(force: Bool) -> String? {
        switch pasteboard.clip {
        case .empty: nil
        case .own where !force: nil
        case .own, .other: pasteboard.markFirstItem()
        }
    }

    /// Sends this device's clipboard to the PC (`sendClipboard`, StreamClipboardSync.java:124-158); [force] sends a clip
    /// DELOS has marked as well (Send clipboard of the stream menu). Nil when there was nothing to send.
    @discardableResult
    func send(force: Bool) -> Task<Void, Never>? {
        guard let text = content(force: force) else { return nil }
        let host = self.host
        return Task {
            do {
                if try await host.sendClipboard(text) {
                    report(L("send_clipboard_success"), .success)
                } else {
                    report(L("clipboard_sync_unsupported"), .warning)
                }
            } catch {
                // Android appends the exception's message to the text as it is (the resource's trailing space is trimmed)
                report(L("send_clipboard_failed") + HostErrorMessage.of(error, url: host.clipboardURL), .error)
            }
        }
    }

    /// Fetches the PC's clipboard onto this device's (`getClipboard`, StreamClipboardSync.java:160-207), after [delay].
    /// The clip gets DELOS's mark, and is concealed while `checkbox_hide_clipboard_content` is on.
    @discardableResult
    func get(delay: Duration = .zero) -> Task<Void, Never> {
        let host = self.host
        return Task {
            guard !getRunning else { return }
            getRunning = true
            defer { getRunning = false }
            if delay > .zero { try? await Task.sleep(for: delay) }
            do {
                let text = try await host.clipboard()
                pasteboard.putOwn(text, concealed: options.hideContent)
                report(L("get_clipboard_success"), .success)
            } catch {
                report(L("get_clipboard_failed") + HostErrorMessage.of(error, url: host.clipboardURL), .error)
            }
        }
    }

    private func report(_ text: String, _ kind: ToastKind) {
        if options.toast { toast(text, kind) }
    }
}

// MARK: The PC

/// The PC's side of the sync: Vibepollo's and Apollo's `actions/clipboard` (``HostClient/clipboard(pin:)``).
protocol ClipboardHost: Sendable {
    func clipboard() async throws -> String
    func sendClipboard(_ text: String) async throws -> Bool
    /// The command's address without its query: what a failure toast names when the PC has no such command (Android
    /// names the complete URL there, client id included; that id is no help to the player and stays out).
    var clipboardURL: String { get }
}

/// The paired PC of the stream over its pinned HTTPS connection.
struct PairedClipboardHost: ClipboardHost {
    let client: HostClient
    let pin: HostPin

    func clipboard() async throws -> String { try await client.clipboard(pin: pin) }

    func sendClipboard(_ text: String) async throws -> Bool { try await client.sendClipboard(text, pin: pin) }

    var clipboardURL: String { "https://\(HostAddress(host: client.address.host, port: pin.httpsPort))/actions/clipboard" }
}

/// The message of a failed request as DELOS for Android's toasts and help append it (`Exception.getMessage()`).
enum HostErrorMessage {
    static func of(_ error: any Error, url: String) -> String {
        switch error {
        case let HostError.hostStatus(code, message):
            // HostHttpResponseException.getMessage(); Java writes a missing message as "null"
            "Host PC returned error: \(message ?? "null") (Error code: \(code))"
        case HostError.httpStatus(404):
            // FileNotFoundException(url)
            url
        case let HostError.httpStatus(code):
            "Host PC returned error:  (Error code: \(code))"
        case HostError.certificateMismatch:
            "Host PC returned error: Server certificate mismatch (Error code: 401)"
        case HostError.timedOut:
            // OkHttp's SocketTimeoutException
            "timeout"
        case let HostError.unreachable(detail), let HostError.malformedResponse(detail), let HostError.identity(detail):
            detail
        case is RuntimeBitrateOutOfRange:
            "Bitrate must be between 1 and 1000 Mbps"
        default:
            String(describing: error)
        }
    }
}

// MARK: The clipboard

/// What the clipboard holds, read without its content (on iOS, reading the content asks the player for permission).
enum ClipState: Equatable, Sendable {
    case empty
    /// The first item has DELOS's mark: DELOS put it there, or sent it already.
    case own
    case other
}

/// The system clipboard as the sync uses it; tests use ``MemoryPasteboard``.
@MainActor
protocol StreamPasteboard: AnyObject {
    var clip: ClipState { get }
    /// Reads the first item, writes it back alone with DELOS's mark (Android's `cloneClipData` keeps that item only) and
    /// returns its plain text, nil when it has none.
    func markFirstItem() -> String?
    /// Replaces the clipboard with [text] that has DELOS's mark; [concealed] marks it sensitive as well.
    func putOwn(_ text: String, concealed: Bool)
}

/// The pasteboard types the sync writes.
enum ClipboardTypes {
    /// DELOS's mark (Android's `CLIPBOARD_IDENTIFIER` extra, "DelosStreaming").
    static let own = "io.github.meitoncz.delos.streaming"
    /// Android marks a sensitive clip with `android.content.extra.IS_SENSITIVE`, which hides its preview. Apple has no
    /// such flag; the closest is the nspasteboard.org convention that clipboard histories and managers honour: they
    /// neither show nor keep a clip of this type.
    static let concealed = "org.nspasteboard.ConcealedType"
    static let mark = Data([1])
}

/// A clipboard in memory: the tests' clipboard, and tvOS's, which has no system clipboard (a clip fetched from one PC
/// can be sent to another during the app's run).
@MainActor
final class MemoryPasteboard: StreamPasteboard {
    struct Item: Equatable {
        var text: String?
        var own = false
        var concealed = false
    }

    var items: [Item] = []

    init(items: [Item] = []) {
        self.items = items
    }

    var clip: ClipState {
        guard let first = items.first else { return .empty }
        return first.own ? .own : .other
    }

    func markFirstItem() -> String? {
        guard var first = items.first else { return nil }
        first.own = true
        items = [first]
        return first.text
    }

    func putOwn(_ text: String, concealed: Bool) {
        items = [Item(text: text, own: true, concealed: concealed)]
    }
}

#if os(iOS)
/// `UIPasteboard.general`.
@MainActor
final class SystemPasteboard: StreamPasteboard {
    static let shared: any StreamPasteboard = SystemPasteboard()

    private var board: UIPasteboard { .general }

    var clip: ClipState {
        guard board.numberOfItems > 0 else { return .empty }
        return board.contains(pasteboardTypes: [ClipboardTypes.own], inItemSet: IndexSet(integer: 0)) ? .own : .other
    }

    func markFirstItem() -> String? {
        guard var item = board.items.first else { return nil }
        item[ClipboardTypes.own] = ClipboardTypes.mark
        board.setItems([item])
        return Self.text(of: item)
    }

    func putOwn(_ text: String, concealed: Bool) {
        var item: [String: Any] = [UTType.utf8PlainText.identifier: text, ClipboardTypes.own: ClipboardTypes.mark]
        if concealed { item[ClipboardTypes.concealed] = ClipboardTypes.mark }
        board.setItems([item])
    }

    /// The item's plain text (Android's `ClipData.Item.getText()`); a link or an image alone has none.
    static func text(of item: [String: Any]) -> String? {
        if let text = item[UTType.utf8PlainText.identifier] as? String { return text }
        return item.first { UTType($0.key)?.conforms(to: .plainText) == true && $0.value is String }?.value as? String
    }
}
#elseif os(macOS)
/// `NSPasteboard.general`.
@MainActor
final class SystemPasteboard: StreamPasteboard {
    static let shared: any StreamPasteboard = SystemPasteboard()

    private var board: NSPasteboard { .general }
    private static let own = NSPasteboard.PasteboardType(ClipboardTypes.own)

    var clip: ClipState {
        guard let first = board.pasteboardItems?.first else { return .empty }
        return first.types.contains(Self.own) ? .own : .other
    }

    func markFirstItem() -> String? {
        guard let first = board.pasteboardItems?.first else { return nil }
        let copy = NSPasteboardItem()
        for type in first.types {
            if let data = first.data(forType: type) { copy.setData(data, forType: type) }
        }
        copy.setData(ClipboardTypes.mark, forType: Self.own)
        let text = first.string(forType: .string)
        board.clearContents()
        board.writeObjects([copy])
        return text
    }

    func putOwn(_ text: String, concealed: Bool) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(ClipboardTypes.mark, forType: Self.own)
        if concealed { item.setData(ClipboardTypes.mark, forType: NSPasteboard.PasteboardType(ClipboardTypes.concealed)) }
        board.clearContents()
        board.writeObjects([item])
    }
}
#else
/// tvOS has no system clipboard: the closest equivalent is one in memory for the app's run.
enum SystemPasteboard {
    @MainActor static let shared: any StreamPasteboard = MemoryPasteboard()
}
#endif
