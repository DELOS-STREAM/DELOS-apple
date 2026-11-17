import Foundation

/// The certificate pinned for a paired host and the port its HTTPS server listens on.
public struct HostPin: Hashable, Sendable, Codable {
    /// DER. HTTPS to the host accepts this certificate and nothing else.
    public let certificate: Data
    public let httpsPort: Int

    public init(certificate: Data, httpsPort: Int) {
        self.certificate = certificate
        self.httpsPort = httpsPort
    }
}

/// How a `serverinfo` answer reached the client.
public enum ReplySource: Equatable, Sendable {
    /// HTTPS to the pinned certificate: the paired host itself answered.
    case pinnedHTTPS
    /// Plain HTTP: anyone on the network can have sent it.
    case plainHTTP
}

/// A `serverinfo` answer, where it came from and over which channel.
public struct ServerInfoReply: Equatable, Sendable {
    public let info: ServerInfo
    /// The HTTP address the client asked (the HTTPS port is in `info`).
    public let address: HostAddress
    public let source: ReplySource

    public init(info: ServerInfo, address: HostAddress, source: ReplySource) {
        self.info = info
        self.address = address
        self.source = source
    }
}

/// The settings of a launch or resume request (`/launch`, `/resume`).
public struct LaunchRequest: Equatable, Sendable {
    public var appID: Int
    public var appUUID: String?
    public var width: Int
    public var height: Int
    /// Frames per second; a fractional rate is sent in thousandths (59.94 → 59940).
    public var frameRate: Double
    public var resolutionScaleFactor: Int
    /// Let the host optimize game settings (SOPS).
    public var optimizeGameSettings: Bool
    /// The 16-byte AES key of the remote input stream and its id.
    public var remoteInputKey: Data
    public var remoteInputKeyID: Int32
    public var hdr: Bool
    public var virtualDisplay: Bool
    public var playAudioOnHost: Bool
    /// `SURROUNDAUDIOINFO_FROM_AUDIO_CONFIGURATION` of the core.
    public var surroundAudioInfo: Int
    public var gamepadMask: Int
    public var persistGamepadsAfterDisconnect: Bool
    /// What `LiGetLaunchUrlQueryParameters()` of the streaming core returns (`&corever=1`), appended verbatim.
    public var coreParameters: String

    public init(
        appID: Int, appUUID: String?, width: Int, height: Int, frameRate: Double, resolutionScaleFactor: Int,
        optimizeGameSettings: Bool, remoteInputKey: Data, remoteInputKeyID: Int32, hdr: Bool, virtualDisplay: Bool,
        playAudioOnHost: Bool, surroundAudioInfo: Int, gamepadMask: Int, persistGamepadsAfterDisconnect: Bool,
        coreParameters: String
    ) {
        self.appID = appID
        self.appUUID = appUUID
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.resolutionScaleFactor = resolutionScaleFactor
        self.optimizeGameSettings = optimizeGameSettings
        self.remoteInputKey = remoteInputKey
        self.remoteInputKeyID = remoteInputKeyID
        self.hdr = hdr
        self.virtualDisplay = virtualDisplay
        self.playAudioOnHost = playAudioOnHost
        self.surroundAudioInfo = surroundAudioInfo
        self.gamepadMask = gamepadMask
        self.persistGamepadsAfterDisconnect = persistGamepadsAfterDisconnect
        self.coreParameters = coreParameters
    }

    /// The query of the request, in the order DELOS for Android sends it (`NvHTTP.launchApp`). `nvidiaServer` applies
    /// GeForce Experience's quirks: above 60 fps it is sent 0, and SOPS is off at resolutions it does not know.
    func query(nvidiaServer: Bool) -> String {
        let fps = nvidiaServer && frameRate > 60 ? 0 : frameRate
        let fpsValue = fps == fps.rounded() ? Int(fps) : Int(fps * 1000)
        var sops = optimizeGameSettings
        let pixels = width * height
        if nvidiaServer && pixels > 1280 * 720 && pixels != 1920 * 1080 && pixels != 3840 * 2160 {
            sops = false
        }
        var query = "appid=\(appID)"
        if let appUUID { query += "&appuuid=\(HTTPRequest.escape(appUUID))" }
        query += "&mode=\(width)x\(height)x\(fpsValue)"
        query += "&scaleFactor=\(resolutionScaleFactor)"
        query += "&additionalStates=1&sops=\(sops ? 1 : 0)"
        query += "&rikey=\(Hex.encode(remoteInputKey))"
        query += "&rikeyid=\(remoteInputKeyID)"
        if hdr {
            query += "&hdrMode=1&clientHdrCapVersion=0&clientHdrCapSupportedFlagsInUint32=0"
                + "&clientHdrCapMetaDataId=NV_STATIC_METADATA_TYPE_1&clientHdrCapDisplayData=0x0x0x0x0x0x0x0x0x0x0"
        }
        query += "&virtualDisplay=\(virtualDisplay ? 1 : 0)"
        query += "&localAudioPlayMode=\(playAudioOnHost ? 1 : 0)"
        query += "&surroundAudioInfo=\(surroundAudioInfo)"
        query += "&remoteControllersBitmap=\(gamepadMask)&gcmap=\(gamepadMask)"
        query += "&gcpersist=\(persistGamepadsAfterDisconnect ? 1 : 0)"
        return query + coreParameters
    }
}

/// The requests of the GameStream HTTP protocol to one host. Every request carries `uniqueid` (the client id),
/// `devicename` and a fresh `uuid`. Requests that need a paired host go over HTTPS with the pin.
public struct HostClient: Sendable {
    public let address: HostAddress
    public let identity: ClientIdentity
    public let deviceName: String

    /// Time limits: a `serverinfo` poll is short; only the first pairing step, which waits for the user, has none.
    static let pollTimeout: Duration = .seconds(5)
    static let requestTimeout: Duration = .seconds(10)
    /// Quitting an app answers within seconds; a host that stalls must not leave "Quitting" on screen for good.
    static let cancelTimeout: Duration = .seconds(30)
    /// The host answers a launch or a resume when the game runs, which can take a while, but not without end.
    static let launchTimeout: Duration = .seconds(120)

    /// The limits `cancel` and `launch`/`resume` use (tests shorten them).
    var cancelLimit = HostClient.cancelTimeout
    var launchLimit = HostClient.launchTimeout
    static let xmlLimit = 1 << 20
    static let assetLimit = 16 << 20

    public init(address: HostAddress, identity: ClientIdentity, deviceName: String = "DELOS") {
        self.address = address
        self.identity = identity
        self.deviceName = deviceName
    }

    /// `serverinfo`. With a pin, over HTTPS; when the host shows another certificate or no longer knows this client
    /// (401), the answer is fetched over plain HTTP and marked so (S-06): it shows the host is there, nothing more.
    public func serverInfo(pin: HostPin?) async throws -> ServerInfoReply {
        if let pin {
            do {
                let data = try await get("serverinfo", pin: pin, timeout: Self.pollTimeout, limit: Self.xmlLimit)
                return ServerInfoReply(info: try ServerInfo.parse(data), address: address, source: .pinnedHTTPS)
            } catch HostError.certificateMismatch, HostError.httpStatus(401), HostError.hostStatus(code: 401, _) {
                // Fall through to plain HTTP.
            }
        }
        let data = try await get("serverinfo", pin: nil, timeout: Self.pollTimeout, limit: Self.xmlLimit)
        return ServerInfoReply(info: try ServerInfo.parse(data), address: address, source: .plainHTTP)
    }

    public func appList(pin: HostPin) async throws -> [HostApp] {
        try HostApp.parseList(await get("applist", pin: pin, timeout: Self.requestTimeout, limit: Self.xmlLimit))
    }

    /// The box art of an app (PNG or JPEG as the host stores it).
    public func appAsset(appID: Int, pin: HostPin) async throws -> Data {
        let data = try await get(
            "appasset", ["appid": "\(appID)", "AssetType": "2", "AssetIdx": "0"], pin: pin,
            timeout: Self.requestTimeout, limit: Self.assetLimit)
        guard !data.isEmpty else { throw HostError.malformedResponse("empty asset") }
        return data
    }

    /// Starts an app. The host answers when the app runs; ``launchTimeout`` is the limit. Returns the RTSP session URL when
    /// the host names one (`sessionUrl0`).
    public func launch(_ request: LaunchRequest, nvidiaServer: Bool, pin: HostPin) async throws -> String? {
        try await launchOrResume("launch", resultField: "gamesession", request, nvidiaServer: nvidiaServer, pin: pin)
    }

    /// Resumes the app that runs.
    public func resume(_ request: LaunchRequest, nvidiaServer: Bool, pin: HostPin) async throws -> String? {
        try await launchOrResume("resume", resultField: "resume", request, nvidiaServer: nvidiaServer, pin: pin)
    }

    /// Quits the app that runs. Throws `refused` when the host says it did not quit it.
    public func cancel(pin: HostPin) async throws {
        let root = try HostXML.root(await get("cancel", pin: pin, timeout: cancelLimit, limit: Self.xmlLimit))
        guard let value = root.child("cancel") else { throw HostError.malformedResponse("no cancel") }
        if value == "0" { throw HostError.refused }
    }

    /// Asks the host to forget this client (plain HTTP, as every client does).
    public func unpair() async throws {
        _ = try await get("unpair", pin: nil, timeout: Self.requestTimeout, limit: Self.xmlLimit)
    }

    private func launchOrResume(
        _ verb: String, resultField: String, _ request: LaunchRequest, nvidiaServer: Bool, pin: HostPin
    ) async throws -> String? {
        let query = request.query(nvidiaServer: nvidiaServer)
        let root = try HostXML.root(await perform(verb, query: query, pin: pin, timeout: launchLimit, limit: Self.xmlLimit))
        guard let value = root.child(resultField) else { throw HostError.malformedResponse("no \(resultField)") }
        if value == "0" { throw HostError.refused }
        return root.child("sessionUrl0")
    }

    func get(
        _ path: String, _ arguments: KeyValuePairs<String, String> = [:], pin: HostPin?, timeout: Duration?, limit: Int
    ) async throws -> Data {
        let query = HTTPRequest.encode(arguments.map { ($0.key, $0.value) })
        return try await perform(path, query: query, pin: pin, timeout: timeout, limit: limit)
    }

    /// `query` is already encoded; the client id, the device name and a fresh request id are appended.
    func perform(_ path: String, query: String, pin: HostPin?, timeout: Duration?, limit: Int) async throws -> Data {
        let response = try await send(path, query: query, pin: pin, timeout: timeout, limit: limit)
        guard response.status == 200 else { throw HostError.httpStatus(response.status) }
        return response.body
    }

    /// The request as ``perform(_:query:pin:timeout:limit:)`` makes it, a POST of [text] when there is one; the answer
    /// whatever its status.
    func send(
        _ path: String, query: String, pin: HostPin?, timeout: Duration?, limit: Int, text: Data? = nil
    ) async throws -> HTTPResponse {
        let common = HTTPRequest.encode(
            [("uniqueid", identity.uniqueID), ("devicename", deviceName), ("uuid", UUID().uuidString)])
        let target = pin.map { HostAddress(host: address.host, port: $0.httpsPort) } ?? address
        let request = HTTPRequest(
            address: target, path: "/" + path, query: query.isEmpty ? common : query + "&" + common,
            tls: pin.map { TLSPolicy(pinnedCertificate: $0.certificate, identity: identity) },
            timeout: timeout, maximumBodySize: limit, text: text)
        return try await HTTPTransport.perform(request)
    }
}

// MARK: During a stream (Vibepollo and Apollo)

extension HostClient {
    /// The bitrates Vibepollo accepts for a running stream, in kbps: 1 to 1000 Mbps (NvHTTP.java:944-946).
    public static let runtimeBitrateRange = 1000...1_000_000
    /// The longest clipboard text accepted from the host. DELOS for Android reads any length; this client needs a cap
    /// for every answer (HTTPResponseParser), and 16 MiB of text is far beyond what a clipboard holds.
    static let clipboardLimit = 16 << 20

    /// Changes the bitrate of this client's running stream (`setRuntimeBitrate`, NvHTTP.java:942-962: Vibepollo's paired
    /// HTTPS command, no control-stream extension). Returns the bitrate the host applied, which can be lower than asked.
    ///
    /// Throws as DELOS for Android tells the failures apart (StreamMenu.kt:318-327): `httpStatus(404)` when the host has
    /// no such command (or the stream has ended), `hostStatus` with the host's code and message when it refused (an
    /// HTTP error with its reason phrase, or an XML `status_code`, 403 when it did not allow it), anything else when the
    /// change was not confirmed. [kbps] outside ``runtimeBitrateRange`` throws ``RuntimeBitrateOutOfRange``.
    public func setRuntimeBitrate(_ kbps: Int, pin: HostPin) async throws -> Int {
        guard Self.runtimeBitrateRange.contains(kbps) else { throw RuntimeBitrateOutOfRange(kbps: kbps) }
        let response = try await send(
            "bitrate", query: HTTPRequest.encode([("bitrate", "\(kbps)")]), pin: pin, timeout: Self.requestTimeout,
            limit: Self.xmlLimit)
        try Self.check(response)
        guard let text = try HostXML.root(response.body).child("bitrate") else {
            throw HostError.malformedResponse("no bitrate")
        }
        guard let applied = Int(text), Self.runtimeBitrateRange.contains(applied) else {
            throw HostError.malformedResponse("the host did not confirm a valid bitrate")
        }
        return applied
    }

    /// The host's clipboard as text (`getClipboard`, NvHTTP.java:1003-1007): whatever the host answers, as DELOS for
    /// Android puts it on the clipboard.
    public func clipboard(pin: HostPin) async throws -> String {
        let response = try await send(
            "actions/clipboard", query: "type=text", pin: pin, timeout: Self.requestTimeout, limit: Self.clipboardLimit)
        try Self.check(response)
        return String(decoding: response.body, as: UTF8.self)
    }

    /// Sends [text] to the host's clipboard (`sendClipboard`, NvHTTP.java:1009-1018). False when the host does not
    /// support it: Sunshine answers the unknown command with 200 and a body, a host that takes it answers with none.
    public func sendClipboard(_ text: String, pin: HostPin) async throws -> Bool {
        let response = try await send(
            "actions/clipboard", query: "type=text", pin: pin, timeout: Self.requestTimeout, limit: Self.xmlLimit,
            text: Data(text.utf8))
        try Self.check(response)
        return response.body.isEmpty
    }

    /// OkHttp's `isSuccessful` as NvHTTP reads it (NvHTTP.java:538-550): 2xx passes, 404 is `httpStatus(404)` (Android's
    /// FileNotFoundException), any other status the host's code and reason phrase (HostHttpResponseException).
    private static func check(_ response: HTTPResponse) throws {
        switch response.status {
        case 200..<300: return
        case 404: throw HostError.httpStatus(404)
        default: throw HostError.hostStatus(code: response.status, message: response.reason)
        }
    }
}

/// A bitrate outside ``HostClient/runtimeBitrateRange`` (Android's IllegalArgumentException, NvHTTP.java:945).
public struct RuntimeBitrateOutOfRange: Error, Equatable, Sendable {
    public let kbps: Int
}
