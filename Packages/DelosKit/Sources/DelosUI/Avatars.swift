import Foundation
import ImageIO
import os
import Synchronization
import SwiftUI

/// An avatar to choose from (`Avatar` in DELOS for Android's `shell/data/Profiles.kt`): its language-independent
/// [name] (never shown), the shown [label], the [hue] of its fallback gradient, the illustration [asset] (a WebP file in
/// `Resources/Avatars`, drawn over its colors) and the font [icon] shown until the image is decoded or when it is missing.
/// A profile stores the avatar's index in ``all``, so the order never changes: new avatars are only appended.
struct Avatar: Identifiable, Sendable {
    let index: Int
    let icon: String
    let name: String
    let hue: Double
    let asset: String
    let label: String

    var id: Int { index }

    /// The sixteen avatars of DELOS for Android, in its order (docs/gui/START_AND_HOME.md, "The avatar set").
    static let all: [Avatar] = ([
        (Symbols.sailing, "Sailor", 205, "sailor", L("firstrun_avatar_sailor")),
        (Symbols.rocketLaunch, "Voyager", 262, "voyager", L("firstrun_avatar_voyager")),
        (Symbols.sportsEsports, "Player", 330, "player", L("firstrun_avatar_player")),
        (Symbols.pets, "Fox", 24, "fox", L("firstrun_avatar_fox")),
        (Symbols.spark, "Spark", 48, "spark", L("firstrun_avatar_spark")),
        (Symbols.spa, "Calm", 150, "calm", L("firstrun_avatar_calm")),
        (Symbols.swords, "Knight", 232, "knight", L("firstrun_avatar_knight")),
        (Symbols.robot, "Robot", 182, "robot", L("firstrun_avatar_robot")),
        (Symbols.cat, "Cat", 84, "cat", L("firstrun_avatar_cat")),
        (Symbols.magicWand, "Wizard", 292, "wizard", L("firstrun_avatar_wizard")),
        (Symbols.speed, "Racer", 356, "racer", L("firstrun_avatar_racer")),
        (Symbols.ghost, "Ghost", 118, "ghost", L("firstrun_avatar_ghost")),
        (Symbols.pets, "Owl", 150, "owl", L("firstrun_avatar_owl")),
        (Symbols.terminal, "Hacker", 320, "hacker", L("firstrun_avatar_hacker")),
        (Symbols.pets, "Wolf", 200, "wolf", L("firstrun_avatar_wolf")),
        (Symbols.pets, "Dragon", 110, "dragon", L("firstrun_avatar_dragon")),
    ] as [(String, String, Double, String, String)])
        .enumerated().map { i, a in Avatar(index: i, icon: a.0, name: a.1, hue: a.2, asset: a.3, label: a.4) }

    /// The avatar of a stored index; an index this version does not know is clamped.
    static func of(_ index: Int) -> Avatar { all[min(max(index, 0), all.count - 1)] }

    /// The colors behind the illustration: the dark muted pair made for an imported avatar (`avatars.json`), else the
    /// gradient of its hue, `hsl(h 80% 62%)` to `hsl(h+30 70% 38%)`.
    var gradient: AvatarGradient {
        AvatarGradient.imported[asset] ?? AvatarGradient(c0: hsl(hue, 80, 62), c1: hsl(hue + 30, 70, 38))
    }
}

/// The badge colors of an avatar: [c0] in the radial gradient's center, [c1] at its edge.
struct AvatarGradient: Equatable, Sendable {
    let c0: RGBA
    let c1: RGBA

    /// `Resources/Avatars/avatars.json` (written by DELOS for Android's `tools/avatars/import.py`), keyed by the asset
    /// name: `{"fox": {"c0": "#rrggbb", "c1": "#rrggbb"}}`. Read once; a missing or broken file means no avatar has
    /// colors of its own.
    static let imported: [String: AvatarGradient] = {
        guard let url = Bundle.module.url(forResource: "avatars", withExtension: "json") else {
            Logger.avatars.warning("No avatars.json in the bundle")
            return [:]
        }
        do {
            return try parse(Data(contentsOf: url))
        } catch {
            Logger.avatars.warning("No avatar colors: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }()

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    /// The gradients keyed by asset name; throws ``Invalid`` on anything that is not a valid file.
    static func parse(_ data: Data) throws -> [String: AvatarGradient] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Invalid(description: "avatars.json is not a JSON object")
        }
        return try root.mapValues { value in
            guard let entry = value as? [String: Any] else { throw Invalid(description: "an entry is not an object") }
            return AvatarGradient(c0: try color(entry["c0"]), c1: try color(entry["c1"]))
        }
    }

    private static func color(_ value: Any?) throws -> RGBA {
        guard let text = value as? String, text.count == 7, text.first == "#",
              text.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let rgb = UInt32(text.dropFirst(), radix: 16) else {
            throw Invalid(description: "\(String(describing: value)) is not #rrggbb")
        }
        return RGBA(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// The avatar illustrations (384 × 384 WebP, decoded by ImageIO), decoded off the main thread at their full size and kept
/// in memory: all sixteen are 9 MiB, so a picker or a badge never decodes one twice. An asset that is missing or cannot be
/// decoded is looked for once and logged once; its badge keeps the font icon.
enum AvatarImages {
    private static let memory = Mutex<[String: CGImage]>([:])
    private static let missing = Mutex<Set<String>>([])

    static func cached(_ asset: String) -> CGImage? {
        memory.withLock { $0[asset] }
    }

    static func load(_ asset: String) async -> CGImage? {
        if let image = cached(asset) { return image }
        if missing.withLock({ $0.contains(asset) }) { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let image = decode(asset) else {
                if missing.withLock({ $0.insert(asset).inserted }) {
                    Logger.avatars.warning("No avatar image \(asset, privacy: .public)")
                }
                return nil
            }
            memory.withLock { $0[asset] = image }
            return image
        }.value
    }

    /// Decodes an asset from the bundle; nil when it is missing or invalid.
    static func decode(_ asset: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: asset, withExtension: "webp"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

extension Logger {
    static let avatars = Logger(subsystem: "io.github.meitoncz.delos", category: "avatars")
}

/// The avatar's colors behind its illustration in a circle of [size] stage pixels (`AvatarBadge` in DELOS for Android);
/// [iconSize] is the font icon that stands in while the image loads.
struct AvatarBadge: View {
    let avatar: Avatar
    let size: Double
    let iconSize: Double
    @Environment(\.stage) private var stage

    var body: some View {
        ZStack {
            AvatarBackground(avatar: avatar)
            // A badge that changes its avatar starts the new one's art from scratch
            AvatarArt(avatar: avatar, iconSize: iconSize).id(avatar.index)
        }
        .frame(width: stage.px(size), height: stage.px(size))
        .clipShape(Circle())
    }
}

/// `radial-gradient(circle at 35% 30%, c0, c1)`: a circle around that point out to the farthest corner.
struct AvatarBackground: View {
    let avatar: Avatar

    var body: some View {
        let colors = avatar.gradient
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            RadialGradient(
                colors: [colors.c0.color, colors.c1.color],
                center: UnitPoint(x: 0.35, y: 0.3),
                startRadius: 0,
                endRadius: max(hypot(0.65 * w, 0.7 * h), 1)
            )
        }
    }
}

/// The avatar's illustration filling its circle. The white font icon stands in until the image is decoded and fades out
/// as the image fades in (180 ms); it stays when the asset is missing. An image decoded before is there in the first frame.
struct AvatarArt: View {
    let avatar: Avatar
    let iconSize: Double
    @State private var image: CGImage?
    @State private var shown: Bool

    init(avatar: Avatar, iconSize: Double) {
        self.avatar = avatar
        self.iconSize = iconSize
        let cached = AvatarImages.cached(avatar.asset)
        _image = State(initialValue: cached)
        _shown = State(initialValue: cached != nil)
    }

    var body: some View {
        ZStack {
            if !shown {
                // White, as on Android: the icon sits on the avatar's own colors, not on a theme color
                SymbolView(symbol: avatar.icon, size: iconSize, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
                    .transition(.opacity)
            }
            if let image, shown {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            }
        }
        .task(id: avatar.asset) {
            guard image == nil, let loaded = await AvatarImages.load(avatar.asset) else { return }
            image = loaded
            withAnimation(.linear(duration: 0.18)) { shown = true }
        }
    }
}
