import Foundation
import Security

/// Where secrets are kept. The app uses `KeychainStorage`; tests use an in-memory store.
public protocol SecretStorage: Sendable {
    /// Nil when nothing is stored under `account`; throws when the store cannot be read.
    func read(account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// Generic-password items of the data protection keychain, readable after the first unlock, never synchronized and
/// never restored to another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). On the Mac they are items of
/// the user's login keychain: the data protection keychain there needs an application identifier from a provisioning
/// profile, which the ad-hoc signed local build (`tools/mac.sh`) does not have (error -34018).
public struct KeychainStorage: SecretStorage {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if !os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func read(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HostError.identity("keychain read failed (\(status))")
        }
        return data
    }

    public func write(_ data: Data, account: String) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw HostError.identity("keychain write failed (\(status))") }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HostError.identity("keychain delete failed (\(status))")
        }
    }
}

/// Loads the client identity, or makes and stores one on first use. The key, the certificate and the client id are one
/// property-list item, so they are always written together.
public struct ClientIdentityStore: Sendable {
    public static let defaultService = "io.github.meitoncz.delos.client-identity"
    static let account = "client-identity"

    private struct Stored: Codable {
        var privateKey: Data
        var certificate: Data
        var uniqueID: String
    }

    private let storage: any SecretStorage

    public init(storage: any SecretStorage = KeychainStorage(service: ClientIdentityStore.defaultService)) {
        self.storage = storage
    }

    /// The stored identity, or a new one. A stored item that cannot be decoded is replaced: it could not be used, and
    /// the hosts have to be paired again either way. A failure to read the store is thrown, never treated as "empty".
    public func loadOrCreate() throws -> ClientIdentity {
        if let data = try storage.read(account: Self.account),
           let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
           let identity = try? ClientIdentity(
               privateKey: stored.privateKey, certificate: stored.certificate, uniqueID: stored.uniqueID) {
            return identity
        }
        let identity = try ClientIdentity.generate()
        let stored = Stored(
            privateKey: identity.privateKey, certificate: identity.certificate, uniqueID: identity.uniqueID)
        try storage.write(try PropertyListEncoder().encode(stored), account: Self.account)
        return identity
    }

    /// Forgets the identity; every host has to be paired again.
    public func reset() throws {
        try storage.delete(account: Self.account)
    }
}
