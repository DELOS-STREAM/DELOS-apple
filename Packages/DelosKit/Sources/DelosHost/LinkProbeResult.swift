import Foundation
import Network
import Synchronization

/// The kind of network a result was measured on; the cheap stand-in for a network identity (a Wi-Fi network's name
/// needs a location permission) (LinkResult.kt). The raw values are the stored names.
public enum LinkTransport: String, CaseIterable, Equatable, Sendable {
    case wifi = "WIFI"
    case ethernet = "ETHERNET"
    case other = "OTHER"

    public static func parse(_ name: String?) -> LinkTransport { name.flatMap(LinkTransport.init(rawValue:)) ?? .other }

    /// The kind of network the device is on now (`currentTransport`): wired Ethernet first, then Wi-Fi, else another one.
    public static var current: LinkTransport { CurrentPath.shared.transport }

    /// The path monitor that keeps ``current`` up to date for the whole app.
    private final class CurrentPath: Sendable {
        static let shared = CurrentPath()
        private let monitor = NWPathMonitor()
        private let value = Mutex<LinkTransport>(.other)

        private init() {
            monitor.pathUpdateHandler = { [self] path in
                value.withLock { $0 = LinkTransport(path) }
            }
            monitor.start(queue: DispatchQueue(label: "io.github.meitoncz.delos.host.path"))
            let path = monitor.currentPath
            value.withLock { $0 = LinkTransport(path) }
        }

        var transport: LinkTransport { value.withLock { $0 } }
    }

    init(_ path: NWPath) {
        if path.usesInterfaceType(.wiredEthernet) {
            self = .ethernet
        } else if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else {
            self = .other
        }
    }
}

/// The last confirmed link test of one PC on one kind of network. [wireKbps] is the total wire allowance the path carried
/// twice (5 % margin included). Never applied by itself: it only feeds the recommendation.
public struct LinkTest: Equatable, Sendable {
    public var wireKbps: Int
    /// Milliseconds since 1970.
    public var testedAtMs: Int64
    public var transport: LinkTransport
    public var criticalFECPercent: Int
    public var packetSize: Int

    public init(wireKbps: Int, testedAtMs: Int64, transport: LinkTransport, criticalFECPercent: Int, packetSize: Int) {
        self.wireKbps = wireKbps
        self.testedAtMs = testedAtMs
        self.transport = transport
        self.criticalFECPercent = criticalFECPercent
        self.packetSize = packetSize
    }

    /// `1;wireKbps;testedAtMs;TRANSPORT;criticalFec;packetSize`, the same text DELOS for Android stores.
    public func encode() -> String {
        "1;\(wireKbps);\(testedAtMs);\(transport.rawValue);\(criticalFECPercent);\(packetSize)"
    }

    /// Nil for anything this version did not write.
    public static func decode(_ text: String?) -> LinkTest? {
        guard let parts = text?.split(separator: ";", omittingEmptySubsequences: false).map(String.init),
              parts.count == 6, parts[0] == "1",
              let wire = Int(parts[1]), wire >= LinkPolicy.minKbps,
              let at = Int64(parts[2]), let fec = Int(parts[4]), let size = Int(parts[5]) else { return nil }
        return LinkTest(wireKbps: wire, testedAtMs: at, transport: .parse(parts[3]), criticalFECPercent: fec, packetSize: size)
    }
}
