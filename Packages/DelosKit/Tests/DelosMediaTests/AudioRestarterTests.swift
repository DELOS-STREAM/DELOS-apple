import Synchronization
import Testing
@testable import DelosMedia

/// A fake engine: a flag the system can clear, and a count of the starts.
private final class FakeEngine: Sendable {
    let running = Mutex(false)
    let starts = Mutex(0)
    let startFails = Mutex(false)

    func restarter() -> AudioRestarter {
        AudioRestarter(isRunning: { self.running.withLock { $0 } }, restart: {
            self.starts.withLock { $0 += 1 }
            if self.startFails.withLock({ $0 }) { return false }
            self.running.withLock { $0 = true }
            return true
        })
    }
    func systemStops() { running.withLock { $0 = false } }
}

@Suite struct AudioRestarterTests {
    @Test(arguments: [AudioRestarter.Event.configurationChange, .routeChange])
    func aStoppedEngineIsStartedAfterAChange(event: AudioRestarter.Event) {
        let engine = FakeEngine()
        let restarter = engine.restarter()
        restarter.setWanted(true)
        engine.systemStops()

        #expect(restarter.handle(event))
        #expect(engine.running.withLock { $0 })
    }

    @Test func aRunningEngineIsLeftAlone() {
        let engine = FakeEngine()
        let restarter = engine.restarter()
        restarter.setWanted(true)
        engine.running.withLock { $0 = true }

        #expect(!restarter.handle(.routeChange))
        #expect(engine.starts.withLock { $0 } == 0)
    }

    @Test func afterStopNothingStartsTheEngine() {
        let engine = FakeEngine()
        let restarter = engine.restarter()
        restarter.setWanted(true)
        restarter.setWanted(false)

        #expect(!restarter.handle(.configurationChange))
        #expect(!restarter.handle(.interruptionEnded))
        #expect(engine.starts.withLock { $0 } == 0)
    }

    @Test func theEngineWaitsForTheEndOfACallAndThenStarts() {
        let engine = FakeEngine()
        let restarter = engine.restarter()
        restarter.setWanted(true)
        engine.running.withLock { $0 = true }

        restarter.handle(.interruptionBegan)
        engine.systemStops()
        // Route changes during the call do not try to start it
        #expect(!restarter.handle(.routeChange))
        #expect(!restarter.handle(.configurationChange))
        #expect(engine.starts.withLock { $0 } == 0)

        #expect(restarter.handle(.interruptionEnded))
        #expect(engine.running.withLock { $0 })
    }

    @Test func aFailedStartIsTriedAgainByTheNextEvent() {
        let engine = FakeEngine()
        let restarter = engine.restarter()
        restarter.setWanted(true)
        engine.startFails.withLock { $0 = true }

        #expect(!restarter.handle(.configurationChange))
        engine.startFails.withLock { $0 = false }
        #expect(restarter.handle(.routeChange))
        #expect(engine.starts.withLock { $0 } == 2)
    }
}
