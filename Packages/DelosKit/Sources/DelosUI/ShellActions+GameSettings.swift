import DelosData
import DelosHost

/// App settings: the stream settings one app overrides in the current profile (`GameSettingsStore` of DELOS for Android,
/// docs/PER_APP_SETTINGS.md).
extension ShellActions {
    /// Opens the App settings screen of [app] above the library.
    func openAppSettings(hostID: String, app: HostApp) {
        go { navigator.push(.appSettings(hostID: hostID, appID: app.id), focus: GameSettingsScreen.firstFocus()) }
    }

    /// What the app overrides in the current profile.
    func gameOverrides(hostID: String, appID: Int) -> GameSettingsOverride {
        guard let profile = profiles.current?.id else { return GameSettingsOverride() }
        return gameSettings.load(profile: profile, hostID: hostID, appID: appID)
    }

    /// The settings a stream of the app uses: the current profile's, with the app's overrides laid over them. The one place
    /// a launch reads them, so every way to start the app streams with its overrides.
    func streamSettings(hostID: String, appID: Int) -> StreamSettings {
        let profile = profiles.current?.id ?? ""
        return gameOverrides(hostID: hostID, appID: appID).merged(onto: streams.load(profile: profile))
    }
}
