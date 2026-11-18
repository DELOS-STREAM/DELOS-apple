import Foundation

/// The sizes the upscaler works at, in pixels: the mode that runs, the size it reconstructs at (MetalFX's output, the
/// internal size) and the picture's size on the view (the presentation size). The internal size is larger than the
/// presentation while it supersamples and the stream's own size with Sharpen only; a stream as large as the picture or
/// larger is sampled into it directly and reports the picture's size (``enlarges(width:height:)`` is then false).
public struct UpscalerSizes: Sendable, Equatable {
    public var mode: UpscalerMode
    public var internalWidth: Int
    public var internalHeight: Int
    public var presentationWidth: Int
    public var presentationHeight: Int

    public init(mode: UpscalerMode, internalWidth: Int, internalHeight: Int, presentationWidth: Int, presentationHeight: Int) {
        self.mode = mode
        self.internalWidth = internalWidth
        self.internalHeight = internalHeight
        self.presentationWidth = presentationWidth
        self.presentationHeight = presentationHeight
    }

    /// Reconstructed larger than the picture, then reduced to it.
    public var isSupersampling: Bool { internalWidth > presentationWidth && internalHeight > presentationHeight }

    /// A MetalFX scaler enlarges a stream of `width` × `height` (it only ever enlarges).
    public func enlarges(width: Int, height: Int) -> Bool {
        mode != .sharpen && (internalWidth > width || internalHeight > height)
    }

    /// The sizes of a drawing that was made.
    init(_ report: UpscaleReport) {
        let d = report.dimensions
        self.init(
            mode: report.mode, internalWidth: d.internalWidth, internalHeight: d.internalHeight,
            presentationWidth: d.presentationWidth, presentationHeight: d.presentationHeight)
    }

    /// The sizes the upscaler will use for a stream of `stream` pixels on a view of `view` pixels placed by `scaleMode`,
    /// as ``MetalUpscaler/upscale(source:mode:presentation:supersamplingLevel:frameTime:hdr:commandBuffer:)``
    /// decides them: the mode this GPU runs for `mode` (``MetalFXSupport/effectiveMode(_:)``), the presentation size
    /// (``PictureGeometry``), the internal size (``UpscalerDimensions/plan(source:presentation:maxTextureSize:supersamplingLevel:)``:
    /// supersampling only when the stream already has the picture's size and the larger size fits the limits) and MetalFX's
    /// output, which keeps the stream's aspect ratio and the scaler's largest factor (``MetalUpscaler/scalerOutput(input:target:scales:)``).
    public static func plan(
        stream: (width: Int, height: Int), view: (width: Int, height: Int), scaleMode: VideoScaleMode, mode: UpscalerMode,
        supersamplingLevel: Int, support: MetalFXSupport = .system, maxTextureSize: Int = 16_384
    ) -> UpscalerSizes {
        let geometry = PictureGeometry.make(video: stream, target: view, mode: scaleMode)
        let presentation = (width: geometry.presentationWidth, height: geometry.presentationHeight)
        let mode = support.effectiveMode(mode)
        guard mode != .sharpen else {
            return UpscalerSizes(
                mode: mode, internalWidth: stream.width, internalHeight: stream.height,
                presentationWidth: presentation.width, presentationHeight: presentation.height)
        }
        let d = UpscalerDimensions.plan(
            source: stream, presentation: presentation, maxTextureSize: maxTextureSize, supersamplingLevel: supersamplingLevel)
        let output = MetalUpscaler.scalerOutput(
            input: stream, target: (d.internalWidth, d.internalHeight), scales: support.scales(mode))
        // Without an enlargement the stream is sampled into the picture directly; the drawing reports the planned size
        let internalSize = output ?? (d.internalWidth, d.internalHeight)
        return UpscalerSizes(
            mode: mode, internalWidth: internalSize.width, internalHeight: internalSize.height,
            presentationWidth: d.presentationWidth, presentationHeight: d.presentationHeight)
    }

    /// Whether the stream already has the view's size for `scaleMode`, so a scaling mode supersamples it (when its larger
    /// size fits the limits).
    public static func isNativeInput(
        stream: (width: Int, height: Int), view: (width: Int, height: Int), scaleMode: VideoScaleMode
    ) -> Bool {
        let geometry = PictureGeometry.make(video: stream, target: view, mode: scaleMode)
        return UpscalerDimensions.isNativeInput(
            source: stream, presentation: (geometry.presentationWidth, geometry.presentationHeight))
    }

    /// The internal size supersampling at `level` asks for a picture of `presentation` pixels (4/3 at level 1, 2 at
    /// level 2, even sides), before the limits decide whether it is used
    /// (``UpscalerDimensions/plan(source:presentation:maxTextureSize:supersamplingLevel:)``).
    public static func supersampledSize(presentation: (width: Int, height: Int), level: Int) -> (width: Int, height: Int) {
        let numerator = level >= 2 ? 2 : 4, denominator = level >= 2 ? 1 : 3
        let width = max(2, presentation.width) & ~1, height = max(2, presentation.height) & ~1
        return ((width * numerator / denominator) & ~1, (height * numerator / denominator) & ~1)
    }

    /// The internal size's pixel limit as a size (``UpscalerDimensions/maxInternalPixels``; each side is also at most 3840).
    public static let pixelLimit = (width: 3840, height: 2160)
}

extension MetalFXSupport {
    /// A GPU with these scalers; `temporalScale` is the temporal scaler's smallest and largest scale factor.
    public static func scalers(spatial: Bool, temporal: Bool, temporalScale: ClosedRange<Float>) -> MetalFXSupport {
        MetalFXSupport(spatial: spatial, temporal: temporal, temporalScale: temporalScale)
    }
}
