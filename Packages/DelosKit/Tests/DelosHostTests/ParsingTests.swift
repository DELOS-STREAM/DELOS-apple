import Foundation
import Testing
@testable import DelosHost

/// What the client reads out of `/serverinfo` and `/applist` (cases of `ServerInfoParsingTest.java`, DELOS for Android).
@Suite struct ServerInfoParsingTests {
    func parse(_ text: String) throws -> ServerInfo { try ServerInfo.parse(Data(text.utf8)) }

    @Test func sunshine() throws {
        let info = try parse(Documents.sunshine)

        #expect(info.hostName == "LIVINGROOM")
        #expect(info.uniqueID == "2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F")
        #expect(info.httpsPort == 48984)
        #expect(info.externalPort == 48989)
        #expect(info.macAddress == "a0:b1:c2:d3:e4:f5")
        #expect(info.localIP == "192.168.1.20")
        #expect(info.externalIP == nil)
        #expect(info.pairStatus)
        #expect(info.currentGame == 0)
        #expect(info.currentGameUUID == nil)
        #expect(!info.isNvidiaServer)
        #expect(!info.virtualDisplayCapable)
        #expect(info.serverCommands.isEmpty)
        #expect(info.permission == -1)
        #expect(info.appVersion == "7.1.431.-1")
        #expect(info.gfeVersion == "3.23.0.74")
    }

    @Test func apolloWithARunningApp() throws {
        let info = try parse(Documents.apolloBusy)

        #expect(info.hostName == "DESK")
        #expect(info.currentGame == 881448767)
        #expect(info.currentGameUUID == "8CB5C136-DA67-4F99-B4A1-F9CD35005CF4")
        #expect(info.permission == 117506049)
        #expect(info.virtualDisplayCapable)
        #expect(info.virtualDisplayDriverReady)
        #expect(info.serverCommands == ["Sleep", "Restart Steam"])
        #expect(info.externalIP == "203.0.113.9")
        #expect(info.localIP == "10.0.0.7")
    }

    @Test func geForceExperienceInUTF16() throws {
        let info = try ServerInfo.parse(Documents.gfe.data(using: .utf16)!)

        #expect(info.hostName == "OLDPC")
        #expect(info.isNvidiaServer)
        #expect(!info.pairStatus)
        // GeForce Experience keeps the last game in currentgame; it only counts while the server is busy.
        #expect(info.currentGame == 0)
        #expect(info.externalPort == nil)
        #expect(info.httpsPort == 47984)
        #expect(info.codecModeSupport == 0)
        #expect(info.maxLumaPixelsHEVC == 0)
        #expect(info.maxLumaPixelsH264 == 0)
    }

    @Test func codecAndLumaFields() throws {
        let info = try parse(Documents.sunshine)

        #expect(info.codecModeSupport == 3843)
        #expect(info.maxLumaPixelsHEVC == 1869449984)
    }

    @Test func aHostWithoutANameStillHasOne() throws {
        let info = try parse(Documents.sunshine.replacingOccurrences(of: "<hostname>LIVINGROOM</hostname>", with: "<hostname></hostname>"))

        #expect(info.hostName == "UNKNOWN")
    }

    @Test func aNonNumericPermissionIsNoPermission() throws {
        let info = try parse(Documents.apolloBusy.replacingOccurrences(of: "<Permission>117506049", with: "<Permission>all"))

        #expect(info.permission == -1)
    }

    @Test func aMissingOrUnusableHostIdIsRejected() {
        let id = "2A6F3E0B-11C4-4E7B-9E2D-5B6A7C8D9E0F"
        for replacement in ["", "<uniqueid></uniqueid>", "<uniqueid>../../databases</uniqueid>", "<uniqueid>a/b</uniqueid>"] {
            #expect(throws: HostError.invalidHostID) {
                try parse(Documents.sunshine.replacingOccurrences(of: "<uniqueid>\(id)</uniqueid>", with: replacement))
            }
        }
    }

    @Test func missingPairStatusOrStateIsRejected() {
        #expect(throws: HostError.malformedResponse("no PairStatus")) {
            try parse(Documents.sunshine.replacingOccurrences(of: "<PairStatus>1</PairStatus>", with: ""))
        }
        #expect(throws: HostError.malformedResponse("no state")) {
            try parse(Documents.sunshine.replacingOccurrences(of: "<state>SUNSHINE_SERVER_FREE</state>", with: ""))
        }
    }

    @Test func anErrorStatusIsAnErrorNotAHost() {
        #expect(throws: HostError.hostStatus(code: 401, message: "Unauthorized")) {
            try parse(#"<root status_code="401" status_message="Unauthorized"><hostname>X</hostname><uniqueid>1</uniqueid></root>"#)
        }
        // 0xFFFFFFFF is -1; with "Invalid" it is GeForce Experience's missing audio device.
        #expect(throws: HostError.hostStatus(code: 418, message: "Missing audio capture device. Reinstall GeForce Experience.")) {
            try parse(#"<root status_code="4294967295" status_message="Invalid"></root>"#)
        }
    }

    @Test func aTruncatedDocumentIsRejected() {
        let cut = String(Documents.sunshine.prefix(upTo: Documents.sunshine.range(of: "<uniqueid>")!.upperBound))

        #expect(throws: HostError.malformedResponse("not well-formed XML")) { try parse(cut) }
    }

    @Test func outOfRangePortsFallBack() throws {
        let info = try parse(Documents.sunshine
            .replacingOccurrences(of: "<HttpsPort>48984", with: "<HttpsPort>0")
            .replacingOccurrences(of: "<ExternalPort>48989", with: "<ExternalPort>70000"))

        #expect(info.httpsPort == 47984)
        #expect(info.externalPort == nil)
        #expect(try parse(Documents.sunshine.replacingOccurrences(of: "<HttpsPort>48984</HttpsPort>", with: "")).httpsPort == 47984)
    }

    @Test func theServerGenerationComesFromTheAppVersion() throws {
        let info = try parse(Documents.sunshine)

        #expect(try info.generation() == 7)
        #expect(try info.appVersionQuad() == [7, 1, 431, -1])
        #expect(throws: HostError.malformedResponse("malformed appversion 7.1")) {
            try parse(Documents.sunshine.replacingOccurrences(of: "7.1.431.-1", with: "7.1")).generation()
        }
    }

    // MARK: /applist

    func apps(_ text: String) throws -> [HostApp] { try HostApp.parseList(Data(text.utf8)) }

    @Test func appListWithHdrFlagsAndUuids() throws {
        #expect(try apps(HostClientTests.appList) == [
            HostApp(id: 881448767, title: "Desktop", uuid: "11111111-2222-3333-4444-555555555555", isHDRSupported: true),
            HostApp(id: 1093255277, title: "Steam Big Picture"),
        ])
    }

    @Test func anAppWithoutAUsableIdOrTitleIsDropped() throws {
        let list = try apps("""
            <root status_code="200"><App><AppTitle>Broken</AppTitle><ID>not-a-number</ID></App>\
            <App><AppTitle>Nameless id</AppTitle></App><App><ID>9</ID></App><App><AppTitle>Good</AppTitle><ID>7</ID></App></root>
            """)

        #expect(list == [HostApp(id: 7, title: "Good")])
    }

    @Test func anEmptyAppListIsEmpty() throws {
        #expect(try apps(#"<root status_code="200"></root>"#).isEmpty)
    }

    @Test func aTruncatedAppListIsRejectedInsteadOfShownHalf() {
        #expect(throws: HostError.malformedResponse("not well-formed XML")) {
            try apps(#"<root status_code="200"><App><AppTitle>Desktop</AppTitle><ID>1</ID></App><App><AppTitle>Stea"#)
        }
    }

    @Test func anAppListErrorStatusIsAnError() {
        #expect(throws: HostError.hostStatus(code: 503, message: "Busy")) {
            try apps(#"<root status_code="503" status_message="Busy"></root>"#)
        }
    }
}

/// The launch and resume query (as `NvHTTP.launchApp` of DELOS for Android builds it). Nothing is launched: the
/// requests in `HostClientTests` go to the loopback host only.
@Suite struct LaunchRequestTests {
    static func request(width: Int = 2560, height: Int = 1440, frameRate: Double = 120, hdr: Bool = true) -> LaunchRequest {
        LaunchRequest(
            appID: 881448767, appUUID: "11111111-2222-3333-4444-555555555555", width: width, height: height,
            frameRate: frameRate, resolutionScaleFactor: 100, optimizeGameSettings: true,
            remoteInputKey: Data(0..<16), remoteInputKeyID: 1234, hdr: hdr, virtualDisplay: false, playAudioOnHost: false,
            surroundAudioInfo: 196610, gamepadMask: 1, persistGamepadsAfterDisconnect: true, coreParameters: "&corever=1")
    }

    @Test func theQueryCarriesEveryField() {
        #expect(Self.request().query(nvidiaServer: false) == "appid=881448767&appuuid=11111111-2222-3333-4444-555555555555"
            + "&mode=2560x1440x120&scaleFactor=100&additionalStates=1&sops=1&rikey=000102030405060708090A0B0C0D0E0F"
            + "&rikeyid=1234&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0"
            + "&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
            + "&virtualDisplay=0&localAudioPlayMode=0&surroundAudioInfo=196610&remoteControllersBitmap=1&gcmap=1"
            + "&gcpersist=1&corever=1")
    }

    @Test func withoutHdrNoHdrFieldsAreSent() {
        #expect(!Self.request(hdr: false).query(nvidiaServer: false).contains("hdrMode"))
    }

    @Test func aFractionalFrameRateIsSentInThousandths() {
        #expect(Self.request(frameRate: 59.94).query(nvidiaServer: false).contains("&mode=2560x1440x59940&"))
    }

    @Test func geForceExperienceGetsZeroAbove60FpsAndNoSopsAtUnknownResolutions() {
        let query = Self.request().query(nvidiaServer: true)

        #expect(query.contains("&mode=2560x1440x0&"))
        #expect(query.contains("&sops=0&"))
        #expect(Self.request(width: 1920, height: 1080, frameRate: 60).query(nvidiaServer: true).contains("&mode=1920x1080x60&"))
        #expect(Self.request(width: 1920, height: 1080).query(nvidiaServer: true).contains("&sops=1&"))
    }
}

/// HTTP/1.1 responses as the transport reads them.
@Suite struct HTTPResponseParserTests {
    func parse(_ chunks: [String], atEnd: Bool = true, limit: Int = 1024) throws -> HTTPResponse? {
        var parser = HTTPResponseParser(maximumBodySize: limit)
        var response: HTTPResponse?
        for (index, chunk) in chunks.enumerated() {
            try parser.append(Data(chunk.utf8))
            response = try parser.response(atEnd: atEnd && index == chunks.count - 1)
        }
        return response
    }

    @Test func contentLengthEvenWhenSplitAcrossReads() throws {
        let response = try parse(["HTTP/1.1 200 OK\r\nContent-Le", "ngth: 5\r\n\r\nhel", "lo"], atEnd: false)

        #expect(response?.status == 200)
        #expect(response?.body == Data("hello".utf8))
    }

    @Test func aBodyShorterThanItsLengthIsNotComplete() throws {
        #expect(try parse(["HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel"], atEnd: false) == nil)
    }

    @Test func chunkedTransferCoding() throws {
        let response = try parse(["HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n", "2;x=y\r\nde\r\n0\r\n\r\n"], atEnd: false)

        #expect(response?.body == Data("abcde".utf8))
    }

    @Test func withoutALengthTheBodyEndsWithTheConnection() throws {
        #expect(try parse(["HTTP/1.0 404 Not Found\r\n\r\npartial"], atEnd: false) == nil)
        #expect(try parse(["HTTP/1.0 404 Not Found\r\n\r\nwhole"])?.body == Data("whole".utf8))
    }

    @Test func notHTTPIsMalformed() {
        #expect(throws: HostError.malformedResponse("not an HTTP response")) { try parse(["SSH-2.0-OpenSSH\r\n\r\n"]) }
    }

    @Test func aDeclaredLengthOverTheLimitIsRefused() {
        #expect(throws: HostError.responseTooLarge) { try parse(["HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n"], atEnd: false) }
    }
}
