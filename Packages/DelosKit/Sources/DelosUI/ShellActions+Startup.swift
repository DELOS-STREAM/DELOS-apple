import DelosData
import Foundation

extension ShellActions {
    /// "Skip the start screen" (`ui_skip_start`, Shell.kt of DELOS for Android): when DELOS opens on the start screen and
    /// the profile chose it, the default PC is connected to straight away, once it is known as paired (waiting up to
    /// 4 s for the stored PCs, `awaitPc(default, 4_000)`). Nothing happens when the start screen was left meanwhile.
    func skipStartIfChosen(wait: Duration = .seconds(4)) async {
        let startup = profiles.startup
        guard startup.skipStart, let hostID = startup.defaultPC, navigator.current == .start else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + wait
        while hosts.host(hostID)?.pin == nil {
            guard clock.now < deadline, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard navigator.current == .start else { return }
        connect(hostID)
    }
}
