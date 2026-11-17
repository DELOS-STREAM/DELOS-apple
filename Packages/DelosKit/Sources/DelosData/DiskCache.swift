import CryptoKit
import Foundation

/// Files kept on disk under a size limit: the artwork the library shows (SteamGridDB images and the PCs' box art). Each
/// entry is one file named by the SHA-256 of its key, so any key is a safe file name. Reading an entry marks it used;
/// storing one drops the least recently used files until the folder fits [budget] bytes again. Everything here can be
/// fetched again, so the system may also purge the folder (it lives under Caches).
public actor DiskCache {
    public let directory: URL
    /// The most bytes the folder may hold after a store.
    public let budget: Int64
    /// The largest single entry; a larger one is refused (``DiskCacheError/tooLarge``).
    public let maxEntryBytes: Int64
    private let now: @Sendable () -> Date
    private let files = FileManager.default

    /// - Parameter now: the clock that marks use (tests set their own, so the order does not depend on the file
    ///   system's timestamp resolution).
    public init(directory: URL, budget: Int64, maxEntryBytes: Int64, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.budget = budget
        self.maxEntryBytes = maxEntryBytes
        self.now = now
    }

    /// The app's artwork cache: 256 MB under Caches/artwork, at most 32 MB per image.
    public static func artwork() -> DiskCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCache(directory: caches.appending(path: "artwork", directoryHint: .isDirectory),
                         budget: 256 * 1024 * 1024, maxEntryBytes: 32 * 1024 * 1024)
    }

    /// The entry of [key], marked as used; nil when there is none.
    public func data(for key: String) -> Data? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? files.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    /// The entry of [key] mapped from its file rather than read (an animation is played from it for as long as it shows),
    /// marked as used; nil when there is none. The mapping stays valid when the entry is replaced or dropped meanwhile.
    public func mappedData(for key: String) -> Data? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), !data.isEmpty else { return nil }
        try? files.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        return data
    }

    public func contains(_ key: String) -> Bool { files.fileExists(atPath: file(key).path) }

    /// Stores [data] as [key] (replacing what was there) and trims the folder to the budget.
    public func store(_ data: Data, for key: String) throws {
        guard Int64(data.count) <= maxEntryBytes else { throw DiskCacheError.tooLarge }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = file(key)
        try data.write(to: url, options: .atomic)
        try? files.setAttributes([.modificationDate: now()], ofItemAtPath: url.path)
        trim(keeping: url)
    }

    public func remove(_ key: String) {
        try? files.removeItem(at: file(key))
    }

    /// The bytes the folder holds now.
    public func totalBytes() -> Int64 { entries().reduce(0) { $0 + $1.size } }

    /// Drops the least recently used files until the folder fits the budget; [keeping] (the file just stored) goes last.
    private func trim(keeping: URL) {
        let all = entries()
        var total = all.reduce(0) { $0 + $1.size }
        guard total > budget else { return }
        for entry in all.sorted(by: { ($0.url == keeping ? 1 : 0, $0.used) < ($1.url == keeping ? 1 : 0, $1.used) }) {
            guard total > budget else { break }
            if (try? files.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    private func entries() -> [(url: URL, size: Int64, used: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }

    private func file(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name, directoryHint: .notDirectory)
    }
}

public enum DiskCacheError: Error, Equatable {
    /// The entry is larger than ``DiskCache/maxEntryBytes``.
    case tooLarge
}
