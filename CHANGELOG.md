# Changelog

All notable changes to DELOS for Apple are documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). The first version will be 0.1.0.

## [Unreleased]

### Added

- Video frame pacing adds Android's Balanced with FPS limit, Warp Drive and Warp 2: real host FPS cap/2x/4x
  requests with the closest display-layer presentation behavior, not generated frames. Native Nano Pacer and
  internal decoder tuning are not falsely advertised; platform differences are documented.
- A decoder watchdog requests a fresh key frame after five seconds of arriving video without observed presentation
  progress. Network silence and unavailable presentation metrics do not trigger it; physical-device recovery is
  not yet verified.
- Game metadata in the library, when `DelosMetadataURL` is configured: the info row shows the HDR chip, HowLongToBeat's
  time and one pill of genres and one of themes (Steam's user tags first, IGDB otherwise, in the game's colors), the game
  menu gets Metadata (search and change the match, refresh, reset) and Settings → About lists the data providers. Without
  the address nothing changes and nothing is requested. Lookups against the real services are not verified.
- Pairing with a one-time code: the menu of a PC that is not paired yet offers "Pair with a PIN" and "Pair with a
  one-time code"; the latter asks for the PIN and passphrase made in the PC's web UI and says when the code was wrong.
- A second video renderer next to the display layer: it decodes with VideoToolbox, keeps the pictures in a small queue
  timed by the frame pacing modes and presents them from a `CAMetalDisplayLink` through Metal (BT.601, BT.709 and
  BT.2020 matrices, full and limited range, 8 and 10 bits). The display layer stays the default; the debug switch
  `-DelosRenderer metal` selects the new one. The statistics panel names the renderer and adds the Decoding and
  Frame queue rows (frames waiting, skipped, repeated and late). Against a model of the display layer on a virtual
  120 Hz display the queue drops far fewer frames; whether the real stream on the iPad is steadier is not verified.
- Settings now keeps the last tab during the session, moves one focus plate between rows, scrolls overflowing focused
  labels and reads long help automatically. Reduced motion leaves text still and help manually scrollable.
- Screen transitions follow the Android timing: the new screen settles while the previous one leaves faster.
- Toasts scale their whole card with the interface scale and announce their localized message through VoiceOver,
  with higher priority for errors. Spoken delivery on physical devices is not verified.
- Apple TV: the Siri Remote and game controllers work on every screen through the system focus engine (Menu is back,
  Play/Pause opens context menus and the stream menu), title-safe margins, a 24-point text floor, system keyboard
  fields, and the artwork matches kept in the caches.
- A new Swift app, DELOS, for iPhone, iPad and Apple TV next to the Moonlight reference app. So far it shows the
  start screen: the greeting, the Contour background, the DELOS palette, fonts and icons, and a focus that a game
  controller or the arrow keys move between two circles (iOS and iPadOS) or the Apple TV remote moves (tvOS).
- The app speaks the ten languages of DELOS for Android, with the same texts.
- The connection to the gaming PC, not yet shown in the interface: finding PCs on the local network, adding one by
  its address, pairing with a PIN, the app list and box art, Wake-on-LAN. After pairing, DELOS trusts only the PC's
  own certificate.
- The first run and profiles of DELOS for Android: the boot screen, creating a profile with one of the sixteen avatars
  and a name, the start screen's greeting and profile chip, and the profile screen (change the avatar and name, add or
  delete a profile). Each profile keeps its own appearance.
- Pairing a PC and its library: the start screen shows the paired PCs, the pairing screen the PCs found on the network
  or an address typed in, the PIN screen waits while the PIN is typed on the PC, and the library shows the PC's apps
  with their box art.
- The stream screen: it launches or resumes the app on the PC, tells DELOS for Android's loading lines while it
  connects, shows the video full screen at up to 120 Hz and sends game controllers (with rumble), a keyboard, a mouse
  and touch as a trackpad to the PC. L3 + R3 or a swipe from the left edge opens a small stream menu (Resume,
  Disconnect, Quit app); a stream that fails shows Android's result screen with Try again. Not yet tried with a real
  stream.
- Settings, with the Stream and Audio tabs of DELOS for Android: the video resolution (the presets and the display's
  own), the frame rate (up to what the display shows), the bitrate, the video codec (only the ones the device decodes)
  and playing audio on the PC. Each profile keeps its own; streams use them. A tap on a choice opens the list of its
  values, a tap on a switch flips it, and the help of the tapped setting shows beside the list. The library and the
  profile screen show the top navigation (Settings, Profile), and the left menu button of a controller opens the side
  menu with All settings.
- Holding a direction on a controller or the keyboard repeats it, as on Android.
- Settings → Appearance of DELOS for Android: the theme (dark or light), the eight color palettes with their colors,
  the eleven animated backgrounds and reduced animations; interface sounds under Audio and interface haptics under
  Controls. Each change shows at once and is kept per profile.
- The full statistics panel and the stream menu's Overlay toggle from DELOS for Android: negotiated resolution and
  codec, incoming and displayed frame rates, video payload bandwidth, network round-trip time, host processing,
  presentation lateness and missing frames. Actual decode duration and RTP packet-loss percentage are unavailable
  with the current renderer/core and are not invented. Live statistics on a real stream are not verified.
- The status bar of DELOS for Android: Wi-Fi, the battery with its percentage (red when low, a bolt while charging)
  and the clock at the right, and the connected PC beside the brand on the library, Settings and Profile. Settings →
  Appearance has the Clock (System, 12-hour, 24-hour) and the Interface scale (100 to 130 %), which enlarges text and
  icons and zooms the status bar.
- Settings → About → MISC → Language on iPhone and iPad: the current app language, with an action that opens the
  app's page in system Settings. Language selection stays with iOS; the row and otherwise empty About tab are omitted
  on tvOS. Changing the language through Settings on physical devices is not verified.
- Context menus of DELOS for Android, opened with the right menu button or X of a controller, or a long press: a PC on
  the start screen (start DELOS with it, wake it, rename it), a game in the library (start, resume, quit, or quit the
  running game and start this one) and the profiles (switch, new profile) from the profile chip or Switch profile.
- Dialogs for typing a name: Rename PC and Rename profile.
- The default PC: marked and focused first on the start screen, chosen per profile.
- Toasts of DELOS for Android at the top right, colored by kind (information, done, warning, error, undo), with a
  timer line. Deleting a profile can be undone for 10 seconds with Y or a tap on its toast.
- The library of DELOS for Android: the focused game's background behind it (blurred, slowly tilting, its colors
  tinting the animated background), its logo or name, the streaming time and when it was last streamed, a Running
  badge and chip, a Last played badge, and covers with placeholder art. Artwork from SteamGridDB (covers, wide covers,
  backgrounds, logos) with your own API key under Settings → Covers, kept in a size-limited cache; the PC's box art
  is cached too. Settings → Appearance gains Match the app's colors, App background and its blur and opacity.
- The Devices screen, the third button of the top navigation (Settings, Profile, Devices): the paired PCs with their
  status, and a menu per PC to connect, make it the default, rename it, wake it, unpair it or remove it; the last
  circle pairs a new PC.
- DELOS for Mac (macOS 15 or later, native SwiftUI, App Sandbox, hardened runtime): one resizable window that opens at
  1920 × 1080 points and goes full screen, the same screens and settings as on the other platforms, a Mac's battery in
  the status bar and a back button for the mouse. During a stream the keyboard, the mouse (the pointer is hidden and
  locked to the stream, its motion sent as relative movement) and game controllers go to the PC; Control + Option +
  Shift + M, or holding Escape for a second, opens the stream menu and frees the pointer, as does L3 + R3. Command-Q,
  Quit and closing the window disconnect the stream first. `sh tools/mac.sh` builds an ad-hoc signed copy, starts it
  and takes a screenshot of its window. Not yet tried with a real stream.

### Changed

- Feedback and motion as in DELOS for Android: a tap or a click plays the same cue and squeezes the element (.97) as A
  does, without a second sound (Cancel and Back to library are BACK only; the stream menu opens with OPEN and closes with
  BACK; the PC ending the stream shows a toast), Apple TV plays MOVE and SELECT through the focus engine, circle rows and
  tall menus scroll to the focused item, icons cross-fade between Regular and Fill, the focus curves are 420 ms and jump
  with reduced motion, covers get the light sweep, a settings choice slides its value and nudges its chevron, and the
  stream menu is Android's dock: four glass tiles, one gliding ring, the blurred stream and the staggered entrance.
- The repository is set up for DELOS: README, contribution and security policy, third-party record, commit and branch
  hooks. CI runs only for release tags.
- Streams no longer ask GeForce Experience to optimize the game's settings, as DELOS for Android.
- The profile chip on the start screen opens the profiles menu instead of the profile screen, as on Android; a PC that
  sleeps and can be woken says so.

### Removed

- The Moonlight for iOS/tvOS reference app it was forked from (Objective-C, storyboards, Core Data), its prebuilt
  FFmpeg, SDL2 and Opus libraries (71 MB without recorded sources) and the X1Kit and moonlight-common-c submodules.
- The inherited Moonlight workflow that ran on every push and pull request, and the Moonlight bot configurations.

### Fixed

- The Moonlight reference app starts on iOS and tvOS 27, which stop apps without the scene lifecycle.
- The DELOS app no longer stops at launch: it finds the OpenSSL framework it embeds.
