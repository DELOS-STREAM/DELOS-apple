import Foundation

/// What the app knows about one host. A value: `DelosData` stores it, the poll makes new versions with `updated(with:)`.
public struct HostRecord: Equatable, Sendable, Codable {
    public enum Reachability: String, Equatable, Sendable, Codable {
        case unknown, online, offline
    }

    /// The host's `uniqueid`; never changes.
    public private(set) var id: String
    public var name: String
    /// `LocalIP` with the HTTP port the host was reached on.
    public var localAddress: HostAddress?
    /// `ExternalIP` with the external port.
    public var remoteAddress: HostAddress?
    /// The address the user typed.
    public var manualAddress: HostAddress?
    public var macAddress: String?
    public var httpsPort: Int
    public var externalPort: Int?
    public var appVersion: String?
    public var gfeVersion: String?
    public var codecModeSupport: Int
    public var isNvidiaServer: Bool
    /// `PairStatus` of the last verified answer.
    public var hostReportsPaired: Bool
    public var runningAppID: Int
    /// The certificate pinned at pairing (DER); nil before pairing. Only `paired(with:)` sets it.
    public private(set) var pinnedCertificate: Data?

    /// Where the last answer came from; not part of what the host is.
    public var reachability: Reachability
    public var activeAddress: HostAddress?
    /// The last answer came over HTTPS to the pinned certificate. False for a paired host means: something answers
    /// for it, but has not proved to be it (another certificate, or the host no longer knows this client).
    public var lastReplyVerified: Bool

    /// A record from the first answer of a host (discovery or a typed address); not paired.
    public init(firstReply reply: ServerInfoReply) {
        id = reply.info.uniqueID
        name = reply.info.hostName
        httpsPort = reply.info.httpsPort
        codecModeSupport = 0
        isNvidiaServer = false
        hostReportsPaired = false
        runningAppID = 0
        reachability = .unknown
        lastReplyVerified = false
        self = applyingAll(reply)
    }

    public var pin: HostPin? {
        pinnedCertificate.map { HostPin(certificate: $0, httpsPort: httpsPort) }
    }

    /// The record after a successful pairing.
    public func paired(with pin: HostPin) -> HostRecord {
        var record = self
        record.pinnedCertificate = pin.certificate
        record.httpsPort = pin.httpsPort
        return record
    }

    /// The record after the user unpaired or removed the pin.
    public func unpaired() -> HostRecord {
        var record = self
        record.pinnedCertificate = nil
        record.hostReportsPaired = false
        record.lastReplyVerified = false
        return record
    }

    public func markedOffline() -> HostRecord {
        var record = self
        record.reachability = .offline
        record.runningAppID = 0
        return record
    }

    /// The record after a `serverinfo` answer. An unverified answer never overwrites stored data (S-06 of DELOS for
    /// Android): for a paired host, an answer over plain HTTP changes only where the host answered and that it did not
    /// prove itself. Before pairing no answer can be verified, so plain HTTP fills the record; the pin itself is only
    /// ever set by pairing. Throws `differentHost` when the answer is from another host.
    public func updated(with reply: ServerInfoReply) throws -> HostRecord {
        guard reply.info.uniqueID == id else { throw HostError.differentHost }
        if pinnedCertificate != nil && reply.source != .pinnedHTTPS {
            var record = self
            record.reachability = .online
            record.activeAddress = reply.address
            record.lastReplyVerified = false
            return record
        }
        if pinnedCertificate == nil && reply.source == .pinnedHTTPS {
            throw HostError.malformedResponse("a pinned answer for a host without a pin")
        }
        return applyingAll(reply)
    }

    private func applyingAll(_ reply: ServerInfoReply) -> HostRecord {
        let info = reply.info
        var record = self
        record.name = info.hostName
        // The IPv4 loopback address comes from IPv6 forwarders on the host; it does not reach the PC from here.
        if let local = info.localIP, !local.hasPrefix("127.") {
            record.localAddress = HostAddress(host: local, port: reply.address.port)
        }
        let externalPort = info.externalPort ?? reply.address.port
        if let external = info.externalIP {
            record.remoteAddress = HostAddress(host: external, port: externalPort)
        } else if let remote = record.remoteAddress, let port = info.externalPort {
            record.remoteAddress = HostAddress(host: remote.host, port: port)
        }
        if let mac = info.macAddress, mac != "00:00:00:00:00:00" {
            record.macAddress = mac
        }
        record.httpsPort = info.httpsPort
        record.externalPort = info.externalPort
        record.appVersion = info.appVersion
        record.gfeVersion = info.gfeVersion
        record.codecModeSupport = info.codecModeSupport
        record.isNvidiaServer = info.isNvidiaServer
        record.hostReportsPaired = reply.source == .pinnedHTTPS && info.pairStatus
        record.runningAppID = info.currentGame
        record.reachability = .online
        record.activeAddress = reply.address
        record.lastReplyVerified = reply.source == .pinnedHTTPS
        return record
    }
}
