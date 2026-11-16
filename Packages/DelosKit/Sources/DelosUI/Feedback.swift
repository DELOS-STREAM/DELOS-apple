import AudioToolbox
import Foundation
#if os(iOS)
import UIKit
#endif

/// The interface's sound and haptic cues.
public enum Cue: String, CaseIterable, Sendable {
    case move, select, back, open, error
}

/// UI sounds (the five blips of DELOS for Android, made by its tools/sounds/make_ui_sounds.py) and haptics on iPhone
/// and iPad. The sounds are system sounds: they mix with other audio, follow the silent switch and never block the main
/// thread (an `AVAudioPlayer` created at launch waited for the audio server and froze the first frame).
@MainActor
public final class Feedback {
    public var soundsEnabled = true
    public var hapticsEnabled = true

    private var sounds: [Cue: SystemSoundID] = [:]
    private var focusSilenced = true
    #if os(iOS)
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    public init() {
        for cue in Cue.allCases {
            guard let url = Bundle.module.url(forResource: "ui_\(cue.rawValue)", withExtension: "wav") else { continue }
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { sounds[cue] = id }
        }
    }

    /// The next focus change is not announced: the first focus of a screen is silent, like in the prototype.
    public func silenceNextFocus() {
        focusSilenced = true
    }

    /// Called whenever an item gains the focus.
    public func focusMoved() {
        if focusSilenced { focusSilenced = false } else { play(.move) }
    }

    /// How many cues were played: an activation sees whether the action it ran announced itself.
    private(set) var playedCount = 0

    /// An activation (A, a tap, a click): runs [run] and then plays [cue], unless [run] played a cue itself, so one
    /// activation is never two sounds. [cue] nil: the activation is silent on its own. [run] returns whether it did
    /// anything; nothing, no cue.
    @discardableResult
    public func activate(_ cue: Cue?, _ run: () -> Bool) -> Bool {
        let before = playedCount
        guard run() else { return false }
        if let cue, playedCount == before { play(cue) }
        return true
    }

    public func play(_ cue: Cue) {
        playedCount += 1
        if soundsEnabled, let id = sounds[cue] { AudioServicesPlaySystemSound(id) }
        #if os(iOS)
        guard hapticsEnabled else { return }
        switch cue {
        case .move, .back: selection.selectionChanged()
        case .select, .open: impact.impactOccurred()
        case .error: notification.notificationOccurred(.error)
        }
        #endif
    }

    /// Whether every cue's sound was loaded (false when a file is missing from the bundle).
    var allSoundsLoaded: Bool { sounds.count == Cue.allCases.count }
}
