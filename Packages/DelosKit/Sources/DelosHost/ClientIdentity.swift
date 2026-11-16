import Foundation
import Security

/// Who this device is to a host: an RSA 2048 key, a self-signed X.509 certificate for it and a client id. Pairing
/// shows the certificate to the host; afterwards the host knows the device by it in every HTTPS request.
///
/// Immutable; the Security objects it holds are thread-safe, which is why the type is `@unchecked Sendable`.
public final class ClientIdentity: @unchecked Sendable {
    /// The common name GameStream clients put into their certificate (as Moonlight does).
    public static let commonName = "NVIDIA GameStream Client"

    /// 16 upper-case hexadecimal digits, sent as `uniqueid` in every request.
    public let uniqueID: String
    /// The certificate, DER.
    public let certificate: Data
    /// The private key, PKCS #1 DER.
    public let privateKey: Data

    let key: SecKey
    let secIdentity: SecIdentity

    /// Rebuilds a stored identity. Throws when the key or the certificate cannot be read or do not belong together.
    public init(privateKey: Data, certificate: Data, uniqueID: String) throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, &error) else {
            throw HostError.identity("unreadable private key: \(String(describing: error?.takeRetainedValue()))")
        }
        guard let parsed = SecCertificateCreateWithData(nil, certificate as CFData),
              let certificateKey = SecCertificateCopyKey(parsed),
              let publicKey = SecKeyCopyPublicKey(key),
              let certificateKeyData = SecKeyCopyExternalRepresentation(certificateKey, nil),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil),
              (certificateKeyData as Data) == (publicKeyData as Data)
        else { throw HostError.identity("the certificate does not belong to the key") }
        guard Self.isValidUniqueID(uniqueID) else { throw HostError.identity("invalid client id") }
        self.uniqueID = uniqueID
        self.certificate = certificate
        self.privateKey = privateKey
        self.key = key
        self.secIdentity = try PKCS12.identity(privateKeyPKCS1: privateKey, certificate: certificate)
    }

    /// A new key, a certificate valid for 20 years from `now` and a random client id.
    public static func generate(now: Date = .now) throws -> ClientIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error),
              let privateKeyData = SecKeyCopyExternalRepresentation(key, &error)
        else { throw HostError.identity("RSA key generation failed: \(String(describing: error?.takeRetainedValue()))") }
        let certificate = try SelfSignedCertificate.make(
            commonName: commonName, publicKeyPKCS1: publicKeyData as Data, notBefore: now,
            notAfter: now.addingTimeInterval(20 * 365 * 24 * 3600), signer: key)
        return try ClientIdentity(
            privateKey: privateKeyData as Data, certificate: certificate, uniqueID: Hex.encode(randomBytes(8)))
    }

    /// The certificate in PEM, as the `clientcert` pairing argument carries it (hex-encoded).
    public var certificatePEM: Data { PEM.certificate(certificate) }

    /// The signature value of the client certificate, part of the pairing hashes.
    var certificateSignature: Data { DER.certificateSignature(certificate)! }

    func sign(_ data: Data) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error)
        else { throw HostError.identity("signing failed: \(String(describing: error?.takeRetainedValue()))") }
        return signature as Data
    }

    static func isValidUniqueID(_ id: String) -> Bool {
        id.utf8.count == 16 && Hex.decode(id) != nil
    }
}

/// A self-signed X.509 v3 certificate (RFC 5280) with SHA-256 with RSA, the subject also as issuer and no extensions,
/// like the certificate Moonlight makes.
enum SelfSignedCertificate {
    static func make(
        commonName: String, publicKeyPKCS1: Data, notBefore: Date, notAfter: Date, signer: SecKey
    ) throws -> Data {
        let algorithm = DER.sequence(DER.objectIdentifier("1.2.840.113549.1.1.11"), DER.null)
        let name = DER.sequence(DER.set(DER.sequence(DER.objectIdentifier("2.5.4.3"), DER.utf8String(commonName))))
        var serial = randomBytes(16)
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let tbs = DER.sequence(
            DER.explicit(0, DER.integer(2)),
            DER.integer(unsigned: serial),
            algorithm,
            name,
            DER.sequence(DER.time(notBefore), DER.time(notAfter)),
            name,
            DER.sequence(
                DER.sequence(DER.objectIdentifier("1.2.840.113549.1.1.1"), DER.null),
                DER.bitString(publicKeyPKCS1)))
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            signer, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &error)
        else { throw HostError.identity("certificate signing failed: \(String(describing: error?.takeRetainedValue()))") }
        return Data(DER.sequence(tbs, algorithm, DER.bitString(signature as Data)))
    }
}

/// PEM (RFC 7468) for certificates.
enum PEM {
    static func certificate(_ der: Data) -> Data {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(base64)\n-----END CERTIFICATE-----\n".utf8)
    }

    /// The DER of the first certificate in `pem`; nil when there is none.
    static func certificateDER(_ pem: Data) -> Data? {
        let text = String(decoding: pem, as: UTF8.self)
        guard let begin = text.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = text.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<text.endIndex)
        else { return nil }
        let body = text[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        return Data(base64Encoded: String(body))
    }
}
