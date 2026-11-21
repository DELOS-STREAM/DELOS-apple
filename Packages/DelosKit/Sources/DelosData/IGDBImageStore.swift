import Foundation

/// The overview's images from IGDB's image server (screenshots, similar games' covers, video thumbnails), kept in a disk
/// LRU of their own (150 MB under Caches/igdb-images) keyed by the image's URL, which names its id and size. Concurrent
/// requests for one image share one download. Nothing here decodes: the caller decodes only what is on screen.
public actor IGDBImageStore {
    private let cache: DiskCache
    private let http: MetadataHTTP
    private let stills: TrailerStills
    private var pending: [URL: Task<Data?, Never>] = [:]

    public static let budget: Int64 = 150 * 1024 * 1024
    public static let maxImageBytes: Int64 = 8 * 1024 * 1024

    public init(cache: DiskCache? = nil, http: MetadataHTTP = MetadataHTTP()) {
        self.cache = cache ?? DiskCache(directory: Self.defaultDirectory(), budget: Self.budget, maxEntryBytes: Self.maxImageBytes)
        self.http = http
        self.stills = TrailerStills(http: http)
    }

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("igdb-images", isDirectory: true)
    }

    /// The bytes of [url]: from the disk cache, else downloaded (a Steam trailer's still, ``HLSStill/url(movie:stream:)``:
    /// made from its stream) and stored. Nil when it cannot be had (offline, not found).
    public func data(_ url: URL) async -> Data? {
        // A still is kept by its movie: the stream's URL carries an access token that changes
        let key = HLSStill.parse(url).map { "delos-still://\($0.movie)" } ?? url.absoluteString
        if let cached = await cache.data(for: key) { return cached }
        if let running = pending[url] { return await running.value }
        let task = Task<Data?, Never> { [http, cache, stills] in
            let data: Data?
            if let still = HLSStill.parse(url) {
                data = await stills.make(stream: still.stream)
            } else {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                data = try? await http.send(request)
            }
            guard let data, !data.isEmpty else { return nil }
            try? await cache.store(data, for: key)
            return data
        }
        pending[url] = task
        defer { pending[url] = nil }
        return await task.value
    }

    /// Whether [url] is on disk already (no download).
    public func isCached(_ url: URL) async -> Bool { await cache.contains(url.absoluteString) }
}
