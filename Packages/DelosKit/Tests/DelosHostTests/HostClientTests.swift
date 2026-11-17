import Foundation
import Network
import Testing
@testable import DelosHost

/// The requests of `HostClient` against a loopback host: channels, the exclusive pin (S-07 of DELOS for Android, cases
/// of `NvHttpTlsPinningTest.java` and `PairedHostTrustTest.java`), and what each answer turns into.
@Suite struct HostClientTests {
    static let appList = """
        <?xml version="1.0" encoding="utf-8"?>
        <root status_code="200"><App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle>\
        <UUID>11111111-2222-3333-4444-555555555555</UUID><IDX>0</IDX><ID>881448767</ID></App>\
        <App><IsHdrSupported>0</IsHdrSupported><AppTitle>Steam Big Picture</AppTitle><ID>1093255277</ID></App></root>
        """

    /// A host answering `serverinfo` (paired over HTTPS, not paired over HTTP, like Sunshine), `applist`, `appasset`,
    /// `launch`, `resume` and `cancel`.
    func host(identity: ClientIdentity = TestIdentities.host, httpsStatus: Int = 200) async throws -> FakeHost {
        try await FakeHost(identity: identity) { request in
            if request.secure && httpsStatus != 200 {
                return .init(status: httpsStatus, body: Data())
            }
            switch request.path {
            case "/serverinfo": return .xml(Documents.serverInfo(paired: request.secure, name: request.secure ? "HTTPS" : "HTTP"))
            case "/applist": return .xml(Self.appList)
            case "/appasset": return .init(body: Data([0x89, 0x50, 0x4E, 0x47, UInt8(request.query["appid"]!.count)]))
            case "/launch": return .xml(#"<root status_code="200"><gamesession>1</gamesession><sessionUrl0>rtspenc://127.0.0.1:48010</sessionUrl0></root>"#)
            case "/resume": return .xml(#"<root status_code="200"><resume>0</resume></root>"#)
            case "/cancel": return .xml(#"<root status_code="200"><cancel>1</cancel></root>"#)
            default: return .init(status: 404, body: Data())
            }
        }
    }

    func client(_ host: FakeHost) -> HostClient {
        HostClient(address: host.httpAddress, identity: TestIdentities.client)
    }

    @Test func withoutAPinServerInfoIsReadOverPlainHTTP() async throws {
        let host = try await host()

        let reply = try await client(host).serverInfo(pin: nil)

        #expect(reply.source == .plainHTTP)
        #expect(reply.info.hostName == "HTTP")
        #expect(reply.address == host.httpAddress)
        #expect(host.requests.map(\.secure) == [false])
    }

    @Test func withThePinnedCertificateServerInfoComesOverHTTPSWithTheClientCertificate() async throws {
        let host = try await host()

        let reply = try await client(host).serverInfo(pin: host.pin())

        #expect(reply.source == .pinnedHTTPS)
        #expect(reply.info.hostName == "HTTPS")
        #expect(reply.info.pairStatus)
        #expect(host.requests.map(\.secure) == [true])
        #expect(host.requests[0].clientCertificate == TestIdentities.client.certificate)
    }

    @Test func anotherCertificateIsNeverTrustedAndServerInfoFallsBackToUnverifiedHTTP() async throws {
        // The host presents a different certificate than the one pinned at pairing.
        let host = try await host(identity: TestIdentities.impostor)

        let reply = try await client(host).serverInfo(pin: host.pin(TestIdentities.host.certificate))

        #expect(reply.source == .plainHTTP)
        #expect(reply.info.hostName == "HTTP")
        // The handshake was refused before any HTTPS request reached the host.
        #expect(host.requests.map(\.secure) == [false])
    }

    @Test func aHostThatNoLongerKnowsTheClientIsReadOverUnverifiedHTTP() async throws {
        let host = try await host(httpsStatus: 401)

        let reply = try await client(host).serverInfo(pin: host.pin())

        #expect(reply.source == .plainHTTP)
        #expect(host.requests.map(\.secure) == [true, false])
    }

    @Test func otherHTTPSErrorsAreNotHiddenByAFallback() async throws {
        let host = try await host(httpsStatus: 503)

        await #expect(throws: HostError.httpStatus(503)) { try await client(host).serverInfo(pin: host.pin()) }
        #expect(host.requests.count == 1)
    }

    @Test func pinnedRequestsRejectAnotherCertificate() async throws {
        let host = try await host(identity: TestIdentities.impostor)
        let pin = host.pin(TestIdentities.host.certificate)

        await #expect(throws: HostError.certificateMismatch) { try await client(host).appList(pin: pin) }
        await #expect(throws: HostError.certificateMismatch) { try await client(host).appAsset(appID: 1, pin: pin) }
        await #expect(throws: HostError.certificateMismatch) { try await client(host).cancel(pin: pin) }
        #expect(host.requests.isEmpty)
    }

    @Test func appListOverThePinnedConnection() async throws {
        let host = try await host()

        let apps = try await client(host).appList(pin: host.pin())

        #expect(apps == [
            HostApp(id: 881448767, title: "Desktop", uuid: "11111111-2222-3333-4444-555555555555", isHDRSupported: true),
            HostApp(id: 1093255277, title: "Steam Big Picture"),
        ])
        #expect(host.requests.map(\.path) == ["/applist"])
        #expect(host.requests[0].secure)
    }

    @Test func boxArtIsTheAssetOfTheApp() async throws {
        let host = try await host()

        let data = try await client(host).appAsset(appID: 1234, pin: host.pin())

        #expect(data == Data([0x89, 0x50, 0x4E, 0x47, 4]))
        #expect(host.requests[0].query["appid"] == "1234")
        #expect(host.requests[0].query["AssetType"] == "2")
        #expect(host.requests[0].query["AssetIdx"] == "0")
    }

    @Test func launchSendsTheRequestAndReturnsTheSessionURL() async throws {
        let host = try await host()
        let request = LaunchRequestTests.request()

        let session = try await client(host).launch(request, nvidiaServer: false, pin: host.pin())

        #expect(session == "rtspenc://127.0.0.1:48010")
        #expect(host.requests[0].path == "/launch")
        #expect(host.requests[0].secure)
        #expect(host.requests[0].rawQuery.hasPrefix(request.query(nvidiaServer: false) + "&uniqueid="))
    }

    @Test func aRefusedResumeIsAnError() async throws {
        let host = try await host()

        await #expect(throws: HostError.refused) {
            try await client(host).resume(LaunchRequestTests.request(), nvidiaServer: false, pin: host.pin())
        }
    }

    @Test func cancelQuitsTheApp() async throws {
        let host = try await host()

        try await client(host).cancel(pin: host.pin())

        #expect(host.requests.map(\.path) == ["/cancel"])
    }

    @Test func anInvalidHostIdIsRejected() async throws {
        let host = try await FakeHost(identity: TestIdentities.host) { _ in .xml(Documents.serverInfo(id: "../../databases")) }

        await #expect(throws: HostError.invalidHostID) { try await client(host).serverInfo(pin: nil) }
    }

    @Test func aClosedPortIsUnreachable() async throws {
        // Nothing listens on TCP port 1 of the loopback interface.
        let client = HostClient(address: HostAddress(host: "127.0.0.1", port: 1), identity: TestIdentities.client)

        await #expect {
            try await client.serverInfo(pin: nil)
        } throws: { error in
            if case HostError.unreachable = error { true } else { false }
        }
    }

    @Test func aHostThatDoesNotAnswerTimesOut() async throws {
        let host = try await FakeHost(identity: TestIdentities.host) { _ in .init(body: Data(), silent: true) }
        let request = HTTPRequest(
            address: host.httpAddress, path: "/serverinfo", query: "", tls: nil, timeout: .milliseconds(300),
            maximumBodySize: 1024)

        await #expect(throws: HostError.timedOut) { try await HTTPTransport.get(request) }
    }

    @Test func aRequestWithoutATimeLimitEndsWhenItsTaskIsCancelled() async throws {
        let host = try await FakeHost(identity: TestIdentities.host) { _ in .init(body: Data(), silent: true) }
        let request = HTTPRequest(
            address: host.httpAddress, path: "/launch", query: "", tls: nil, timeout: nil, maximumBodySize: 1024)
        let task = Task { try await HTTPTransport.get(request) }
        try await Task.sleep(for: .milliseconds(200))

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func anAnswerLargerThanTheLimitIsRefused() async throws {
        let host = try await FakeHost(identity: TestIdentities.host) { _ in .init(body: Data(count: 4096)) }
        let request = HTTPRequest(
            address: host.httpAddress, path: "/appasset", query: "", tls: nil, timeout: .seconds(5), maximumBodySize: 1024)

        await #expect(throws: HostError.responseTooLarge) { try await HTTPTransport.get(request) }
    }

    @Test func quittingLaunchingAndResumingGiveUpOnAHostThatStalls() async throws {
        let host = try await FakeHost(identity: TestIdentities.host) { _ in .init(body: Data(), silent: true) }
        var client = HostClient(address: host.httpAddress, identity: TestIdentities.client)
        client.cancelLimit = .milliseconds(200)
        client.launchLimit = .milliseconds(200)
        let pin = host.pin()
        let request = LaunchRequestTests.request()

        await #expect(throws: HostError.timedOut) { try await client.cancel(pin: pin) }
        await #expect(throws: HostError.timedOut) { _ = try await client.launch(request, nvidiaServer: false, pin: pin) }
        await #expect(throws: HostError.timedOut) { _ = try await client.resume(request, nvidiaServer: false, pin: pin) }
    }

    @Test func theDefaultLimitsAreSetForEverySlowRequest() {
        let client = HostClient(address: HostAddress(host: "127.0.0.1", port: 1), identity: TestIdentities.client)
        #expect(client.cancelLimit == .seconds(30))
        #expect(client.launchLimit == .seconds(120))
    }
}
