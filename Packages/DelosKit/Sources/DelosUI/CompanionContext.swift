import DelosData
import DelosHost
import SwiftUI

/// The kinds of content the companion has for a screen (`ContentKind`, CompanionPage.kt:80-101 of DELOS for Android).
/// Exhaustive on purpose: a screen added to ``Screen`` does not compile until it is placed here, and ``fallback`` (the
/// status card with the screen's title, purpose and hints) is a valid place, so the companion is never empty.
enum CompanionContentKind: Equatable, Sendable {
    case pc, pairHost, pin, game, help, artwork, profile, createProfile, boot, stream, fallback

    static func of(_ screen: Screen) -> CompanionContentKind {
        switch screen {
        case .home: .game
        case .start, .devices: .pc
        case .pair: .pairHost
        case .pin, .pairCode: .pin
        case .settings, .appSettings: .help
        case .artwork: .artwork
        case .profile: .profile
        case .createProfile: .createProfile
        case .boot: .boot
        case .stream: .stream
        case .oscPreview: .fallback
        }
    }

    /// The title of [screen] on the fallback card (`screenTitle`): the name of the screen on the main screen.
    static func title(_ screen: Screen) -> String {
        switch screen {
        case .home, .stream: L("companion_screen_home")
        case .start: L("companion_screen_start")
        case .devices: L("devices_title")
        case .pair: L("pairing_pc_title")
        case .pin, .pairCode: L("companion_screen_pairing")
        case .settings: L("companion_screen_settings")
        case .appSettings: L("companion_screen_game_settings")
        case .oscPreview: L("companion_screen_osc")
        case .artwork: L("companion_screen_artwork")
        case .profile: L("companion_screen_profile")
        case .createProfile: L("companion_screen_create_profile")
        case .boot: L("companion_screen_boot")
        }
    }

    /// The one-line purpose of [screen] on the fallback card (`screenPurpose`).
    static func purpose(_ screen: Screen) -> String {
        switch screen {
        case .home, .stream: L("companion_purpose_home")
        case .start: L("companion_purpose_start")
        case .devices: L("companion_purpose_devices")
        case .pair: L("companion_purpose_pair_pc")
        case .pin, .pairCode: L("companion_purpose_pin")
        case .settings: L("companion_purpose_settings")
        case .appSettings: L("companion_purpose_game_settings")
        case .oscPreview: L("companion_purpose_osc")
        case .artwork: L("companion_purpose_artwork")
        case .profile: L("companion_purpose_profile")
        case .createProfile: L("companion_purpose_create_profile")
        case .boot: L("companion_purpose_boot")
        }
    }

    /// What the fallback and the welcome card are made of (`PublishCompanionContext`, CompanionPublisher.kt:150-180): the
    /// screen's title and purpose, the entries of the hint bar (the very list the bar draws, so the two never disagree), the
    /// connected PC with its status and running game, and whether any PC is paired.
    @MainActor
    static func context(screen: Screen, hints: [Hint], host: HostRecord?, hosts: HostStore) -> ShellContext {
        let running = host.flatMap { host in host.runningAppID == 0 ? nil : hosts.apps[host.id]?.first { $0.id == host.runningAppID }?.title }
        return ShellContext(
            title: title(screen), purpose: purpose(screen), hints: hints.map { CompanionHint(button: $0.button, label: $0.label) },
            host: host.map { CompanionHostLine(name: $0.name, status: StartScreen.status($0, isDefault: false), runningGame: running) },
            welcome: hosts.paired.isEmpty)
    }
}
