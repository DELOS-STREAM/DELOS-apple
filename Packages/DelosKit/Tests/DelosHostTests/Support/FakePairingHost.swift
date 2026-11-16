import CommonCrypto
import CryptoKit
import Foundation
import Security
import Synchronization
@testable import DelosHost

/// The host side of the GameStream pairing handshake, ported from `FakePairingHost.java` of DELOS for Android. It is
/// written apart from the client's code (its own AES, hashing and hex), so the client is checked against a second
/// implementation of the protocol and not against itself. Answers `/pair` and `/unpair` of a `FakeHost`.
final class FakePairingHost: Sendable {
    struct Settings: Sendable {
        /// The PIN the host's user typed.
        var pin: String
        /// SHA-256 for generation 7 and later, SHA-1 before.
        var sha256 = true
        /// Signs the pairing secret with this key instead of the host's own (an impostor).
        var signingKey: Data?
        /// Another client is already pairing: the first answer carries no certificate.
        var omitCertificate = false
        /// 1-based index of the pairing command answered with paired=0; 0 = never.
        var refuseAtStep = 0
        var refusePairChallenge = false
    }

    struct Observed: Sendable {
        var pairRequests: [[String: String]] = []
        var unpairCount = 0
        /// The client proved it knows the PIN and owns its certificate's key.
        var clientProved = false
        var pairChallengeSeen = false
        var pairChallengeClientCertificate: Data?
    }

    private struct Session {
        var aesKey = Data()
        var clientCertificate = Data()
        var clientChallengeHash = Data()
    }

    let identity: ClientIdentity
    let settings: Settings
    private let state = Mutex<(Observed, Session)>((Observed(), Session()))
    private let serverSecret = Data(repeating: 0x51, count: 16)
    private let serverChallenge = Data(repeating: 0x33, count: 16)

    init(identity: ClientIdentity, settings: Settings) {
        self.identity = identity
        self.settings = settings
    }

    var observed: Observed { state.withLock { $0.0 } }

    func respond(_ request: FakeHost.Request) -> FakeHost.Response {
        switch request.path {
        case "/unpair":
            state.withLock { $0.0.unpairCount += 1 }
            return .xml(#"<root status_code="200"></root>"#)
        case "/pair":
            return .xml(pair(request))
        default:
            return FakeHost.Response(status: 404, body: Data())
        }
    }

    private func pair(_ request: FakeHost.Request) -> String {
        let args = request.query
        if args["phrase"] == "pairchallenge" {
            state.withLock {
                $0.0.pairChallengeSeen = true
                $0.0.pairChallengeClientCertificate = request.clientCertificate
            }
            return #"<root status_code="200"><paired>\#(settings.refusePairChallenge ? 0 : 1)</paired></root>"#
        }
        let step = state.withLock { state -> Int in
            state.0.pairRequests.append(args)
            return state.0.pairRequests.count
        }
        let refused = #"<root status_code="200"><paired>0</paired></root>"#
        if step == settings.refuseAtStep { return refused }

        if args["phrase"] == "getservercert" {
            let salt = unhex(args["salt"]!)
            let pem = unhex(args["clientcert"]!)
            let certificate = PEM.certificateDER(pem)!
            let key = hash(salt + Data(settings.pin.utf8)).prefix(16)
            state.withLock { $0.1.aesKey = Data(key); $0.1.clientCertificate = certificate }
            return ok(settings.omitCertificate ? "" : "<plaincert>\(hex(PEM.certificate(identity.certificate)))</plaincert>")
        }
        let key = state.withLock { $0.1.aesKey }
        if let challenge = args["clientchallenge"] {
            let clientChallenge = aes(decrypt: true, unhex(challenge), key: key).prefix(16)
            let response = hash(clientChallenge + signatureOf(identity.certificate) + serverSecret)
            return ok("<challengeresponse>\(hex(aes(decrypt: false, response + serverChallenge, key: key)))</challengeresponse>")
        }
        if let answer = args["serverchallengeresp"] {
            let decrypted = aes(decrypt: true, unhex(answer), key: key).prefix(settings.sha256 ? 32 : 20)
            state.withLock { $0.1.clientChallengeHash = Data(decrypted) }
            let signer = privateKey(settings.signingKey ?? identity.privateKey)
            let signature = SecKeyCreateSignature(signer, .rsaSignatureMessagePKCS1v15SHA256, serverSecret as CFData, nil)! as Data
            return ok("<pairingsecret>\(hex(serverSecret + signature))</pairingsecret>")
        }
        if let secret = args["clientpairingsecret"] {
            let data = unhex(secret)
            let clientSecret = data.prefix(16)
            let signature = data.dropFirst(16)
            let session = state.withLock { $0.1 }
            let certificate = SecCertificateCreateWithData(nil, session.clientCertificate as CFData)!
            let signed = SecKeyVerifySignature(
                SecCertificateCopyKey(certificate)!, .rsaSignatureMessagePKCS1v15SHA256, Data(clientSecret) as CFData,
                Data(signature) as CFData, nil)
            let knowsPin = session.clientChallengeHash
                == hash(serverChallenge + signatureOf(session.clientCertificate) + clientSecret)
            state.withLock { $0.0.clientProved = signed && knowsPin }
            return signed && knowsPin ? ok("") : refused
        }
        fatalError("unexpected pairing command \(request.rawQuery)")
    }

    private func ok(_ body: String) -> String {
        #"<root status_code="200"><paired>1</paired>\#(body)</root>"#
    }

    private func hash(_ data: Data) -> Data {
        settings.sha256 ? Data(SHA256.hash(data: data)) : Data(Insecure.SHA1.hash(data: data))
    }

    private func privateKey(_ pkcs1: Data) -> SecKey {
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary
        return SecKeyCreateWithData(pkcs1 as CFData, attributes, nil)!
    }

    /// The certificate's signature value: the last element of the outer SEQUENCE, a BIT STRING.
    private func signatureOf(_ certificate: Data) -> Data {
        DER.certificateSignature(certificate)!
    }

    /// AES-128 ECB with a CCCryptor, the input zero-filled to whole blocks.
    private func aes(decrypt: Bool, _ data: Data, key: Data) -> Data {
        let padded = data + Data(count: (16 - data.count % 16) % 16)
        var cryptor: CCCryptorRef?
        _ = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(
                CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                keyBytes.baseAddress, 16, nil, &cryptor)
        }
        var out = Data(count: padded.count)
        var moved = 0
        _ = out.withUnsafeMutableBytes { outBytes in
            padded.withUnsafeBytes { inBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, padded.count, outBytes.baseAddress, padded.count, &moved)
            }
        }
        CCCryptorRelease(cryptor)
        return out.prefix(moved)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func unhex(_ text: String) -> Data {
        var out = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            out.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return out
    }
}
