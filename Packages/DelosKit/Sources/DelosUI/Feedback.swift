import AVFoundation
import Foundation
import OSLog
#if os(iOS)
import UIKit
#endif

/// The interface's sound and haptic cues.
public enum Cue: String, CaseIterable, Sendable {
    case move, select, back, open, error
}

/// Interface cues use media-volume playback. Audio-server work and WAV preparation stay off the main actor.
/// The stream owns its audio-session mode; UI cues never deactivate it or replace an existing playback category.
@MainActor
public final class Feedback {
    public var soundsEnabled = true
    public var hapticsEnabled = true

    private let sounds: any CueSoundPlaying
    private var focusSilenced = true
    #if os(iOS)
    private let selection = UISelectionFeedbackGenerator()
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    public init() {
        sounds = MediaCueSounds()
    }

    init(sounds: any CueSoundPlaying) { self.sounds = sounds }

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
        if soundsEnabled, !Self.debugMuted { sounds.play(cue) }
        #if os(iOS)
        guard hapticsEnabled else { return }
        switch cue {
        case .move, .back: selection.selectionChanged()
        case .select, .open: impact.impactOccurred()
        case .error: notification.notificationOccurred(.error)
        }
        #endif
    }

    /// DEBUG only: `-DelosMuteMedia YES` keeps simulator runs silent (no interface cues).
    #if DEBUG
    private static let debugMuted = UserDefaults.standard.bool(forKey: "DelosMuteMedia")
    #else
    private static let debugMuted = false
    #endif

}

protocol CueSoundPlaying: Sendable {
    func play(_ cue: Cue)
}

/// All mutable AVAudioPlayer state belongs to this serial queue, not to the caller's actor.
private final class MediaCueSounds: CueSoundPlaying, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.meitoncz.delos", category: "InterfaceAudio")
    private let queue = DispatchQueue(label: "io.github.meitoncz.delos.interface-audio", qos: .userInitiated)
    private var players: [Cue: AVAudioPlayer] = [:]

    init() {
        queue.async { [self] in
            do { try configureSession(activate: false) }
            catch { Self.logger.error("Interface audio preparation session failed: \(error.localizedDescription, privacy: .public)") }
            for cue in Cue.allCases {
                guard let url = Bundle.module.url(forResource: "ui_\(cue.rawValue)", withExtension: "wav") else {
                    Self.logger.error("Missing interface cue: \(cue.rawValue, privacy: .public)")
                    continue
                }
                do {
                    let player = try AVAudioPlayer(contentsOf: url)
                    player.prepareToPlay()
                    players[cue] = player
                } catch {
                    Self.logger.error("Interface cue preparation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func play(_ cue: Cue) {
        queue.async { [self] in
            do {
                try configureSession(activate: true)
                guard let player = players[cue] else { return }
                player.currentTime = 0
                if !player.play() { Self.logger.error("Interface cue playback did not start: \(cue.rawValue, privacy: .public)") }
            } catch {
                Self.logger.error("Interface audio session failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func configureSession(activate: Bool) throws {
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        // Preparation can activate the session too. Never prepare under the default solo-ambient category.
        // AudioOutput owns moviePlayback during a stream, so an existing playback session is left unchanged.
        if session.category != .playback {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        if activate { try session.setActive(true) }
        #endif
    }
}
