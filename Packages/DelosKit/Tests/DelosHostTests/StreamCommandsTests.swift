import Foundation
import Testing
@testable import DelosHost

/// The requests a running stream makes over the pinned connection: Vibepollo's live bitrate change (the cases of
/// `RuntimeBitrateTest.java` of DELOS for Android) and Apollo's clipboard.
@Suite struct StreamCommandsTests {
    func client(_ host: FakeHost) -> HostClient {
        HostClient(address: host.httpAddress, identity: TestIdentities.client)
    }

    func host(_ respond: @escaping FakeHost.Handler) async throws -> FakeHost {
        try await FakeHost(identity: TestIdentities.host, handler: respond)
    }

    // MARK: Bitrate

    @Test func theBitrateIsAskedOverHTTPSAndTheAppliedOneReturned() async throws {
        let host = try await host { _ in .xml(#"<root status_code="200"><bitrate>40000</bitrate></root>"#) }

        let applied = try await client(host).setRuntimeBitrate(50000, pin: host.pin())

        #expect(applied == 40000)
        #expect(host.requests.count == 1)
        #expect(host.requests[0].path == "/bitrate")
        #expect(host.requests[0].query["bitrate"] == "50000")
        #expect(host.requests[0].secure)
        #expect(host.requests[0].method == "GET")
    }

    @Test(arguments: [999, 1_000_001])
    func aBitrateOutOfRangeIsNotSent(kbps: Int) async throws {
        let host = try await host { _ in .xml(#"<root status_code="200"><bitrate>1000</bitrate></root>"#) }

        await #expect(throws: RuntimeBitrateOutOfRange(kbps: kbps)) { try await client(host).setRuntimeBitrate(kbps, pin: host.pin()) }
        #expect(host.requests.isEmpty)
    }

    @Test func aHostWithoutTheCommandAnswers404() async throws {
        let host = try await host { _ in .init(status: 404, body: Data()) }

        await #expect(throws: HostError.httpStatus(404)) { try await client(host).setRuntimeBitrate(20000, pin: host.pin()) }
    }

    @Test func anHTTPErrorCarriesTheReasonPhrase() async throws {
        let host = try await host { _ in .init(status: 503, body: Data(), reason: "Service Unavailable") }

        await #expect(throws: HostError.hostStatus(code: 503, message: "Service Unavailable")) {
            try await client(host).setRuntimeBitrate(20000, pin: host.pin())
        }
    }

    @Test func anXMLErrorWithStatus200IsTheHostsRefusal() async throws {
        let host = try await host { _ in .xml(#"<root status_code="403" status_message="Not allowed"/>"#) }

        await #expect(throws: HostError.hostStatus(code: 403, message: "Not allowed")) {
            try await client(host).setRuntimeBitrate(20000, pin: host.pin())
        }
    }

    @Test(arguments: ["0", "-1", "nan", "2147483648", "1000001", "999", nil])
    func anUnconfirmedBitrateIsAnError(value: String?) async throws {
        let field = value.map { "<bitrate>\($0)</bitrate>" } ?? ""
        let host = try await host { _ in .xml(#"<root status_code="200">\#(field)</root>"#) }

        await #expect(throws: HostError.self) { try await client(host).setRuntimeBitrate(20000, pin: host.pin()) }
    }

    @Test func anXMLErrorIsNotMistakenForSuccessEvenWithABitrate() async throws {
        let host = try await host { _ in .xml(#"<root status_code="403" status_message="Denied"><bitrate>0</bitrate></root>"#) }

        await #expect(throws: HostError.hostStatus(code: 403, message: "Denied")) {
            try await client(host).setRuntimeBitrate(20000, pin: host.pin())
        }
    }

    @Test func theHostsCeilingIsAccepted() async throws {
        let host = try await host { request in .xml(#"<root status_code="200"><bitrate>\#(request.query["bitrate"]!)</bitrate></root>"#) }

        #expect(try await client(host).setRuntimeBitrate(1000, pin: host.pin()) == 1000)
        #expect(try await client(host).setRuntimeBitrate(1_000_000, pin: host.pin()) == 1_000_000)
    }

    // MARK: Clipboard

    @Test func theClipboardIsFetchedAsText() async throws {
        let host = try await host { _ in .init(body: Data("Příliš žluťoučký kůň".utf8)) }

        let text = try await client(host).clipboard(pin: host.pin())

        #expect(text == "Příliš žluťoučký kůň")
        #expect(host.requests[0].path == "/actions/clipboard")
        #expect(host.requests[0].query["type"] == "text")
        #expect(host.requests[0].secure)
    }

    @Test func theClipboardIsSentAsAPostOfPlainText() async throws {
        let host = try await host { _ in .init(body: Data()) }

        let taken = try await client(host).sendClipboard("ahoj 👋", pin: host.pin())

        #expect(taken)
        let request = try #require(host.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/actions/clipboard")
        #expect(request.query["type"] == "text")
        #expect(request.query["uniqueid"] != nil)
        #expect(request.headers["content-type"] == "text/plain; charset=utf-8")
        #expect(String(decoding: request.body, as: UTF8.self) == "ahoj 👋")
    }

    @Test func aHostThatAnswersSendingWithABodyDoesNotSupportIt() async throws {
        // Sunshine answers the unknown command with 200 and its XML (NvHTTP.java:1012-1013)
        let host = try await host { _ in .xml(#"<root status_code="404" status_message="Not Found"/>"#) }

        #expect(try await client(host).sendClipboard("text", pin: host.pin()) == false)
    }

    @Test func aClipboardThatFailsThrows() async throws {
        let host = try await host { _ in .init(status: 404, body: Data()) }

        await #expect(throws: HostError.httpStatus(404)) { try await client(host).clipboard(pin: host.pin()) }
        await #expect(throws: HostError.httpStatus(404)) { try await client(host).sendClipboard("x", pin: host.pin()) }
    }
}
