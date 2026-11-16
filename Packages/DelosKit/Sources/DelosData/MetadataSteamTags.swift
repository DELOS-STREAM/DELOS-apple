import Foundation

public struct SteamTagsClient: Sendable {
    // Android's Steam endpoint has a narrower bound than PCGW's uint32 bound.
    public static let maxAppID: Int64 = 2_000_000_000
    public static let maxTags = 20

    private let baseURL: String
    private let http: MetadataHTTP
    private let pacer: RequestPacer

    public init(baseURL: String, http: MetadataHTTP = MetadataHTTP()) {
        self.baseURL = baseURL
        self.http = http
        pacer = RequestPacer(intervalMilliseconds: 650)
    }

    public func tags(_ appID: Int64) async throws -> [String] {
        guard (1...Self.maxAppID).contains(appID) else {
            throw MetadataError.invalidRequest
        }
        guard let url = MetadataProxy.url(
            baseURL: baseURL,
            path: "v1/steam/tags",
            parameters: [URLQueryItem(name: "app", value: String(appID))]
        ) else {
            throw MetadataError.unavailable
        }
        try await pacer.wait()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try Self.parseTags(await http.send(request), appID: appID)
    }

    public static func parseTags(_ data: Data, appID: Int64) throws -> [String] {
        guard (1...maxAppID).contains(appID) else {
            throw MetadataError.invalidRequest
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw MetadataError.malformedResponse
        }
        guard payload.app == appID else { throw MetadataError.malformedResponse }

        // Decode the entire array first: invalid trailing elements must not be
        // hidden by the result limit.
        var seen: Set<String> = []
        var result: [String] = []
        for raw in payload.tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tag.isEmpty, seen.insert(tag).inserted, result.count < maxTags {
                result.append(tag)
            }
        }
        return result
    }

    private struct Payload: Decodable {
        let app: Int64
        let tags: [String]
    }
}
