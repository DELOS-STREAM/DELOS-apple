import DelosData
import DelosInput
import ImageIO
import SwiftUI

// MARK: Focus ring

/// The overview's one focus ring (the prototype's `.ring`): a gold rounded outline with a glow that glides between the
/// focused elements (560 ms, `--ease-glide`), drawn over the page so it scrolls with it. Elements mark themselves with
/// ``View/overviewRingTarget(focused:corner:pad:scale:)``. Hidden for touch, whose focus is not shown.
@MainActor
@Observable
final class OverviewRing {
    static let space = "overview-page"
    struct Target: Equatable {
        var frame: CGRect
        var corner: Double
    }
    private(set) var shown: Target?
    private(set) var alpha = 0.0
    @ObservationIgnored private var holder: AnyHashable?
    @ObservationIgnored var reduced = false

    func focus(_ key: AnyHashable, _ target: Target) {
        holder = key
        guard target.frame != .zero else { return }
        if alpha > 0, shown != nil, !reduced {
            withAnimation(.timingCurve(0.3, 1.22, 0.42, 1, duration: Motion.ring / 1000)) { shown = target }
        } else {
            shown = target
        }
        withAnimation(.easeOut(duration: 0.2)) { alpha = 1 }
    }

    func moved(_ key: AnyHashable, _ target: Target) {
        guard holder == key, target.frame != .zero, target != shown else { return }
        if shown == nil || alpha == 0 { focus(key, target); return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { shown = target }
    }

    func blur(_ key: AnyHashable) {
        guard holder == key else { return }
        holder = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            guard holder == nil else { return }
            withAnimation(.easeOut(duration: 0.2)) { alpha = 0 }
        }
    }

    func hide() {
        holder = nil
        withAnimation(.easeOut(duration: 0.2)) { alpha = 0 }
    }
}

extension EnvironmentValues {
    @Entry var overviewRing: OverviewRing?
}

private struct OverviewRingTarget: ViewModifier {
    let focused: Bool
    let corner: Double
    let pad: Double
    let scale: Double
    @Environment(\.overviewRing) private var ring
    @Environment(\.stage) private var stage
    @State private var key = UUID()
    @State private var frame = CGRect.zero

    private func target(_ frame: CGRect) -> OverviewRing.Target {
        // The element as it shows focused (grown about its middle), the ring [pad] outside it
        let grown = frame.insetBy(dx: -frame.width * (scale - 1) / 2, dy: -frame.height * (scale - 1) / 2)
        let p = stage.px(pad)
        return .init(frame: grown.insetBy(dx: -p, dy: -p), corner: stage.px(corner * scale + pad))
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(OverviewRing.space)) } action: { now in
                frame = now
                if focused { ring?.moved(key, target(now)) }
            }
            .onChange(of: focused, initial: true) { _, now in
                if now { ring?.focus(key, target(frame)) } else { ring?.blur(key) }
            }
            .onDisappear { ring?.blur(key) }
    }
}

extension View {
    /// Marks an overview element the ring goes to while it is [focused]: [corner] its corner radius, [pad] how far outside
    /// it the ring stands, [scale] its focus scale (stage pixels).
    func overviewRingTarget(focused: Bool, corner: Double, pad: Double = 0, scale: Double = 1) -> some View {
        modifier(OverviewRingTarget(focused: focused, corner: corner, pad: pad, scale: scale))
    }

    /// The host of an ``OverviewRing``: the ring is drawn over the content (`box-shadow: 0 0 0 4px accent, 0 0 34px -4px glow`).
    func overviewRingHost(_ ring: OverviewRing, hidden: Bool) -> some View {
        modifier(OverviewRingHost(ring: ring, hidden: hidden))
    }
}

private struct OverviewRingHost: ViewModifier {
    let ring: OverviewRing
    let hidden: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    func body(content: Content) -> some View {
        ring.reduced = reduced
        return content
            .coordinateSpace(name: OverviewRing.space)
            .environment(\.overviewRing, ring)
            .overlay(alignment: .topLeading) {
                if let shown = ring.shown, ring.alpha > 0, !hidden {
                    let w = stage.px(4)
                    RoundedRectangle(cornerRadius: shown.corner + w, style: .continuous)
                        .strokeBorder(colors.accent.color, lineWidth: w)
                        .shadow(color: colors.glow.color, radius: stage.px(15))
                        .frame(width: shown.frame.width + 2 * w, height: shown.frame.height + 2 * w)
                        .offset(x: shown.frame.minX - w, y: shown.frame.minY - w)
                        .opacity(ring.alpha)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: Count-up and rings

/// A number that counts up when its value changes (animated in the draw phase: only the text is redrawn).
struct CountUpText: View, Animatable {
    var value: Double
    let decimals: Int
    let font: Font
    let color: Color

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(value.formatted(.number.precision(.fractionLength(decimals))))
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// The rating ring (`.rring`): the arc fills to the rating and the number counts up, both over 1.3 s (`--ease-out`), once
/// [active]; without a rating a dash in an empty track.
struct RatingRing: View {
    let value: Double?
    let size: Double
    let color: RGBA
    let active: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        let side = stage.px(size), line = stage.px(8)
        let shown = active ? (value ?? 0) : 0
        let animation: Animation? = reduced ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: OverviewMotion.ratings / 1000)
        ZStack {
            Circle().inset(by: line / 2).stroke(Color.white.opacity(0.1), lineWidth: line)
            if let value {
                Circle().inset(by: line / 2)
                    .trim(from: 0, to: active ? value / 100 : 0)
                    .stroke(color.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(animation, value: active)
                CountUpText(value: shown, decimals: 0, font: DelosFonts.unbounded(stage.tpx(size * 0.3), .bold), color: colors.text.color)
                    .animation(animation, value: active)
            } else {
                Text("—").font(DelosFonts.unbounded(stage.tpx(size * 0.2), .bold)).foregroundStyle(colors.text3.color)
            }
        }
        .frame(width: side, height: side)
    }
}

/// A thin bar that fills from its start to [value] percent (`.rbar`), with the ratings' timing.
struct FillBar: View {
    let value: Int
    let active: Bool
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced

    var body: some View {
        Capsule().fill(Color.white.opacity(0.1))
            .overlay(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [colors.accent.color, colors.accent2.color], startPoint: .leading, endPoint: .trailing))
                    .scaleEffect(x: active ? Double(value) / 100 : 0, anchor: .leading)
                    .animation(reduced ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: OverviewMotion.ratings / 1000), value: active)
            }
            .frame(height: stage.px(10))
            .clipShape(Capsule())
    }
}

// MARK: Tags

/// A tag of the overview (`.tag`): an icon and a name in a faint pill; a genre's takes the game's hue.
struct OverviewTag: View {
    let icon: String?
    let label: String
    var genre = false
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    var body: some View {
        HStack(spacing: stage.px(8)) {
            if let icon { SymbolView(symbol: icon, size: 22, color: genre ? colors.text : colors.accent2) }
            Text(label).font(DelosFonts.figtree(stage.tpx(19))).foregroundStyle((genre ? colors.text : colors.text2).color).lineLimit(1)
        }
        .padding(.horizontal, stage.px(16))
        .frame(height: stage.px(40))
        .background {
            Capsule().fill(genre ? colors.accent2.opacity(0.18).color : Color.white.opacity(0.06))
                .overlay(Capsule().strokeBorder((genre ? colors.accent2.opacity(0.45) : colors.line).color, lineWidth: stage.px(1)))
        }
        .fixedSize()
    }
}

/// An age rating badge with its organization and descriptors (`.age`): PEGI in its colors, ESRB white.
struct AgeBadge: View {
    let rating: GameDetails.AgeRating?
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage

    private var badgeColor: Color {
        guard let rating else { return Color.white.opacity(0.08) }
        if rating.organization != "PEGI" { return .white }
        switch rating.rating {
        case "3", "7": return Color(.sRGB, red: 0x74 / 255, green: 0xB7 / 255, blue: 0x2E / 255)
        case "12", "16": return Color(.sRGB, red: 0xF3 / 255, green: 0x92 / 255, blue: 0)
        default: return Color(.sRGB, red: 0xE0 / 255, green: 0x32 / 255, blue: 0x2B / 255)
        }
    }

    var body: some View {
        HStack(spacing: stage.px(12)) {
            Text(rating?.rating ?? "—")
                .font(rating == nil ? DelosFonts.figtree(stage.tpx(18)) : DelosFonts.unbounded(stage.tpx(22), .bold))
                .foregroundStyle(rating == nil ? colors.text3.color : rating?.organization == "PEGI" ? .white : Color(white: 0.07))
                .padding(.horizontal, stage.px(8))
                .frame(minWidth: stage.px(54), minHeight: stage.px(54))
                .background(RoundedRectangle(cornerRadius: stage.px(rating?.organization == "PEGI" || rating == nil ? 12 : 6)).fill(badgeColor))
            VStack(alignment: .leading, spacing: 0) {
                Text(rating.map { "\($0.organization) \($0.rating)" } ?? L("overview_not_rated"))
                    .font(DelosFonts.figtree(stage.tpx(22))).foregroundStyle(colors.text.color)
                Text(rating.map { $0.descriptors.isEmpty ? L("overview_no_descriptors") : $0.descriptors.joined(separator: ", ") } ?? L("overview_no_age_rating"))
                    .font(DelosFonts.figtree(stage.tpx(16))).foregroundStyle(colors.text3.color)
            }
        }
        .fixedSize()
    }
}

/// Lays its children out in rows that wrap (`flex-wrap`).
struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: Remote images

/// Decoded IGDB images in memory, by URL and size: the overview decodes only what it shows, downsampled to its size.
@MainActor
enum OverviewImageMemory {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }
    static func store(_ image: CGImage, _ key: String) {
        cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
    }

    /// [data] decoded no larger than [maxPixels] on its long side.
    nonisolated static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// An image of IGDB's server (or a video's thumbnail) filling its frame: downloaded through the disk cache, decoded for
/// the size shown, faded in; the faint surface until then. [placeholder]: a smaller image of the same picture shown
/// meanwhile (the viewer keeps the thumbnail until the large one is decoded).
struct RemoteImage: View {
    let url: URL?
    let maxPixels: Int
    var placeholder: URL?
    var placeholderPixels = 640
    @Environment(GameMetadataModel.self) private var metadata
    @Environment(\.delosColors) private var colors
    @State private var image: CGImage?
    @State private var fallback: CGImage?

    private func key(_ url: URL, _ pixels: Int) -> String { "\(url.absoluteString)#\(pixels)" }

    var body: some View {
        ZStack {
            Rectangle().fill(colors.surface2.color)
            if let shown = image ?? fallback {
                Image(decorative: shown, scale: 1).resizable().scaledToFill().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: image.map(ObjectIdentifier.init))
        .task(id: url) {
            if let placeholder, image == nil { fallback = await load(placeholder, placeholderPixels) }
            if let url { image = await load(url, maxPixels) }
        }
    }

    private func load(_ url: URL, _ pixels: Int) async -> CGImage? {
        let key = key(url, pixels)
        if let cached = OverviewImageMemory.image(key) { return cached }
        guard let data = await metadata.images.data(url), !Task.isCancelled else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { OverviewImageMemory.decode(data, maxPixels: pixels) }.value
        if let decoded { OverviewImageMemory.store(decoded, key) }
        return decoded
    }
}

/// What the overview loads a screenshot's thumbnail and its full view at: `screenshot_med` thumbs on a 1080p stage, the
/// `screenshot_big` ones on the 4:3 one (an iPad's density), `screenshot_huge` or `1080p` in the viewer.
enum OverviewImageSizes {
    static func thumb(_ media: OverviewContent.Media, tall: Bool) -> URL? {
        switch media.kind {
        case .video: IGDBImage.videoThumbnail(media.id)
        case .screenshot: IGDBImage.url(media.id, size: tall ? .screenshotBig : .screenshotMed)
        }
    }

    static func full(_ media: OverviewContent.Media, tall: Bool) -> URL? {
        switch media.kind {
        case .video: IGDBImage.videoThumbnail(media.id)
        case .screenshot: IGDBImage.url(media.id, size: tall ? .full : .screenshotHuge)
        }
    }
}

// MARK: The Game info hint

/// The "Game info" hint (the prototype's `.gi`): a small dark glass chip centred over the focused cover's lower edge, as
/// its badges are, drawn for the input in use: the D-pad's down arm on a controller (outline cut, the pressed arm filled),
/// the ↓ key cap on a keyboard, a small arrow up for touch (swipe the cover up) and a clickable arrow down for the
/// pointer; the glyph bobs gently (not with reduced motion). A tap or a click on it opens the overview.
struct GameInfoHint: View {
    let kind: InputKind
    let onOpen: () -> Void
    var active = true
    @Environment(\.delosColors) private var colors
    @Environment(\.stage) private var stage
    @Environment(\.reducedMotion) private var reduced
    @Environment(\.scenePhase) private var scenePhase
    @State private var hovered = false

    static func dpadDown(_ family: PadFamily) -> String {
        switch family {
        case .dualSense: Symbols.padDualsenseDpadDown
        case .dualShock: Symbols.padDualshock4DpadDown
        case .nintendo: Symbols.padJoyconDpadDown
        case .generic, .xbox: Symbols.padXboxDpadDown
        }
    }

    var body: some View {
        let tappable = kind == .touch || kind == .pointer
        HStack(spacing: stage.px(10)) {
            glyph
            Text(L(kind == .touch ? "overview_swipe_up_game_info" : "overview_game_info"))
                .font(DelosFonts.figtree(stage.tpx(20), .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.leading, stage.px(14))
        .padding(.trailing, stage.px(18))
        .frame(height: stage.px(48))
        .background {
            Capsule().fill(Color(.sRGB, red: 5 / 255, green: 10 / 255, blue: 20 / 255, opacity: hovered ? 0.78 : 0.6))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: stage.px(1)))
        }
        .contentShape(Capsule())
        .pointerHover { hovered = $0 && kind == .pointer }
        .onTapGesture { if tappable { onOpen() } }
        .allowsHitTesting(tappable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onOpen() }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .controller:
            Text(Self.dpadDown(ControllerGlyphs.shared.family))
                .font(DelosFonts.symbol(stage.px(GlyphLook.controllerEm(for: 32)), filled: false))
                .foregroundStyle(.white)
                .modifier(Bob(up: false, paused: bobPaused))
        case .keyboard:
            Text(Symbols.macArrowDown)
                .font(DelosFonts.symbol(stage.px(GlyphLook.controllerEm(for: 32)), filled: true))
                .foregroundStyle(.white)
                .modifier(Bob(up: false, paused: bobPaused))
        case .touch:
            // A finger with two stacked chevrons rising above it (swipe the cover up)
            HStack(spacing: stage.px(2)) {
                SymbolView(symbol: Symbols.touchApp, size: 26, color: RGBA(red: 1, green: 1, blue: 1), filled: true)
                VStack(spacing: -stage.px(15)) {
                    SymbolView(symbol: Symbols.expandLess, size: 22, color: colors.accent, filled: true)
                    SymbolView(symbol: Symbols.expandLess, size: 22, color: colors.accent, filled: true).opacity(0.6)
                }
                .modifier(Bob(up: true, paused: bobPaused))
            }
        case .pointer:
            SymbolView(symbol: Symbols.expandMore, size: 26, color: colors.accent, filled: true)
                .modifier(Bob(up: false, paused: bobPaused))
        }
    }

    /// No clock while hidden, in the background or with reduced motion.
    private var bobPaused: Bool { reduced || !active || scenePhase != .active }
}

/// The hint's bob: 5 px down and back over 2.2 s; touch's chevrons rise 10 px and fade in and out over 2.2 s, looping.
private struct Bob: ViewModifier {
    let up: Bool
    let paused: Bool
    @Environment(\.stage) private var stage

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: paused)) { timeline in
            let period = up ? 1.8 : 2.2
            let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            let wave = paused ? 0 : (up ? t : (1 - cos(t * 2 * .pi)) / 2)
            // Touch: from 5 px below to 7 px above, 25 % to full and back, every 1.8 s
            content.offset(y: stage.px(up ? (paused ? 0 : 5 - 12 * wave) : 5 * wave))
                .opacity(up && !paused ? 0.25 + 0.75 * sin(t * .pi) : 1)
        }
    }
}

extension View {
    /// The pointer entering and leaving the view (the hover look); nothing on tvOS, which has no pointer.
    @ViewBuilder func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: action)
        #endif
    }
}
