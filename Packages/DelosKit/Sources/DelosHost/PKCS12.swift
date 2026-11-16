import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Makes a `SecIdentity` (what TLS needs to present a certificate) from a private key and its certificate without
/// putting them into any keychain: they are packed into a PKCS #12 container (RFC 7292) that only lives in memory and
/// imported with `kSecImportToMemoryOnly`. `SecPKCS12Import` accepts only password-protected containers, so the key is
/// encrypted with PBES2 (PBKDF2-HMAC-SHA256, AES-256-CBC) and the container carries an HMAC-SHA256, both under a
/// random password that is thrown away after the import.
enum PKCS12 {
    static let iterations = 2048

    static func identity(privateKeyPKCS1: Data, certificate: Data) throws -> SecIdentity {
        let password = Hex.encode(randomBytes(16))
        let container = try make(privateKeyPKCS1: privateKeyPKCS1, certificate: certificate, password: password)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        let status = SecPKCS12Import(Data(container) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let first = (items as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String]
        else { throw HostError.identity("PKCS #12 import failed (\(status))") }
        return identity as! SecIdentity // a CF type: the cast cannot fail
    }

    static func make(privateKeyPKCS1: Data, certificate: Data, password: String) throws -> [UInt8] {
        let keyID = Array(Insecure.SHA1.hash(data: certificate))
        let localKeyID = DER.sequence(
            DER.objectIdentifier("1.2.840.113549.1.9.21"), DER.set(DER.octetString(keyID)))

        let certBag = DER.sequence(
            DER.objectIdentifier("1.2.840.113549.1.12.10.1.3"),
            DER.explicit(0, DER.sequence(
                DER.objectIdentifier("1.2.840.113549.1.9.22.1"),
                DER.explicit(0, DER.octetString(certificate)))),
            DER.set(localKeyID))

        let privateKeyInfo = DER.sequence(
            DER.integer(0),
            DER.sequence(DER.objectIdentifier("1.2.840.113549.1.1.1"), DER.null),
            DER.octetString(privateKeyPKCS1))
        let salt = randomBytes(16)
        let iv = randomBytes(16)
        let key = try pbkdf2(password: Array(password.utf8), salt: salt, rounds: iterations, length: 32)
        let encrypted = try aes256CBC(privateKeyInfo, key: key, iv: iv)
        let pbes2 = DER.sequence(
            DER.objectIdentifier("1.2.840.113549.1.5.13"),
            DER.sequence(
                DER.sequence(
                    DER.objectIdentifier("1.2.840.113549.1.5.12"),
                    DER.sequence(
                        DER.octetString(salt), DER.integer(iterations),
                        DER.sequence(DER.objectIdentifier("1.2.840.113549.2.9"), DER.null))),
                DER.sequence(DER.objectIdentifier("2.16.840.1.101.3.4.1.42"), DER.octetString(iv))))
        let keyBag = DER.sequence(
            DER.objectIdentifier("1.2.840.113549.1.12.10.1.2"),
            DER.explicit(0, DER.sequence(pbes2, DER.octetString(encrypted))),
            DER.set(localKeyID))

        let authenticatedSafe = DER.sequence(dataContent(DER.sequence(certBag)), dataContent(DER.sequence(keyBag)))

        let macSalt = randomBytes(16)
        let macKey = pkcs12KDF(password: password, salt: macSalt, id: 3, rounds: iterations, length: 32)
        let mac = Array(HMAC<SHA256>.authenticationCode(for: authenticatedSafe, using: SymmetricKey(data: macKey)))
        let macData = DER.sequence(
            DER.sequence(
                DER.sequence(DER.objectIdentifier("2.16.840.1.101.3.4.2.1"), DER.null),
                DER.octetString(mac)),
            DER.octetString(macSalt),
            DER.integer(iterations))

        return DER.sequence(DER.integer(3), dataContent(authenticatedSafe), macData)
    }

    /// ContentInfo of type `data` (PKCS #7) around `content`.
    private static func dataContent(_ content: [UInt8]) -> [UInt8] {
        DER.sequence(DER.objectIdentifier("1.2.840.113549.1.7.1"), DER.explicit(0, DER.octetString(content)))
    }

    /// The key derivation of RFC 7292 appendix B.2 with SHA-256 (u = 32, v = 64), used for the container's MAC.
    static func pkcs12KDF(password: String, salt: [UInt8], id: UInt8, rounds: Int, length: Int) -> [UInt8] {
        let u = 32
        let v = 64
        var passwordBytes = [UInt8]()
        for unit in password.utf16 { passwordBytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        passwordBytes += [0, 0]
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let count = v * ((bytes.count + v - 1) / v)
            return (0..<count).map { bytes[$0 % bytes.count] }
        }
        var input = stretch(salt) + stretch(passwordBytes)
        let diversifier = [UInt8](repeating: id, count: v)
        var output = [UInt8]()
        while output.count < length {
            var a = Array(SHA256.hash(data: diversifier + input))
            for _ in 1..<rounds { a = Array(SHA256.hash(data: a)) }
            output += a.prefix(min(u, length - output.count))
            let b = (0..<v).map { a[$0 % u] }
            for block in stride(from: 0, to: input.count, by: v) {
                var carry = 1
                for index in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(input[block + index]) + Int(b[index]) + carry
                    input[block + index] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return output
    }

    static func pbkdf2(password: [UInt8], salt: [UInt8], rounds: Int, length: Int) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: length)
        let status = password.withUnsafeBufferPointer { pass in
            pass.withMemoryRebound(to: CChar.self) { passChars in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), passChars.baseAddress, pass.count, salt, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, length)
            }
        }
        guard status == kCCSuccess else { throw HostError.identity("PBKDF2 failed (\(status))") }
        return key
    }

    private static func aes256CBC(_ plain: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            key, key.count, iv, plain, plain.count, &out, out.count, &written)
        guard status == kCCSuccess else { throw HostError.identity("AES-CBC failed (\(status))") }
        return Array(out.prefix(written))
    }
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "the system random number generator failed")
    return bytes
}
