import DelosData
import DelosHost
import Foundation
import ImageIO

/// The offline artwork of DELOS's own entries on a PC (`BundledArtwork` of DELOS for Android): Desktop, Remote Input,
/// Remote Monitor and Steam Big Picture have fixed cover, wide cover and background images in `Artwork/<slug>/`, copied
/// byte for byte from Android's `assets/artwork/`. Their logo is the rendered name. They are never looked up on
/// SteamGridDB, have no metadata and no choice of artwork.
enum BundledArtwork {
    enum Kind: String, CaseIterable {
        case desktop
        case remoteInput = "remote-input"
        case remoteMonitor = "remote-monitor"
        case steamBigPicture = "steam-big-picture"

        /// The placeholder's icon while the image is not decoded (`appArt`).
        var icon: String {
            switch self {
            case .desktop: Symbols.desktopApp
            case .remoteInput: Symbols.remoteInput
            case .remoteMonitor: Symbols.remoteMonitor
            case .steamBigPicture: Symbols.steam
            }
        }

        /// The folder of the kind's files inside the bundle.
        var folder: String { "Artwork/\(rawValue)" }

        /// The file of an art kind; nil for the logo, which stays the rendered name.
        func file(_ art: ArtKind) -> String? { art == .logo ? nil : art.rawValue }
    }

    /// Remote Input and Remote Monitor are told apart by the UUID the PC gives them, the others by their name.
    static func kind(uuid: String?, title: String) -> Kind? {
        switch uuid?.lowercased() {
        case "9a1c5a25-58fe-40e0-b9aa-7d3f00000006": return .remoteInput
        case "9a1c5a25-58fe-40e0-b9aa-7d3f00000005": return .remoteMonitor
        default: break
        }
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "desktop": return .desktop
        case "remote input": return .remoteInput
        case "remote monitor": return .remoteMonitor
        case "steam big picture", "steam bigpicture": return .steamBigPicture
        default: return nil
        }
    }

    static func kind(_ app: HostApp) -> Kind? { kind(uuid: app.uuid, title: app.title) }

    /// The file's location in the bundle; nil for the logo or a file that is missing.
    static func url(_ kind: Kind, _ art: ArtKind) -> URL? {
        kind.file(art).flatMap { Bundle.module.url(forResource: $0, withExtension: "jpg", subdirectory: kind.folder) }
    }

    /// The bundled image of [art], decoded no larger than [maxPixels] on its longer side, off the main thread.
    static func image(_ kind: Kind, _ art: ArtKind, maxPixels: Int) async -> CGImage? {
        guard let url = url(kind, art) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }.value
    }
}
