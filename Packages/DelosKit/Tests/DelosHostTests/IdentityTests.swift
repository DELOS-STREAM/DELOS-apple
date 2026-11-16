import Foundation
import Security
import Synchronization
import Testing
@testable import DelosHost

/// The client identity: the generated certificate as the Security framework reads it, the in-memory PKCS #12 import
/// and the store.
@Suite struct ClientIdentityTests {
    let identity = TestIdentities.client

    @Test func theCertificateIsAValidSelfSignedX509ForTheKey() throws {
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificate as CFData))

        #expect(SecCertificateCopySubjectSummary(certificate) as String? == ClientIdentity.commonName)
        // The certificate's public key is the identity's key.
        let certificateKey = try #require(SecCertificateCopyKey(certificate))
        let publicKey = try #require(SecKeyCopyPublicKey(identity.key))
        #expect(SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        #expect(SecKeyGetBlockSize(publicKey) * 8 == 2048)
        // The signature value read out of the certificate verifies over its to-be-signed part with that key.
        let outer = try #require(DER.read(ArraySlice(identity.certificate)))
        let tbs = try #require(DER.read(outer.content))
        let tbsBytes = Data(outer.content[outer.content.startIndex..<tbs.rest.startIndex])
        let signature = try #require(DER.certificateSignature(identity.certificate))
        #expect(signature.count == 256)
        #expect(SecKeyVerifySignature(certificateKey, .rsaSignatureMessagePKCS1v15SHA256, tbsBytes as CFData, signature as CFData, nil))
    }

    @Test func theCertificateIsValidForTwentyYears() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = try ClientIdentity.generate(now: now)
        let certificate = try #require(SecCertificateCreateWithData(nil, identity.certificate as CFData))
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, policy, &trust)
        let evaluated = try #require(trust)
        SecTrustSetAnchorCertificates(evaluated, [certificate] as CFArray)

        for (offset, valid) in [(-60.0, false), (60.0, true), (19 * 365 * 86400.0, true), (21 * 365 * 86400.0, false)] {
            SecTrustSetVerifyDate(evaluated, now.addingTimeInterval(offset) as CFDate)
            #expect(SecTrustEvaluateWithError(evaluated, nil) == valid, "offset \(offset)")
        }
    }

    @Test func theClientIdIsSixteenHexDigits() {
        #expect(identity.uniqueID.count == 16)
        #expect(Hex.decode(identity.uniqueID) != nil)
        #expect(identity.uniqueID != TestIdentities.host.uniqueID)
    }

    @Test func pemRoundTripsTheCertificate() throws {
        let pem = String(decoding: identity.certificatePEM, as: UTF8.self)

        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        #expect(pem.hasSuffix("\n-----END CERTIFICATE-----\n"))
        #expect(pem.split(separator: "\n").dropFirst().dropLast().allSatisfy { $0.count <= 64 })
        #expect(PEM.certificateDER(identity.certificatePEM) == identity.certificate)
    }

    @Test func theTLSIdentityCarriesTheCertificate() throws {
        var certificate: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity.secIdentity, &certificate) == errSecSuccess)
        #expect(certificate.map { SecCertificateCopyData($0) as Data } == identity.certificate)
    }

    @Test func aContainerWithAWrongMacIsRefused() throws {
        // The import checks the container's HMAC: the password-based MAC key derivation matches the system's.
        var container = try PKCS12.make(privateKeyPKCS1: identity.privateKey, certificate: identity.certificate, password: "pw")
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: "pw", kSecImportToMemoryOnly as String: true] as CFDictionary
        #expect(SecPKCS12Import(Data(container) as CFData, options, &items) == errSecSuccess)

        // The container ends with the 32-byte MAC value, its 16-byte salt (18 bytes DER) and the 2048 iterations (4).
        container[container.count - 30] ^= 0x01
        #expect(SecPKCS12Import(Data(container) as CFData, options, &items) != errSecSuccess)
    }

    @Test func aStoredIdentityIsRebuiltAndCheckedAgainstItsKey() throws {
        let rebuilt = try ClientIdentity(
            privateKey: identity.privateKey, certificate: identity.certificate, uniqueID: identity.uniqueID)
        #expect(rebuilt.certificate == identity.certificate)

        #expect(throws: HostError.identity("the certificate does not belong to the key")) {
            try ClientIdentity(privateKey: identity.privateKey, certificate: TestIdentities.host.certificate, uniqueID: identity.uniqueID)
        }
        #expect(throws: HostError.identity("invalid client id")) {
            try ClientIdentity(privateKey: identity.privateKey, certificate: identity.certificate, uniqueID: "../x")
        }
    }

    @Test func derLengthsAndIntegers() {
        #expect(DER.length(0x7F) == [0x7F])
        #expect(DER.length(0x80) == [0x81, 0x80])
        #expect(DER.length(0x1234) == [0x82, 0x12, 0x34])
        #expect(DER.integer(0) == [0x02, 0x01, 0x00])
        #expect(DER.integer(128) == [0x02, 0x02, 0x00, 0x80])
        #expect(DER.objectIdentifier("1.2.840.113549.1.1.11") == [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        #expect(DER.read([0x30, 0x05, 0x01][...]) == nil)
    }
}

/// The identity store with an in-memory backend. `KeychainStorage` itself cannot run here: the data protection
/// keychain needs an application identifier entitlement, which neither `swift test` on the Mac nor the package tests
/// in the simulator have (errSecMissingEntitlement, -34018).
@Suite struct ClientIdentityStoreTests {
    final class MemoryStorage: SecretStorage {
        let items = Mutex<[String: Data]>([:])
        let failReads = Atomic<Bool>(false)

        func read(account: String) throws -> Data? {
            if failReads.load(ordering: .relaxed) { throw HostError.identity("locked") }
            return items.withLock { $0[account] }
        }

        func write(_ data: Data, account: String) throws { items.withLock { $0[account] = data } }
        func delete(account: String) throws { _ = items.withLock { $0.removeValue(forKey: account) } }
    }

    @Test func theFirstUseCreatesAnIdentityThatIsLoadedFromThenOn() throws {
        let storage = MemoryStorage()
        let store = ClientIdentityStore(storage: storage)

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(second.certificate == first.certificate)
        #expect(second.privateKey == first.privateKey)
        #expect(second.uniqueID == first.uniqueID)
    }

    @Test func anUnreadableStoredItemIsReplaced() throws {
        let storage = MemoryStorage()
        storage.items.withLock { $0[ClientIdentityStore.account] = Data("garbage".utf8) }

        let identity = try ClientIdentityStore(storage: storage).loadOrCreate()

        #expect(try ClientIdentityStore(storage: storage).loadOrCreate().certificate == identity.certificate)
    }

    @Test func aStoreThatCannotBeReadIsAnErrorNotANewIdentity() throws {
        let storage = MemoryStorage()
        let store = ClientIdentityStore(storage: storage)
        let identity = try store.loadOrCreate()
        storage.failReads.store(true, ordering: .relaxed)

        #expect(throws: HostError.identity("locked")) { try store.loadOrCreate() }
        storage.failReads.store(false, ordering: .relaxed)
        #expect(try store.loadOrCreate().certificate == identity.certificate)
    }

    @Test func resetForgetsTheIdentity() throws {
        let storage = MemoryStorage()
        let store = ClientIdentityStore(storage: storage)
        let identity = try store.loadOrCreate()

        try store.reset()

        #expect(try store.loadOrCreate().certificate != identity.certificate)
    }
}
