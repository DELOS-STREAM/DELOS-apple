import DelosHost
import Foundation
import Observation

/// The PCs DELOS knows: the paired ones (stored) and the ones found on the network this session. Each record is
/// updated only by the rules of `HostRecord` (an answer that is not verified never overwrites what pairing stored).
@MainActor
@Observable
public final class HostStore {
    /// Every known PC, paired first, then by name.
    public private(set) var hosts: [HostRecord] = []
    /// The apps of each PC as last loaded, by host id.
    public private(set) var apps: [String: [HostApp]] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let identities: ClientIdentityStore
    @ObservationIgnored private var cachedIdentity: ClientIdentity?
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private let deviceName: String
    private static let key = "hosts"

    public init(defaults: UserDefaults = .standard, identities: ClientIdentityStore = ClientIdentityStore(), deviceName: String = "DELOS") {
        self.defaults = defaults
        self.identities = identities
        self.deviceName = deviceName
        hosts = Self.load(defaults)
    }

    public var paired: [HostRecord] { hosts.filter { $0.pin != nil } }

    public func host(_ id: String) -> HostRecord? { hosts.first { $0.id == id } }

    /// The client's key and certificate, created on first use.
    public func identity() throws -> ClientIdentity {
        if let cachedIdentity { return cachedIdentity }
        let identity = try identities.loadOrCreate()
        cachedIdentity = identity
        return identity
    }

    private func client(_ address: HostAddress) throws -> HostClient {
        HostClient(address: address, identity: try identity(), deviceName: deviceName)
    }

    // MARK: Finding PCs

    /// Starts looking for PCs on the local network; each one found is asked for its server info.
    public func startDiscovery() {
        guard discovery == nil else { return }
        discovery = Task { [weak self] in
            for await event in HostDiscovery().events() {
                guard case let .found(found) = event else { continue }
                _ = try? await self?.ask(found.address)
            }
        }
    }

    public func stopDiscovery() {
        discovery?.cancel()
        discovery = nil
    }

    /// Asks a PC at `address` (found or typed) who it is and merges the answer. Returns the record.
    @discardableResult
    public func ask(_ address: HostAddress, typed: Bool = false) async throws -> HostRecord {
        let reply = try await client(address).serverInfo(pin: nil)
        var record: HostRecord
        if let known = host(reply.info.uniqueID) {
            // A paired PC is refreshed over its pinned connection; this unverified answer only says it is reachable
            record = try known.updated(with: reply)
        } else {
            record = HostRecord(firstReply: reply)
        }
        if typed { record.manualAddress = address }
        store(record)
        return record
    }

    /// Asks a known PC again (over HTTPS to its pinned certificate once paired) and stores the answer; a PC that does
    /// not answer is marked offline.
    public func refresh(_ id: String) async {
        guard let record = host(id), let address = record.activeAddress ?? record.manualAddress ?? record.localAddress else { return }
        do {
            let reply = try await client(address).serverInfo(pin: record.pin)
            store(try record.updated(with: reply))
        } catch {
            store(record.markedOffline())
        }
    }

    // MARK: Pairing

    /// A random four-digit PIN, shown to the user to type on the PC.
    public static func newPIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    /// Pairs with a PC: the user types `pin` on the PC while this waits. A successful pairing pins the PC's
    /// certificate.
    public func pair(_ id: String, pin: String, passphrase: String? = nil) async throws -> PairingOutcome {
        guard let record = host(id), let address = record.activeAddress ?? record.manualAddress ?? record.localAddress else {
            throw HostError.unreachable(id)
        }
        let client = try client(address)
        let info = try await client.serverInfo(pin: nil).info
        let outcome = try await client.pair(pin: pin, passphrase: passphrase, serverInfo: info)
        if case let .paired(hostPin) = outcome {
            store(record.paired(with: hostPin))
            await refresh(id)
        }
        return outcome
    }

    /// Forgets the pairing on both sides (the PC is asked to unpair; locally the pin is removed either way).
    public func unpair(_ id: String) async {
        guard let record = host(id) else { return }
        if let address = record.activeAddress ?? record.localAddress { try? await client(address).unpair() }
        store(record.unpaired())
        apps[id] = nil
    }

    // MARK: Managing PCs

    /// Gives a PC a name of its own in DELOS on this device (`PcRepository.rename` of DELOS for Android); a blank name
    /// returns to the PC's own name. The name is trimmed and at most ``maxNameLength`` characters.
    public func rename(_ id: String, to name: String) {
        guard var record = host(id) else { return }
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))
        record.customName = clean.isEmpty ? nil : clean
        store(record)
    }

    /// The longest name of a PC, in characters (the rename field of DELOS for Android takes 24).
    public static let maxNameLength = 24

    /// What sending the Wake-on-LAN packet to a PC did (`WakeResult` of DELOS for Android).
    public enum WakeResult: Equatable, Sendable {
        /// The packet went out; whether the PC wakes cannot be known.
        case sent
        /// The PC never told its MAC address, so it cannot be woken from here.
        case noMAC
        /// The packet could not be sent.
        case failed
    }

    /// Sends the Wake-on-LAN packet to every known address of a PC and to the broadcast address.
    public func wake(_ id: String) async -> WakeResult {
        guard let record = host(id), let mac = record.macAddress else { return .noMAC }
        var addresses: [HostAddress] = []
        for address in [record.activeAddress, record.localAddress, record.manualAddress, record.remoteAddress] {
            if let address, !addresses.contains(address) { addresses.append(address) }
        }
        return await WakeOnLan.wake(macAddress: mac, addresses: addresses) > 0 ? .sent : .failed
    }

    /// Quits the app that runs on a paired PC (`cancel`), then asks the PC again so its record knows. Throws what the
    /// PC answered (`HostError.refused`: it did not quit the app).
    public func quitApp(_ id: String) async throws {
        let (client, _, pin) = try pairedClient(id)
        try await client.cancel(pin: pin)
        await refresh(id)
    }

    // MARK: Apps

    /// Loads a paired PC's apps.
    @discardableResult
    public func loadApps(_ id: String) async throws -> [HostApp] {
        guard let record = host(id), let pin = record.pin, let address = record.activeAddress ?? record.localAddress else { return [] }
        let list = try await client(address).appList(pin: pin)
        apps[id] = list
        return list
    }

    /// A client for a paired PC's requests (launch, resume, quit, box art).
    public func pairedClient(_ id: String) throws -> (HostClient, HostRecord, HostPin) {
        guard let record = host(id), let pin = record.pin, let address = record.activeAddress ?? record.localAddress ?? record.manualAddress else {
            throw HostError.unreachable(id)
        }
        return (try client(address), record, pin)
    }

    // MARK: Storage

    func store(_ record: HostRecord) {
        if let index = hosts.firstIndex(where: { $0.id == record.id }) { hosts[index] = record } else { hosts.append(record) }
        hosts.sort { ($0.pin != nil ? 0 : 1, $0.name.lowercased()) < ($1.pin != nil ? 0 : 1, $1.name.lowercased()) }
        // Only paired PCs are kept across launches; found ones are found again
        if let data = try? JSONEncoder().encode(hosts.filter { $0.pin != nil }) { defaults.set(data, forKey: Self.key) }
    }

    private static func load(_ defaults: UserDefaults) -> [HostRecord] {
        guard let data = defaults.data(forKey: key), let records = try? JSONDecoder().decode([LenientRecord].self, from: data) else { return [] }
        return records.compactMap(\.record).map { $0.markedOffline() }
    }

    /// One stored record; one that no longer decodes is skipped instead of losing every PC.
    private struct LenientRecord: Decodable {
        let record: HostRecord?
        init(from decoder: any Decoder) throws {
            record = try? HostRecord(from: decoder)
        }
    }
}
