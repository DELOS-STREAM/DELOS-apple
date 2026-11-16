import AVFAudio
import Foundation
#if os(iOS)
import UIKit
#endif

/// The interface's sound and haptic cues.
public enum Cue: String, CaseIterable, Sendable {
    case move, select, back, open, error
}

/// UI sounds (the five blips of DELOS for Android, made by its tools/sounds/make_ui_sounds.py) and haptics on iPhone
/// and iPad. The sounds play in the ambient audio session: they mix with other audio and follow the silent switch.
@MainActor
public final class Feedback {
    public var soundsEnabled = true
    public var hapticsEnabled = true

    private var players: [Cue: AVAudioPlayer] = [:]
    private var focusSilenced = true
    #if os(iOS)
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    public init() {
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        #endif
        for cue in Cue.allCases {
            guard let url = Bundle.module.url(forResource: "ui_\(cue.rawValue)", withExtension: "wav"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[cue] = player
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

    public func play(_ cue: Cue) {
        if soundsEnabled, let player = players[cue] {
            player.currentTime = 0
            player.play()
        }
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
    var allSoundsLoaded: Bool { players.count == Cue.allCases.count }
}
