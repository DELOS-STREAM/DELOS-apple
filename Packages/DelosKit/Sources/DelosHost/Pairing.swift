import CommonCrypto
import CryptoKit
import Foundation
import Security

/// How a pairing attempt ended.
public enum PairingOutcome: Equatable, Sendable {
    /// The host proved it knows the PIN and owns its certificate; that certificate is pinned from now on.
    case paired(HostPin)
    /// The host's proof did not match the PIN typed on the host.
    case pinWrong
    /// Another client is pairing with the host (it sent no certificate).
    case alreadyInProgress
    /// The host refused a step, or its signature was not valid (a man in the middle cannot sign).
    case failed
}

extension HostClient {
    /// The GameStream pairing handshake (as `PairingManager` of DELOS for Android and `PairManager` of Moonlight).
    /// The user types `pin` on the host; the PIN itself never leaves the device. Both sides prove they know it, and
    /// each proves it owns the key of its certificate. `serverInfo` decides the hash: SHA-256 from server generation 7,
    /// SHA-1 before. `passphrase` is Apollo's one-time password option, sent only as a salted hash.
    ///
    /// The steps run over plain HTTP, the final `pairchallenge` over HTTPS pinned to the certificate the host sent.
    /// After any failure past the first step, a refusal as well as a thrown error (a time-out, a broken connection, a
    /// malformed answer, cancellation), the client asks the host to `unpair`.
    public func pair(pin: String, passphrase: String? = nil, serverInfo: ServerInfo) async throws -> PairingOutcome {
        let hash = PairingHash(generation: try serverInfo.generation())
        let salt = Data(randomBytes(16))
        let aesKey = hash.digest(salt + Data(pin.utf8)).prefix(16)
        let saltHex = Hex.encode(salt)

        var first: [(String, String)] = [
            ("updateState", "1"), ("phrase", "getservercert"), ("salt", saltHex),
            ("clientcert", Hex.encode(identity.certificatePEM)),
        ]
        if let passphrase {
            first.append(("otpauth", Hex.encode(SHA256.hash(data: Data((pin + saltHex + passphrase).utf8)))))
        }
        // No time limit: the host answers once its user has typed the PIN. When the wait ends otherwise (the user left
        // the PIN screen and the task was cancelled, or the connection broke), the host is still waiting for the PIN:
        // it is told to unpair.
        let certificateAnswer: HostXMLElement
        do {
            certificateAnswer = try await pairingStep(first, timeout: nil)
        } catch {
            abandonAfterThrow()
            throw error
        }
        guard certificateAnswer.child("paired") == "1" else { return .failed }
        guard let certificateHex = certificateAnswer.child("plaincert"), !certificateHex.isEmpty else {
            try? await unpair()
            return .alreadyInProgress
        }
        guard let pem = Hex.decode(certificateHex), let serverCertificate = PEM.certificateDER(pem),
              let serverSignature = DER.certificateSignature(serverCertificate),
              let parsed = SecCertificateCreateWithData(nil, serverCertificate as CFData),
              let serverKey = SecCertificateCopyKey(parsed)
        else { return try await abandon(.failed) }

        // From here on the host holds this client's attempt. The refusals below abandon it themselves; a thrown
        // failure (a time-out, a broken connection, a malformed answer, cancellation) abandons it here.
        do {
            return try await prove(
                aesKey: aesKey, hash: hash, serverCertificate: serverCertificate, serverSignature: serverSignature,
                serverKey: serverKey, httpsPort: serverInfo.httpsPort)
        } catch {
            abandonAfterThrow()
            throw error
        }
    }

    /// The steps after the host sent its certificate: both sides prove they know the PIN and own their keys, then the
    /// final challenge goes over HTTPS pinned to the host's certificate.
    private func prove(
        aesKey: Data, hash: PairingHash, serverCertificate: Data, serverSignature: Data, serverKey: SecKey, httpsPort: Int
    ) async throws -> PairingOutcome {
        let clientChallenge = Data(randomBytes(16))
        let challengeAnswer = try await pairingStep(
            [("updateState", "1"), ("clientchallenge", Hex.encode(try PairingAES.encrypt(clientChallenge, key: aesKey)))],
            timeout: Self.requestTimeout)
        guard challengeAnswer.child("paired") == "1",
              let encryptedResponse = challengeAnswer.child("challengeresponse").flatMap(Hex.decode),
              case let response = try PairingAES.decrypt(encryptedResponse, key: aesKey),
              response.count >= hash.length + 16
        else { return try await abandon(.failed) }
        let serverResponse = response.prefix(hash.length)
        let serverChallenge = response.dropFirst(hash.length).prefix(16)

        let clientSecret = Data(randomBytes(16))
        let challengeHash = hash.digest(serverChallenge + identity.certificateSignature + clientSecret)
        let secretAnswer = try await pairingStep(
            [("updateState", "1"), ("serverchallengeresp", Hex.encode(try PairingAES.encrypt(challengeHash, key: aesKey)))],
            timeout: Self.requestTimeout)
        guard secretAnswer.child("paired") == "1",
              let pairingSecret = secretAnswer.child("pairingsecret").flatMap(Hex.decode),
              pairingSecret.count > 16
        else { return try await abandon(.failed) }
        let serverSecret = pairingSecret.prefix(16)
        let signature = pairingSecret.dropFirst(16)

        // The signature first: a host that cannot sign is not the host, whatever the PIN.
        guard Self.verify(Data(signature), of: Data(serverSecret), with: serverKey) else { return try await abandon(.failed) }
        guard hash.digest(clientChallenge + serverSignature + serverSecret) == Data(serverResponse) else {
            return try await abandon(.pinWrong)
        }

        let clientPairingSecret = clientSecret + (try identity.sign(clientSecret))
        let clientSecretAnswer = try await pairingStep(
            [("updateState", "1"), ("clientpairingsecret", Hex.encode(clientPairingSecret))], timeout: Self.requestTimeout)
        guard clientSecretAnswer.child("paired") == "1" else { return try await abandon(.failed) }

        let hostPin = HostPin(certificate: serverCertificate, httpsPort: httpsPort)
        let query = HTTPRequest.encode([("updateState", "1"), ("phrase", "pairchallenge")])
        let challenge = try HostXML.root(
            await perform("pair", query: query, pin: hostPin, timeout: Self.requestTimeout, limit: Self.xmlLimit))
        guard challenge.child("paired") == "1" else { return try await abandon(.failed) }
        return .paired(hostPin)
    }

    private func pairingStep(_ arguments: [(String, String)], timeout: Duration?) async throws -> HostXMLElement {
        try HostXML.root(
            await perform("pair", query: HTTPRequest.encode(arguments), pin: nil, timeout: timeout, limit: Self.xmlLimit))
    }

    /// A refusal or a failed proof: the host is told to unpair before the outcome is reported.
    private func abandon(_ outcome: PairingOutcome) async throws -> PairingOutcome {
        try? await unpair()
        return outcome
    }

    /// A thrown failure: the host is told to unpair from a task of its own, since a cancelled task cannot send
    /// requests, and the failure is reported without waiting for that request.
    private func abandonAfterThrow() {
        let client = self
        Task { try? await client.unpair() }
    }

    /// SHA-256 signatures with RSA (PKCS #1 v1.5) or ECDSA, by the type of the host's key.
    static func verify(_ signature: Data, of data: Data, with key: SecKey) -> Bool {
        let attributes = SecKeyCopyAttributes(key) as? [String: Any]
        let isEC = (attributes?[kSecAttrKeyType as String] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String)
        let algorithm: SecKeyAlgorithm = isEC ? .ecdsaSignatureMessageX962SHA256 : .rsaSignatureMessagePKCS1v15SHA256
        return SecKeyVerifySignature(key, algorithm, data as CFData, signature as CFData, nil)
    }

    /// A new four-digit PIN for the user to type on the host.
    public static func newPIN() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4).map { _ in String(Int.random(in: 0...9, using: &generator)) }.joined()
    }
}

/// The hash of the pairing handshake: SHA-256 from server generation 7, SHA-1 before.
struct PairingHash {
    let length: Int
    private let sha256: Bool

    init(generation: Int) {
        sha256 = generation >= 7
        length = sha256 ? 32 : 20
    }

    func digest(_ data: Data) -> Data {
        sha256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
    }
}

/// AES-128 in ECB mode without padding; the input is zero-filled to whole blocks, as the hosts expect.
enum PairingAES {
    static func encrypt(_ data: Data, key: Data) throws -> Data { try run(CCOperation(kCCEncrypt), data, key) }
    static func decrypt(_ data: Data, key: Data) throws -> Data { try run(CCOperation(kCCDecrypt), data, key) }

    private static func run(_ operation: CCOperation, _ data: Data, _ key: Data) throws -> Data {
        var input = [UInt8](data)
        input += [UInt8](repeating: 0, count: (16 - input.count % 16) % 16)
        var output = [UInt8](repeating: 0, count: input.count)
        var written = 0
        let keyBytes = [UInt8](key)
        let status = CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes, keyBytes.count, nil,
            input, input.count, &output, output.count, &written)
        guard status == kCCSuccess, keyBytes.count == 16 else { throw HostError.identity("AES failed (\(status))") }
        return Data(output.prefix(written))
    }
}
