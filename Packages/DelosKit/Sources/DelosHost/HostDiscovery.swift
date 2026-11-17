import Foundation
import Network
import Synchronization

/// A host that announced itself on the local network, resolved to an address.
public struct DiscoveredHost: Hashable, Sendable {
    /// The Bonjour service name (the PC's name as the host announces it).
    public let serviceName: String
    /// The address and HTTP port the service resolved to.
    public let address: HostAddress
}

public enum DiscoveryEvent: Hashable, Sendable {
    case found(DiscoveredHost)
    case lost(serviceName: String)
    /// Browsing stopped, for example because the user denied local network access.
    case failed(String)
}

/// The services one browse accepts: a hostile network cannot make the app resolve and list any number of them.
struct ServiceLimit {
    static let maximum = 32
    private(set) var names: Set<String> = []

    /// A service that went away makes room for another.
    mutating func release(_ name: String) { names.remove(name) }

    /// True for a service already admitted or one that still fits.
    mutating func admit(_ name: String) -> Bool {
        if names.contains(name) { return true }
        guard names.count < Self.maximum else { return false }
        names.insert(name)
        return true
    }
}

/// Finds GameStream hosts with Bonjour (`_nvstream._tcp`). Each service is resolved by opening a TCP connection to it
/// and reading the remote address; the connection is closed right away.
public struct HostDiscovery: Sendable {
    public static let gameStreamService = "_nvstream._tcp"

    public let serviceType: String
    public let resolveTimeout: Duration

    public init(serviceType: String = gameStreamService, resolveTimeout: Duration = .seconds(5)) {
        self.serviceType = serviceType
        self.resolveTimeout = resolveTimeout
    }

    /// Events until the consumer stops iterating; browsing stops with it.
    public func events() -> AsyncStream<DiscoveryEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: DiscoveryEvent.self)
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: NWParameters())
        let resolving = Resolutions()
        let admitted = Mutex(ServiceLimit())
        let queue = DispatchQueue(label: "io.github.meitoncz.delos.host.discovery")
        let timeout = resolveTimeout

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error), .waiting(let error):
                continuation.yield(.failed(String(describing: error)))
                if case .failed = state { continuation.finish() }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    guard case .service(let name, _, _, _) = result.endpoint, admitted.withLock({ $0.admit(name) }) else { continue }
                    Self.resolve(result.endpoint, name: name, on: queue, timeout: timeout, resolving: resolving) {
                        continuation.yield(.found($0))
                    }
                case .removed(let result):
                    guard case .service(let name, _, _, _) = result.endpoint else { continue }
                    admitted.withLock { $0.release(name) }
                    continuation.yield(.lost(serviceName: name))
                default: break
                }
            }
        }
        continuation.onTermination = { _ in
            browser.cancel()
            resolving.connections.withLock { connections in
                connections.values.forEach { $0.cancel() }
                connections.removeAll()
            }
        }
        browser.start(queue: queue)
        return stream
    }

    /// The resolutions that are running, by service name.
    private final class Resolutions: Sendable {
        let connections = Mutex<[String: NWConnection]>([:])
    }

    private static func resolve(
        _ endpoint: NWEndpoint, name: String, on queue: DispatchQueue, timeout: Duration,
        resolving: Resolutions, found: @escaping @Sendable (DiscoveredHost) -> Void
    ) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving.connections.withLock { $0[name]?.cancel(); $0[name] = connection }
        let finish: @Sendable () -> Void = {
            connection.cancel()
            resolving.connections.withLock { if $0[name] === connection { $0[name] = nil } }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint, let address = address(of: remote) {
                    found(DiscoveredHost(serviceName: name, address: address))
                }
                finish()
            case .failed, .waiting:
                finish()
            default: break
            }
        }
        connection.start(queue: queue)
        let seconds = timeout.components.seconds
        queue.asyncAfter(deadline: .now() + .seconds(Int(seconds))) { finish() }
    }

    /// The address of a resolved endpoint; nil for endpoints that are not a host and port.
    static func address(of endpoint: NWEndpoint) -> HostAddress? {
        guard case .hostPort(let host, let port) = endpoint, port.rawValue > 0 else { return nil }
        let text: String
        switch host {
        // Without the interface (`%en0`) that Network.framework appends; an IPv6 link-local address needs it.
        case .ipv4(let address): text = address.rawValue.map(String.init).joined(separator: ".")
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: return nil
        }
        return HostAddress(host: text, port: Int(port.rawValue))
    }
}
