import Foundation

/// An XML element of a host answer: its name, attributes, text and children.
struct HostXMLElement: Sendable {
    var name: String
    var attributes: [String: String]
    var text: String
    var children: [HostXMLElement]

    /// The text of the first child with that name; nil when there is none.
    func child(_ name: String) -> String? {
        children.first { $0.name == name }?.text
    }

    func children(_ name: String) -> [HostXMLElement] {
        children.filter { $0.name == name }
    }
}

/// Reads the XML that GameStream hosts answer with: a `root` element whose `status_code` attribute says whether the
/// request succeeded. A document that is not well-formed (also a truncated one) is rejected as a whole.
enum HostXML {
    static func root(_ data: Data) throws -> HostXMLElement {
        let reader = TreeReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = reader.root else {
            throw HostError.malformedResponse("not well-formed XML")
        }
        guard root.name == "root" else { throw HostError.malformedResponse("no root element") }
        try checkStatus(root)
        return root
    }

    /// Throws `hostStatus` unless `status_code` is 200. Hosts can send 0xFFFFFFFF, which is -1 as a 32-bit value.
    static func checkStatus(_ root: HostXMLElement) throws {
        guard let text = root.attributes["status_code"], let value = Int64(text) else {
            throw HostError.malformedResponse("no status_code")
        }
        var code = Int(Int32(truncatingIfNeeded: value))
        guard code != 200 else { return }
        var message = root.attributes["status_message"]
        if code == -1 && message == "Invalid" {
            // GeForce Experience reports a missing audio capture device this way (as Moonlight handles it).
            code = 418
            message = "Missing audio capture device. Reinstall GeForce Experience."
        }
        throw HostError.hostStatus(code: code, message: message)
    }

    private final class TreeReader: NSObject, XMLParserDelegate {
        var root: HostXMLElement?
        private var stack: [HostXMLElement] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            stack.append(HostXMLElement(name: elementName, attributes: attributeDict, text: "", children: []))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }
    }
}

/// What a host says about itself in `/serverinfo`.
public struct ServerInfo: Equatable, Sendable {
    /// Never empty: a host that sends no name is called "UNKNOWN" (as DELOS for Android does).
    public var hostName: String
    /// Valid by `HostID.isValid`; answers without one are rejected.
    public var uniqueID: String
    public var macAddress: String?
    /// `LocalIP`.
    public var localIP: String?
    /// `ExternalIP`.
    public var externalIP: String?
    public var httpsPort: Int
    /// `ExternalPort` (Sunshine and its forks); nil when absent.
    public var externalPort: Int?
    /// `appversion`, four dot-separated numbers (`7.1.431.-1`).
    public var appVersion: String?
    public var gfeVersion: String?
    /// Bit field of the codecs the host can encode (bit 0 H.264, bit 8 HEVC Main, bit 9 HEVC Main10, ...); 0 if absent.
    public var codecModeSupport: Int
    public var maxLumaPixelsH264: Int
    public var maxLumaPixelsHEVC: Int
    /// `PairStatus` is 1. Hosts report 1 only over HTTPS to a paired client.
    public var pairStatus: Bool
    /// `state`, such as `SUNSHINE_SERVER_FREE` or `SUNSHINE_SERVER_BUSY`.
    public var state: String
    /// The app that runs, 0 when none. Only read while `state` ends in `_SERVER_BUSY` (GeForce Experience keeps the
    /// last game there).
    public var currentGame: Int
    public var currentGameUUID: String?
    /// Apollo's permission bits, -1 when absent or not a number.
    public var permission: Int
    public var virtualDisplayCapable: Bool
    public var virtualDisplayDriverReady: Bool
    public var serverCommands: [String]
    public var gpuType: String?
    /// What the host says about PyroWave link measurement (``PyroWaveHostInfo``); ``PyroWaveHostInfo/none`` when nothing.
    public var pyroWave: PyroWaveHostInfo = .none

    /// GeForce Experience (code name MJOLNIR); no other server uses that name.
    public var isNvidiaServer: Bool { state.contains("MJOLNIR") }

    /// The four numbers of `appversion`; throws when it is missing or not four numbers.
    public func appVersionQuad() throws -> [Int] {
        guard let appVersion else { throw HostError.malformedResponse("no appversion") }
        let parts = appVersion.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil }) else {
            throw HostError.malformedResponse("malformed appversion \(appVersion)")
        }
        return parts.map { $0! }
    }

    /// The server generation: 7 and later hash with SHA-256 when pairing, earlier ones with SHA-1.
    public func generation() throws -> Int { try appVersionQuad()[0] }

    public static func parse(_ data: Data) throws -> ServerInfo {
        let root = try HostXML.root(data)
        func required(_ name: String) throws -> String {
            guard let value = root.child(name) else { throw HostError.malformedResponse("no \(name)") }
            return value
        }
        func port(_ name: String) -> Int? {
            root.child(name).flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil }
        }
        func number(_ name: String) -> Int { root.child(name).flatMap { Int($0) } ?? 0 }

        guard let uniqueID = root.child("uniqueid"), HostID.isValid(uniqueID) else { throw HostError.invalidHostID }
        let state = try required("state")
        let pairStatus = try required("PairStatus") == "1"
        var currentGame = 0
        if state.hasSuffix("_SERVER_BUSY") {
            guard let game = Int(try required("currentgame")) else {
                throw HostError.malformedResponse("malformed currentgame")
            }
            currentGame = game
        }
        let name = root.child("hostname") ?? ""
        let mac = root.child("mac")
        return ServerInfo(
            hostName: name.isEmpty ? "UNKNOWN" : name,
            uniqueID: uniqueID,
            macAddress: mac?.isEmpty == false ? mac : nil,
            localIP: root.child("LocalIP").flatMap { $0.isEmpty ? nil : $0 },
            externalIP: root.child("ExternalIP").flatMap { $0.isEmpty ? nil : $0 },
            httpsPort: port("HttpsPort") ?? HostAddress.defaultHTTPSPort,
            externalPort: port("ExternalPort"),
            appVersion: root.child("appversion"),
            gfeVersion: root.child("GfeVersion"),
            codecModeSupport: number("ServerCodecModeSupport"),
            maxLumaPixelsH264: number("MaxLumaPixelsH264"),
            maxLumaPixelsHEVC: number("MaxLumaPixelsHEVC"),
            pairStatus: pairStatus,
            state: state,
            currentGame: currentGame,
            currentGameUUID: root.child("currentgameuuid"),
            permission: root.child("Permission").flatMap { Int($0) } ?? -1,
            virtualDisplayCapable: root.child("VirtualDisplayCapable") == "true",
            virtualDisplayDriverReady: root.child("VirtualDisplayDriverReady") == "true",
            serverCommands: root.children("ServerCommand").map(\.text),
            gpuType: root.child("gputype"),
            pyroWave: PyroWaveHostInfo.parse(root))
    }
}

/// An app of the host's `/applist`.
public struct HostApp: Equatable, Sendable, Codable {
    public var id: Int
    public var title: String
    public var uuid: String?
    public var isHDRSupported: Bool

    public init(id: Int, title: String, uuid: String? = nil, isHDRSupported: Bool = false) {
        self.id = id
        self.title = title
        self.uuid = uuid
        self.isHDRSupported = isHDRSupported
    }

    /// The apps in the order the host lists them. An app without a title or a numeric id is left out; a document that
    /// is not complete is rejected rather than shown in part.
    public static func parseList(_ data: Data) throws -> [HostApp] {
        let root = try HostXML.root(data)
        return root.children("App").compactMap { app in
            guard let title = app.child("AppTitle"), let id = app.child("ID").flatMap({ Int($0) }) else { return nil }
            return HostApp(id: id, title: title, uuid: app.child("UUID"), isHDRSupported: app.child("IsHdrSupported") == "1")
        }
    }
}
