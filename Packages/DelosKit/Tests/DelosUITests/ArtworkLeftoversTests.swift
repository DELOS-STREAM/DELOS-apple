import CoreGraphics
import DelosData
import DelosHost
import DelosInput
import Foundation
import Testing
@testable import DelosUI

@Suite struct ArtworkLeftoversTests {
    private func image(_ id: Int) -> SteamGridDBImage {
        SteamGridDBImage(id: id, url: URL(string: "https://cdn.example/\(id).png")!)
    }

    /// A [side] × [side] image of one color.
    private func filled(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1, side: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }

    @Test func aNearlyAllBlackOpaqueThumbnailIsATakedownPlaceholder() {
        #expect(TakedownPlaceholder.looksRemoved(filled(0, 0, 0)))
        // A dark picture, a transparent logo and nothing at all are not
        #expect(!TakedownPlaceholder.looksRemoved(filled(0.1, 0.1, 0.12)))
        #expect(!TakedownPlaceholder.looksRemoved(filled(0, 0, 0, alpha: 0)))
        #expect(!TakedownPlaceholder.looksRemoved(rgba: []))
        // 90 % of the pixels is enough (the line of text is the rest)
        let black: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [255, 255, 255, 255]
        #expect(TakedownPlaceholder.looksRemoved(rgba: Array(repeating: black, count: 9).flatMap { $0 } + white))
        #expect(!TakedownPlaceholder.looksRemoved(rgba: Array(repeating: black, count: 8).flatMap { $0 } + white + white))
    }

    @Test func aPlaceholderLeavesTheGridUnlessItIsInUse() {
        let images = [image(1), image(2), image(3)]
        let removed: Set<URL> = [images[0].previewURL, images[1].previewURL]
        #expect(TakedownPlaceholder.shown(images, chosen: .unset, removed: removed).map(\.id) == [3])
        #expect(TakedownPlaceholder.shown(images, chosen: .image(2), removed: removed).map(\.id) == [2, 3])
        #expect(TakedownPlaceholder.shown(images, chosen: .none, removed: []).map(\.id) == [1, 2, 3])
    }

    @Test func anAppWithoutSteamGridDBArtworkIsAskedWhatItLooksLike() {
        let game = ArtworkNoGame.text(HostApp(id: 1, title: "Hades"))
        #expect(game.title == "Hades is not on SteamGridDB")
        let desktop = ArtworkNoGame.text(HostApp(id: 2, title: "Desktop"))
        #expect(desktop.title == "Choose what Desktop looks like")
        #expect(desktop.note.hasSuffix("Desktop is not looked up automatically."))
    }

    @MainActor @Test func theBuiltInArtworkScreenGoesBackWithAAndB() {
        var context = ShellHints.Context(screen: .artwork(hostID: "h", appID: 1))
        context.screenHints.artworkBuiltIn = true
        let hints = ShellHints.hints(context, kind: .controller)
        #expect(hints.map(\.button) == [.pad(.south), .pad(.east)])
        #expect(hints.map(\.label) == ["Back", "Back"])
    }
}
