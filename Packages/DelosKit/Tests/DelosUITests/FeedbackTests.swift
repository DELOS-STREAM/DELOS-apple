import Synchronization
import Testing
@testable import DelosUI

@MainActor
@Suite struct FeedbackTests {
    private final class Sounds: CueSoundPlaying, Sendable {
        let cues = Mutex<[Cue]>([])
        func play(_ cue: Cue) { cues.withLock { $0.append(cue) } }
        var played: [Cue] { cues.withLock { $0 } }
    }

    @Test func mediaMuteDoesNotSuppressActionAccountingAndCannotLeakSound() {
        let sounds = Sounds()
        let feedback = Feedback(sounds: sounds)
        feedback.hapticsEnabled = false
        feedback.soundsEnabled = false
        feedback.play(.select)
        #expect(sounds.played.isEmpty)
        feedback.soundsEnabled = true
        feedback.play(.open)
        #expect(sounds.played == [.open])
        #expect(feedback.playedCount == 2)
    }

    @Test func anActionsExplicitCueReplacesTheDefaultAcrossAudioBackends() {
        let sounds = Sounds()
        let feedback = Feedback(sounds: sounds)
        feedback.hapticsEnabled = false
        feedback.activate(.select) { feedback.play(.back); return true }
        #expect(sounds.played == [.back])
    }

    @Test func initialAndProgrammaticallyRestoredFocusAreSilent() {
        let sounds = Sounds()
        let feedback = Feedback(sounds: sounds)
        feedback.hapticsEnabled = false
        feedback.focusMoved()
        #expect(sounds.played.isEmpty)
        feedback.focusMoved()
        #expect(sounds.played == [.move])
        feedback.silenceNextFocus()
        feedback.focusMoved()
        #expect(sounds.played == [.move])
    }
}
