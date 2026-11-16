import CryptoKit
import Foundation
import Testing
@testable import DelosHost

/// The pairing handshake end to end against a loopback host that implements the host side independently
/// (`FakePairingHost`). Cases ported from `PairingManagerTest.java` of DELOS for Android.
@Suite struct PairingTests {
    static let pin = "4821"

    struct Run {
        let host: FakeHost
        let pairing: FakePairingHost
        let outcome: PairingOutcome
    }

    func pair(
        _ settings: FakePairingHost.Settings = .init(pin: pin), clientGeneration: String = "7.1.431.-1",
        passphrase: String? = nil
    ) async throws -> Run {
        let pairing = FakePairingHost(identity: TestIdentities.host, settings: settings)
        let host = try await FakeHost(identity: TestIdentities.host) { pairing.respond($0) }
        let info = try ServerInfo.parse(Data(
            Documents.serverInfo(httpsPort: host.httpsPort, appVersion: clientGeneration).utf8))
        let client = HostClient(address: host.httpAddress, identity: TestIdentities.client, deviceName: "Test device")
        let outcome = try await client.pair(pin: Self.pin, passphrase: passphrase, serverInfo: info)
        return Run(host: host, pairing: pairing, outcome: outcome)
    }

    @Test func pairsWithAHostThatKnowsThePinAndPinsItsCertificate() async throws {
        let run = try await pair()

        #expect(run.outcome == .paired(HostPin(certificate: TestIdentities.host.certificate, httpsPort: run.host.httpsPort)))
        // The host accepted the client's proof (PIN knowledge and key ownership) as well.
        #expect(run.pairing.observed.clientProved)
        #expect(run.pairing.observed.pairChallengeSeen)
        // The final challenge went over HTTPS and the client presented its certificate.
        #expect(run.pairing.observed.pairChallengeClientCertificate == TestIdentities.client.certificate)
        #expect(run.pairing.observed.unpairCount == 0)
    }

    @Test func everyRequestCarriesTheClientIdAndDeviceName() async throws {
        let run = try await pair()

        for request in run.host.requests {
            #expect(request.query["uniqueid"] == TestIdentities.client.uniqueID)
            #expect(request.query["devicename"] == "Test device")
            #expect(request.query["uuid"].flatMap(UUID.init(uuidString:)) != nil)
            #expect(request.query["updateState"] == "1")
        }
        #expect(run.pairing.observed.pairRequests.first?["phrase"] == "getservercert")
    }

    @Test func thePinNeverLeavesTheDevice() async throws {
        let run = try await pair()

        for request in run.host.requests {
            #expect(!request.query.values.contains(Self.pin))
        }
    }

    @Test func everyAttemptUsesAFreshSalt() async throws {
        let first = try await pair().pairing.observed.pairRequests[0]["salt"]
        let second = try await pair().pairing.observed.pairRequests[0]["salt"]

        #expect(first?.count == 32)
        #expect(first != second)
    }

    @Test func theClientSendsItsOwnCertificateAsHexPEM() async throws {
        let sent = try await pair().pairing.observed.pairRequests[0]["clientcert"]

        #expect(sent == TestIdentities.client.certificatePEM.map { String(format: "%02X", $0) }.joined())
    }

    @Test func aWrongPinIsPinWrongAndUnpairsBeforeTheClientRevealsItsSecret() async throws {
        let run = try await pair(.init(pin: "0000"))

        #expect(run.outcome == .pinWrong)
        #expect(run.pairing.observed.unpairCount == 1)
        #expect(run.pairing.observed.pairRequests.count == 3)
        #expect(!run.pairing.observed.clientProved)
        #expect(!run.pairing.observed.pairChallengeSeen)
    }

    @Test func aForgedServerSignatureFails() async throws {
        // A man in the middle relays the real host's certificate but cannot sign with its key.
        let run = try await pair(.init(pin: Self.pin, signingKey: TestIdentities.impostor.privateKey))

        #expect(run.outcome == .failed)
        #expect(run.pairing.observed.unpairCount == 1)
        #expect(run.pairing.observed.pairRequests.count == 3)
        #expect(!run.pairing.observed.pairChallengeSeen)
    }

    @Test func aForgedSignatureFailsEvenWhenThePinIsAlsoWrong() async throws {
        let run = try await pair(.init(pin: "0000", signingKey: TestIdentities.impostor.privateKey))

        #expect(run.outcome == .failed)
        #expect(run.pairing.observed.unpairCount == 1)
    }

    @Test func anEmptyCertificateMeansAnotherClientIsPairing() async throws {
        let run = try await pair(.init(pin: Self.pin, omitCertificate: true))

        #expect(run.outcome == .alreadyInProgress)
        #expect(run.pairing.observed.unpairCount == 1)
        #expect(run.pairing.observed.pairRequests.count == 1)
    }

    @Test func aRefusedFirstRequestFailsWithoutUnpairing() async throws {
        let run = try await pair(.init(pin: Self.pin, refuseAtStep: 1))

        #expect(run.outcome == .failed)
        #expect(run.pairing.observed.unpairCount == 0)
        #expect(run.pairing.observed.pairRequests.count == 1)
    }

    @Test(arguments: [2, 3, 4])
    func aRefusalAtALaterStepFailsAndUnpairs(step: Int) async throws {
        let run = try await pair(.init(pin: Self.pin, refuseAtStep: step))

        #expect(run.outcome == .failed)
        #expect(run.pairing.observed.unpairCount == 1)
        // The handshake stops at the refused step.
        #expect(run.pairing.observed.pairRequests.count == step)
        #expect(!run.pairing.observed.pairChallengeSeen)
    }

    @Test func aRefusedPairChallengeFailsAndUnpairs() async throws {
        let run = try await pair(.init(pin: Self.pin, refusePairChallenge: true))

        #expect(run.outcome == .failed)
        #expect(run.pairing.observed.unpairCount == 1)
    }

    @Test func generation6UsesSha1() async throws {
        let run = try await pair(.init(pin: Self.pin, sha256: false), clientGeneration: "6.0.0.0")

        #expect(run.outcome == .paired(HostPin(certificate: TestIdentities.host.certificate, httpsPort: run.host.httpsPort)))
        #expect(run.pairing.observed.clientProved)
    }

    @Test func aHashMismatchBetweenGenerationsIsNotAccepted() async throws {
        // The client believes generation 6 (SHA-1) while the host hashes with SHA-256.
        let run = try await pair(clientGeneration: "6.0.0.0")

        #expect(run.outcome != .paired(HostPin(certificate: TestIdentities.host.certificate, httpsPort: run.host.httpsPort)))
        #expect(run.pairing.observed.unpairCount == 1)
    }

    @Test func aPassphraseIsSentAsASaltedHashOnly() async throws {
        let run = try await pair(passphrase: "correct horse")

        let first = run.pairing.observed.pairRequests[0]
        let expected = SHA256.hash(data: Data((Self.pin + first["salt"]! + "correct horse").utf8))
            .map { String(format: "%02X", $0) }.joined()
        #expect(first["otpauth"] == expected)
        #expect(run.host.requests.allSatisfy { !$0.rawQuery.contains("horse") })
    }

    @Test func withoutAPassphraseNoOtpFieldIsSent() async throws {
        let run = try await pair()

        #expect(run.pairing.observed.pairRequests[0]["otpauth"] == nil)
    }

    @Test func aMissingAppVersionCannotChooseTheHash() async throws {
        let info = try ServerInfo.parse(Data(Documents.sunshine.replacingOccurrences(
            of: "<appversion>7.1.431.-1</appversion>", with: "").utf8))
        let client = HostClient(address: HostAddress(host: "127.0.0.1", port: 9), identity: TestIdentities.client)

        await #expect(throws: HostError.malformedResponse("no appversion")) {
            try await client.pair(pin: Self.pin, serverInfo: info)
        }
    }

    @Test func newPinsAreFourDigits() {
        for _ in 0..<200 {
            let pin = HostClient.newPIN()
            #expect(pin.count == 4 && pin.allSatisfy(\.isASCII) && pin.allSatisfy(\.isNumber))
        }
    }

    @Test func leavingWhileTheHostWaitsForThePinAsksItToUnpair() async throws {
        // The host never answers getservercert: its user has not typed the PIN
        let host = try await FakeHost(identity: TestIdentities.host) { request in
            request.path.hasSuffix("unpair") ? .xml("<root status_code=\"200\"/>") : .init(body: Data(), silent: true)
        }
        let info = try ServerInfo.parse(Data(Documents.serverInfo(httpsPort: host.httpsPort, appVersion: "7.1.431.-1").utf8))
        let client = HostClient(address: host.httpAddress, identity: TestIdentities.client)
        let task = Task { try await client.pair(pin: Self.pin, serverInfo: info) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!host.requests.contains { $0.path.hasSuffix("unpair") })

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<50 where !host.requests.contains(where: { $0.path.hasSuffix("unpair") }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.requests.contains { $0.path.hasSuffix("unpair") })
    }
}
