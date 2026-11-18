import DelosData
import DelosMedia

/// What the upscaler works with on this display: the stream, the view it fills (landscape pixels), the scale mode and the
/// MetalFX scalers of the GPU. Settings and the stream menu read the upscaler's sizes from it before a frame is drawn
/// (``DelosMedia/UpscalerSizes/plan(stream:view:scaleMode:mode:supersamplingLevel:support:maxTextureSize:)``).
struct UpscalerSizePlan: Equatable {
    var stream: StreamResolution
    var viewWidth: Int
    var viewHeight: Int
    var scaleMode: VideoScaleMode
    var support: MetalFXSupport

    /// A plan for a display of `displayWidth` × `displayHeight` pixels in either orientation: the stream fills it in
    /// landscape.
    init(stream: StreamResolution, displayWidth: Int, displayHeight: Int, scaleMode: VideoScaleMode, support: MetalFXSupport) {
        self.stream = stream
        viewWidth = max(displayWidth, displayHeight)
        viewHeight = min(displayWidth, displayHeight)
        self.scaleMode = scaleMode
        self.support = support
    }

    /// The display's own resolution, the stream that has the picture's size on it.
    var display: StreamResolution { StreamResolution(width: viewWidth, height: viewHeight) }

    func sizes(mode: UpscalerMode, level: Int) -> UpscalerSizes {
        UpscalerSizes.plan(
            stream: (stream.width, stream.height), view: (viewWidth, viewHeight), scaleMode: scaleMode, mode: mode,
            supersamplingLevel: level, support: support)
    }

    /// The stream already has the picture's size, so a scaling mode supersamples it where the larger size fits.
    var isNativeInput: Bool {
        UpscalerSizes.isNativeInput(stream: (stream.width, stream.height), view: (viewWidth, viewHeight), scaleMode: scaleMode)
    }

    /// The plan the supersampling levels describe: this stream when it has the picture's size, else the display's own.
    var supersampled: UpscalerSizePlan {
        guard !isNativeInput else { return self }
        var plan = self
        plan.stream = display
        return plan
    }

    /// Some supersampling level fits the limits for `mode` (a stream at the picture's size that is not too large).
    func supersamples(mode: UpscalerMode) -> Bool {
        isNativeInput && (1...2).contains { sizes(mode: mode, level: $0).isSupersampling }
    }
}

/// The upscaler's sizes in words: the Settings and stream menu notes, the supersampling levels and the statistics line.
enum UpscalerSizeText {
    /// "1440 × 1080", as the resolution help writes a size.
    static func size(_ width: Int, _ height: Int) -> String { "\(width) × \(height)" }

    static func size(_ resolution: StreamResolution) -> String { size(resolution.width, resolution.height) }

    /// What the upscaler does with `stream`: enlarges it, supersamples it, or leaves its size; nil for Sharpen only (and a
    /// device without the mode's MetalFX scaler, where Sharpen only runs), whose help says it never scales.
    static func note(stream: StreamResolution, sizes s: UpscalerSizes) -> String? {
        guard s.mode != .sharpen else { return nil }
        if s.isSupersampling {
            return L("help_note_upscaler_supersamples", size(stream), size(s.internalWidth, s.internalHeight),
                     size(s.presentationWidth, s.presentationHeight))
        }
        if s.enlarges(width: stream.width, height: stream.height) {
            return L("help_note_upscaler_upscales", size(stream), size(s.internalWidth, s.internalHeight))
        }
        return L("help_note_upscaler_unscaled", size(stream), size(s.presentationWidth, s.presentationHeight))
    }

    /// A supersampling level's name with the size it renders at on this display ("1.33× · 3226 × 2224"); the bare factor
    /// where that size is over the limits.
    static func levelLabel(_ level: Int, plan: UpscalerSizePlan, mode: UpscalerMode) -> String {
        let factor = L(level >= 2 ? "sgsr_supersampling_level_2_short" : "sgsr_supersampling_level_1_short")
        let s = plan.supersampled.sizes(mode: mode, level: level)
        guard s.isSupersampling else { return factor }
        return L("settings_screen_dot_join", factor, size(s.internalWidth, s.internalHeight))
    }

    /// What a supersampling level does on this display: the size it renders the display-sized stream at, or that this size
    /// is over the upscaler's limit. Nil where no MetalFX scaler runs the mode.
    static func levelHelp(_ level: Int, plan: UpscalerSizePlan, mode: UpscalerMode) -> String? {
        let native = plan.supersampled
        let s = native.sizes(mode: mode, level: level)
        guard s.mode != .sharpen else { return nil }
        if s.isSupersampling {
            return L("help_supersampling_renders", size(native.stream), size(s.internalWidth, s.internalHeight))
        }
        let wanted = UpscalerSizes.supersampledSize(presentation: (s.presentationWidth, s.presentationHeight), level: level)
        let limit = UpscalerSizes.pixelLimit
        return L("help_supersampling_too_large", size(wanted.width, wanted.height), size(limit.width, limit.height))
    }

    /// The statistics panel's scale line under the first one, a technical readout in English like the rest of the panel:
    /// the stream, what the upscaler made of it and the picture's size when that differs.
    static func statistics(streamWidth: Int, streamHeight: Int, sizes s: UpscalerSizes) -> String {
        let stream = size(streamWidth, streamHeight)
        let internalSize = size(s.internalWidth, s.internalHeight)
        let picture = size(s.presentationWidth, s.presentationHeight)
        if s.mode == .sharpen { return "Sharpen only: \(stream)" } // l10n-ignore
        if s.isSupersampling { return "Supersampled: \(stream) → \(internalSize) → \(picture)" } // l10n-ignore
        guard s.enlarges(width: streamWidth, height: streamHeight) else { return "Not upscaled: \(stream) → \(picture)" } // l10n-ignore
        return internalSize == picture ? "Upscaled: \(stream) → \(internalSize)" : "Upscaled: \(stream) → \(internalSize) → \(picture)" // l10n-ignore
    }
}
