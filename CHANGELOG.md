# Changelog

All notable changes to DELOS for Apple are documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). The first version will be 0.1.0.

## [Unreleased]

### Added

- The app icon: the mark of DELOS for Android (the gold ring and the blue moon on the dark background), drawn from its
  vector for iPhone and iPad (with a dark and a tinted variant), for the Mac (the rounded shape at every size) and for
  Apple TV (the layered icon and the Top Shelf images).
- Debug builds log the video path once a second (os_log category `StreamPerf` and the diagnostic log): the frame rate
  asked for and received, lost frame numbers, the rate the PC encoded at, FEC failures, the receive thread's time per
  frame, the decoder's backlog and time, the queue's drops by reason, the display link's rate, the GPU time, the
  thermal state and Low Power Mode, plus one line for the launch request and one for the display plan.
- Debug builds log animated artwork once a second (os_log category `ArtFPS`): per playing animation the frames shown a
  second against its file's rate, the display frames that waited for a decode, and the time from asking for a frame to
  having it, so a device console tells the rate artwork really plays at.
- Picture in Picture on iPhone and iPad (Settings → Appearance → Enable Picture-in-Picture observer mode): when DELOS
  leaves during a stream, the stream keeps playing in the system's Picture in Picture window, with its sound and its
  connection, and nothing is sent to the PC; what was held comes up there, and the stream menu and the keyboards close.
  The window's restore button, or going back to DELOS, gives the stream back as it was; closing the window closes the
  stream as leaving the app does, and the return connects again. The Mac keeps streaming in its window and Apple TV
  has no automatic start, so neither shows the setting. Not verified on a device.
- The controller Home button notice: on iOS, iPadOS and macOS 27 the system keeps a controller's Home button unless
  Settings → General → Game Controller leaves DELOS's Home action to the app. When a controller with a Home button
  connects and the system keeps it, an information toast says so once per launch, names the other ways to the stream
  menu (the swipe up from the bottom edge, Escape held, buttons recorded in Controls) and its action opens that
  settings page; it goes away once the setting defers to DELOS. Nothing on older systems and Apple TV. Not verified on
  a device.
- Fully External Display Mode (Settings → Display) works: a stream goes to a monitor or TV attached to the iPhone or
  iPad (USB-C, HDMI adapter, AirPlay screen) or to the Mac's other screen, with its menu, and comes back when it ends;
  the device's screen turns black and takes touches for the stream. Unplugging the screen leaves the stream. Not
  verified on a real external display.
- Diagnostics (docs/DIAGNOSTICS.md): DELOS keeps a small rolling log on the device (Settings → About → Keep diagnostic
  logs), notices a crash, a hang or a failed stream of the last run and offers once, in a card on the start and home
  screens, to report it: the log, cleaned of addresses, PC and profile names, ids and keys, is uploaded to the report
  service when the build has one, or saved to Files (DELOS folder) on iPhone and iPad and to Downloads on the Mac, and
  a prefilled GitHub draft opens. Nothing is sent without the user. Settings → About → Debug info shows the device, its
  displays and controllers, previews, shares, copies and clears the log, and has the vibration test and the rumble
  laboratory, whose edits become a Custom rumble feel. Apple TV cannot save, share or copy the log or open the draft.
  Not verified on a device.
- The link test: Settings → Stream has Test link and Use recommended bitrate under the bitrate. Test link measures
  what the network carries from the PC with Vibepollo's UDP probe (a portal shows each step, B stops it) and keeps
  the result per PC and kind of network with its date; the bitrate row then says the recommendation and why, and its
  help names both numbers. The bitrate is only changed by pressing Use recommended bitrate. App settings show the
  same recommendation. Not verified against a real PC.
- The Delos full keyboard on every device, as on DELOS for Android: the stream menu's Keyboard tile raises a bar of
  80 keys over the stream. Fingers (several at once) or the pointer press keys; a controller moves a gold ring
  with the D-pad or the left stick, A presses, B closes, L3 latches Shift, X and Y type Backspace and Space; on Apple
  TV the Siri Remote drives it. Modifiers held for a moment stay down (sticky modifiers), keys carry the modifiers
  that are down, Caps Lock and Shift change the legends, a popup shows the character typed, and the profile's
  keyboard size, width, alignment, opacity and vibration apply. While it is up the controllers type instead of
  playing, and everything held comes up at the PC when it closes. The system keyboard of iPhone and iPad moved to
  More → Open system keyboard.
- The six touch modes of DELOS for Android on iPhone and iPad: Multi touch (the fingers are the PC's touch screen,
  the mouse where the PC takes no touch), Mouse and Mouse with swapped buttons (tap, long press for the other
  button, a second finger scrolls), Trackpad natural (acceleration, flicks, double tap to drag, two-finger scroll)
  and Trackpad gaming (long press to drag, its own X/Y speed, absolute mouse mode), and touch off. Taps of three,
  four and five fingers open the keyboard, the full keyboard and the stream menu. The stream menu can switch the
  mode (kept when Remember mouse mode is on), pan and zoom the picture (kept when Remember zoom & pan is on) and
  turn the touch sensitivity on. The Apple Pencil is the PC's pen with its pressure, tilt and hover, or its mouse.
  The local pointer shows the system pointer and moves the PC's to where it is; the Mac scrolls from AppKit with the
  trackpad's speed and swapped axes. Not verified on a device or against a real PC.
- On-screen controls on iPhone and iPad, as on DELOS for Android: the D-pad, A/B/X/Y, bumpers, triggers, Back,
  Guide, Start, L3/R3, the trackpad button and fixed or free sticks in the DELOS style, any number of fingers at
  once, sent to the PC as controller 0. The default layout is computed for every screen shape; the gear edits it
  (turn on or off, move, resize) and only the changed controls are stored, against their side of the screen in
  layout units. The stream menu's More page toggles them and sets their opacity; Settings → Controls has a preview.
  They hide while a controller is in use, vibrate on press when the profile asks, and play controller 0's rumble on
  an iPhone. Apple TV and the Mac have no touchscreen and no on-screen controls.
- Surround audio: Settings → Audio asks the PC for stereo, 5.1 or 7.1. Each channel plays on the speaker of its
  name on an HDMI or AirPlay receiver that has it, and fewer speakers get the layout mixed down. The stream also
  sends the resolution scale factor and asks for full-range video when chosen. Real surround receivers are not
  verified.
- Live bitrate change and clipboard sync with Vibepollo and Apollo: the stream can ask the PC for another
  bitrate and reports what it accepted or why it failed; Smart Clipboard Sync sends this device's clipboard when
  the stream starts and fetches the PC's on Disconnect, with Android's toasts and the Hide clipboard content
  option. The stream menu's Bitrate page and clipboard rows come later; nothing was verified against a real PC.

- Controllers send their motion sensors (at the host's rate, up to 200 Hz, with the gyro smoothing of DELOS for
  Android), their battery and their touchpad to the PC and take the PC's light colour; player 1 can use the iPhone's or
  iPad's own sensors when its controller has none. Stick dead zone, flipped face buttons, Multiple controllers off,
  the mouse emulation (hold Start) with stick scrolling, Touchpad as mouse, Select/Guide from combinations on
  controllers without those buttons, and a quick double Start that opens the stream menu work as on Android.
  Controllers are no longer announced with capabilities the app does not deliver.
- The keyboard: Control + Alt + Shift with Z (release or grab the input), Q (disconnect) and C (local pointer), with
  Command instead of Control as well; the right Option key as the Windows key; the mouse's back and forward buttons as
  X1 and X2 only when on; every key held is released at the PC when the window loses the keyboard; keyboard keys can be
  recorded as the stream menu's buttons. The motion axes, battery, light and touchpad are not verified with a
  physical controller.
- SteamGridDB calls on the Artwork screen are tried again after 500, 1200 and 2500 ms when the service is busy (429,
  5xx) or the network drops; the loader stays up until the fourth attempt has failed.
- Artwork files up to 2 GB can be used, so a large animated background can be applied: downloads go to disk as they
  arrive and are never held in memory, and the artwork cache holds 2 GB.
- The Artwork screen leaves out images SteamGridDB has taken down (their thumbnail is its black placeholder), unless
  the image is the one in use.
- The Artwork screen of one of DELOS's own entries (Desktop, Remote Input and the others) shows its built-in artwork, a
  note that it cannot be changed and Back; such an app without a SteamGridDB game is asked "Choose what <app> looks like".
- The library of a PC that is no longer paired says "No PC paired yet"; an offline PC's library says how to wake it.
- The info row shows a Virtual display chip on Desktop when the PC can stream to a virtual display of its own.
- Starting a game on a PC DELOS has no address of says it cannot be reached, a virtual display the settings want but
  the PC cannot make is said in a warning (the main display is streamed), and Quit on such a PC says DELOS is still
  connecting to it.
- Try again on a failed stream first checks that the PC answers and still has the game, and otherwise returns to the
  library saying why; the hint bar over the result shows Select and Back to library.
- While artwork downloads or game info is looked up, a glass pill above the button hints shows what runs, "x of N" and
  a bar. Strings Android does not translate have their English text in every language of the catalog.
- The Metal renderer upscales the stream with MetalFX: MetalFX Spatial, MetalFX Temporal (motion vectors and a reactive
  mask computed from the video's own optical flow, a constant depth plane, no jitter, the history dropped on cuts and
  gaps), and Sharpen only (contrast-adaptive sharpening at the stream's size). The sharpness applies as a
  contrast-adaptive sharpen after the MetalFX scalers, and streams that already match the view are supersampled at
  1.33× or 2×. Where the device has no MetalFX (the simulators, Apple TV before tvOS 27.1, a GPU without it) the
  MetalFX modes run as Sharpen only, the upscaler reports itself unavailable and Settings says so. Stored modes of
  earlier builds map to the MetalFX modes. Two frames of GPU work at most, a lighter optical flow under load, and a
  warning when the upscaler cannot keep up with the frame rate. The video fills the view as chosen (fit, fill,
  stretch), the display runs the refresh rate the planner picks (reduce refresh rate, enforce display mode on the
  Mac, display criteria on Apple TV, variable refresh rate), HEVC and AV1 streams recover from loss with reference
  frame invalidation, and the receive thread runs at the interactive quality of service. The statistics know the
  1 % low, the render latency (average, 95th percentile, maximum), the upscaling time, the Sharpen pass and the
  upscaler's target. The look on a device, the GPU cost and real streams are not verified.

- Pairing waits for the trusted paired state instead of a fixed delay, and manual-address entry reports a PC
  that was not added. The start screen retargets its initial PC focus as discovery changes. On compact stages,
  the profile chip shares the status line, clears the measured status cluster and truncates long names.
  Avatar fallback glyphs use the smaller grid size.
- Game rumble has Original, Soft, Kick-start and Pulsing feels, live profile updates, an optional device
  vibration fallback and a strength control. DualSense feedback, weapon and positional vibration trigger effects
  use GameController; unsupported effects release the trigger rather than leaving resistance stuck.
  Physical-controller and Taptic playback are not verified.
- Interface cues use media-volume playback instead of system-alert sounds. Audio preparation runs off the main
  thread and preserves an active stream's audio-session mode. Device volume, silent-switch behavior and
  real-stream mixing are not verified on hardware.

- Controller hints use the approved complete Xbox, DualSense, DualShock 4 and Joy-Con font glyphs,
  with physical button positions preserved and no extra disc or connected-pad SF Symbols override. The shared
  library also includes Mac keyboard, mouse and trackpad symbols.
- The stream arrives at the end of the launch scene: while the tunnel opens, the live picture waits zoomed to 118 %
  and blurred, then springs in to 100 % with a short squash, wave and RGB split, and ends exactly on the plain picture.
  It is drawn by the Metal renderer on the live frames; with reduced motion, and with the display layer where Metal
  is unavailable, the picture is shown as it is. Not verified on a device.
- Controller hints use the same approved complete Xbox, DualSense, DualShock 4 and Joy-Con font glyphs as Android,
  with physical button positions preserved and no extra disc or connected-pad SF Symbols override. Both font files
  are byte-identical to Android; the shared library also includes Mac keyboard, mouse and trackpad symbols.
  Physical-device rendering is not verified.
- The library filter on the home screen (when `DelosMetadataURL` is configured): Y, or a tap on the hint bar's Filter
  (a glyphless pill while no controller is the input), opens a glass sheet with chips for genre and theme (with the number of games each holds), HDR support and
- The library filter of Android on the home screen (when `DelosMetadataURL` is configured): Y, or a tap on the hint bar's Filter
  (a 52 px glass pill with the filter symbol before its label while no controller is the input), opens a glass sheet with chips for genre and theme (with the number of games each holds), HDR support and
- A demo harness for debug builds (`-DelosDemo YES`, docs/BUILDING.md): a fake PC with games, generated artwork, fake metadata and a
  command script, none of it touching the network, the client identity or the app's data, and `tools/sim-walkthrough.sh` to
  screenshot any screen in a fresh simulator.
- The library filter on the home screen (when `DelosMetadataURL` is configured): Y, or the new filter button beside
  the title, opens a glass sheet with chips for genre and theme (with the number of games each holds), HDR support and
  duration, the live count and Reset (X) and Done. The filter is kept per PC, the hint bar says how many criteria are on
  ("Filter • 2 active") and the library note counts the games shown, and a filter that lets nothing through shows
  the empty state with a button that resets it. The whole library's cached metadata is read when it opens, so the
  chips are complete at once. The look on a device and on tvOS is not verified.
- Home on a compact stage (a narrow or squarish window, an iPad in a split view) lays itself out top-down: the
  covers scale with the stage and a second game always peeks in, the title box is centred between the status bar
  and the info row, the streaming-time block stands above the badges on a very narrow stage, and the small covers' placeholder
  titles shrink to fit their longest word.
- The artwork of DELOS's own entries (Desktop, Remote Input, Remote Monitor, Steam Big Picture) is bundled:
  their cover, wide cover and background show without SteamGridDB, which never looks them up.
- The stream menu's Overlay tile goes round three statistics overlays: off, the full panel and the compact line at
  the top center (frame rate, bandwidth, network and decoding delay, lost frames), with Off, On and Compact in its pill. The
  profile keeps the last choice for its next streams. The line has no Total delay and 1 % low, which neither
  renderer reports.
- Touch on settings rows (Settings, per-app settings): the first tap focuses a row and shows its help, a tap on the focused row
  changes it; a switch and the arrows of a choice take their own taps. A choice opens a popover list with the current value checked,
  a slider a popover with ◀ ▶ (hold to repeat), the slider and a value to tap and type (validated, snapped, clamped; the bitrate in
  Mbit/s). The popovers grow out of the tapped row with the same caret as the context menus and the stream menu's popover. The
  controller behaves as before. Not verified on a device.
- The launch can be cancelled at any moment by B, Escape or a Cancel pill, also while the scene opens over the stream; it only ends
  this client's attempt, never quits the game on the PC, and returns to the library.
- A tap outside the stream menu closes its popover, then the menu, and never reaches the game.

- HDR streaming: Settings → Stream gets an Enable HDR row (also an app setting) on devices whose display shows HDR and
  whose hardware decodes HEVC Main10 (a hardware-required VideoToolbox probe, not the per-codec check). With it on, the app
  offers HEVC Main10 (and AV1 Main 10 when AV1 is chosen), asks the host for HDR, passes the host's mastering display and
  content light metadata to both renderers, decodes 10-bit streams to 10-bit output and lets the display layer use extended
  dynamic range. The look on iPad and iPhone HDR displays is not verified.
- Hiding games: the game menu has Hide app and Show app, the side menu has "Show hidden apps" with the count, and a shown
  hidden game carries an eye-slash pill. Hidden games are kept per profile and per PC.
- The Artwork screen of the game menu: choose the cover, wide cover, background and logo among the still and animated
  SteamGridDB images, narrowed and sorted by the filter sheet, or leave it to the PC's artwork or the name, search for
  another name and match the game by hand. The choices are kept by automatic refreshes.
- Animated artwork plays: an animated WebP, GIF or APNG cover, wide cover, logo or game background plays over its first
  frame in the library, and the animated choices play in their Artwork screen tiles (a bar shows the download of the
  animation). Each frame keeps the time its file gives it, frames are decoded one at a time at the size they are shown,
  and nothing plays while it is off screen or covered, while the app is in the background, or with reduced motion; the
  game background starts after the game has stayed focused for half a second and loops with a cross-fade. Playback on
  devices and its cost there are not verified.
- App settings in the game menu: resolution, frame rate, bitrate, codec, frame pacing and host audio can be set for one
  app, stored per profile and app, with the CUSTOM marks, Reset all and Undo. A stream of the app uses them.
- Video frame pacing adds Balanced with FPS limit, Warp Drive and Warp 2: real host FPS cap/2x/4x
  requests with the closest display-layer presentation behavior, not generated frames. Native Nano Pacer and
  internal decoder tuning are not falsely advertised; platform differences are documented.
- A decoder watchdog requests a fresh key frame after five seconds of arriving video without observed presentation
  progress. Network silence and unavailable presentation metrics do not trigger it; physical-device recovery is
  not yet verified.
- Game metadata in the library, when `DelosMetadataURL` is configured: the info row shows the HDR chip, HowLongToBeat's
  time and one pill of genres and one of themes (Steam's user tags first, IGDB otherwise, in the game's colors), the game
  menu gets Metadata (search and change the match, refresh, reset) and Settings → About lists the data providers. Without
  the address nothing changes and nothing is requested. Lookups against the real services are not verified.
- The launch scene: while a stream connects, the hyperspace tunnel (a Metal port of the AGSL shader) runs behind
  the game's logo or title, the stream's resolution, codec and frame rate, the connection lines (each told at least
  1.2 s) and the progress; once the first frame is presented the information fades and the tunnel opens over the picture
  (2.2 s). Reduced motion shows a still scene and a 0.5 s fade. Leaving from the stream menu plays the exit scene: the
  picture blurs and zooms while the portal says "Disconnecting" or "Quitting <game>", then the library returns. The
  arrival effect on the picture itself is not ported; the look on a device and the shader's cost are not verified.
- Connecting to a PC goes through the portal: a PC that sleeps is sent Wake-on-LAN (the portal says it is
  waking up, or, when the PC has no known MAC address, waits for you to turn it on), is asked again every 3 s for up to
  two minutes, and its library opens when it answers; B, a tap or a click cancels, and a PC that stays silent ends with
  a toast. The press on a PC of the start screen, the pairing list, the Devices menu's Connect and the end of pairing
  all use it. The flow is a state machine tested with a fake clock and network; the real Wake-on-LAN and a real sleeping
  PC are not verified.
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
- Screen transitions: the new screen settles while the previous one leaves faster.
- Toasts scale their whole card with the interface scale and announce their localized message through VoiceOver,
  with higher priority for errors. Spoken delivery on physical devices is not verified.
- Apple TV: the Siri Remote and game controllers work on every screen through the system focus engine (Menu is back,
  Play/Pause opens context menus and the stream menu), title-safe margins, a 24-point text floor, system keyboard
  fields, and the artwork matches kept in the caches.
- A new Swift app, DELOS, for iPhone, iPad and Apple TV next to the Moonlight reference app. So far it shows the
  start screen: the greeting, the Contour background, the DELOS palette, fonts and icons, and a focus that a game
  controller or the arrow keys move between two circles (iOS and iPadOS) or the Apple TV remote moves (tvOS).
- The app speaks ten languages.
- The connection to the gaming PC, not yet shown in the interface: finding PCs on the local network, adding one by
  its address, pairing with a PIN, the app list and box art, Wake-on-LAN. After pairing, DELOS trusts only the PC's
  own certificate.
- The first run and profiles: the boot screen, creating a profile with one of the sixteen avatars
  and a name, the start screen's greeting and profile chip, and the profile screen (change the avatar and name, add or
  delete a profile). Each profile keeps its own appearance.
- Pairing a PC and its library: the start screen shows the paired PCs, the pairing screen the PCs found on the network
  or an address typed in, the PIN screen waits while the PIN is typed on the PC, and the library shows the PC's apps
  with their box art.
- The stream screen: it launches or resumes the app on the PC, tells the loading lines while it
  connects, shows the video full screen at up to 120 Hz and sends game controllers (with rumble), a keyboard, a mouse
  and touch as a trackpad to the PC. L3 + R3 or a swipe from the left edge opens a small stream menu (Resume,
  Disconnect, Quit app); a stream that fails shows a result screen with Try again. Not yet tried with a real
  stream.
- Settings, with the Stream and Audio tabs: the video resolution (the presets and the display's
  own), the frame rate (up to what the display shows), the bitrate, the video codec (only the ones the device decodes)
  and playing audio on the PC. Each profile keeps its own; streams use them. A tap on a choice opens the list of its
  values, a tap on a switch flips it, and the help of the tapped setting shows beside the list. The library and the
  profile screen show the top navigation (Settings, Profile), and the left menu button of a controller opens the side
  menu with All settings.
- Holding a direction on a controller or the keyboard repeats it.
- Settings → Appearance: the theme (dark or light), the eight color palettes with their colors,
  the eleven animated backgrounds and reduced animations; interface sounds under Audio and interface haptics under
  Controls. Each change shows at once and is kept per profile.
- The full statistics panel and the stream menu's Overlay toggle: negotiated resolution and
  codec, incoming and displayed frame rates, video payload bandwidth, network round-trip time, host processing,
  presentation lateness and missing frames. Actual decode duration and RTP packet-loss percentage are unavailable
  with the current renderer/core and are not invented. Live statistics on a real stream are not verified.
- The status bar: Wi-Fi, the battery with its percentage (red when low, a bolt while charging)
  and the clock at the right, and the connected PC beside the brand on the library, Settings and Profile. Settings →
  Appearance has the Clock (System, 12-hour, 24-hour) and the Interface scale (100 to 130 %), which enlarges text and
  icons and zooms the status bar.
- Settings → About → MISC → Language on iPhone and iPad: the current app language, with an action that opens the
  app's page in system Settings. Language selection stays with iOS; the row and otherwise empty About tab are omitted
  on tvOS. Changing the language through Settings on physical devices is not verified.
- Context menus, opened with the right menu button or X of a controller, or a long press: a PC on
  the start screen (start DELOS with it, wake it, rename it), a game in the library (start, resume, quit, or quit the
  running game and start this one) and the profiles (switch, new profile) from the profile chip or Switch profile.
- Dialogs for typing a name: Rename PC and Rename profile.
- The default PC: marked and focused first on the start screen, chosen per profile.
- Toasts at the top right, colored by kind (information, done, warning, error, undo), with a
  timer line. Deleting a profile can be undone for 10 seconds with Y or a tap on its toast.
- The library: the focused game's background behind it (blurred, slowly tilting, its colors
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
- Links and shortcut files from outside the app, as on DELOS for Android: an `art://` link pairs with a PC (with its
  one-time code when it has one) or starts a game or opens a PC, and an opened `.art` shortcut file starts its game. Each
  asks first in a dialog, since a link can come from any web page or app. A PC that sleeps is woken and waited for, a
  game already running on the PC is never quit (its library opens with a toast), and a link naming no known PC or game
  says so in a toast. A link that arrives before the first profile waits for it. Not verified on a device.

### Changed

- The GPU impact chip shows the chip icon again instead of a graphics card, as in DELOS for Android: Apple devices have a
  system on a chip rather than a separate graphics card. The icon fonts and `Symbols.swift` are synced from Android.
- Video frame pacing: Steady low latency takes the place of Lowest latency. Each frame is shown at the earliest refresh
  its arrival makes 99 times out of 100, measured against the PC's own frame times over the last two seconds, so the
  picture keeps the PC's cadence and a frame waits only the few milliseconds of the network's jitter, never a whole
  frame; with the display's deadline after the callback, a frame decoded just after it still reaches that refresh, and
  on an adaptive-sync Mac display the refreshes come at the display's fastest rate. A stored Lowest latency becomes
  Steady low latency; Balanced stays the default. On the modeled replay of the iPad Pro M5 log (1440×1080 at 120 fps on
  120 Hz, the log's assembly percentiles, clocks drifting ±100 ppm): 119.98 to 120.00 frames shown a second against
  119.93 to 120.00 with Balanced, and 17.8 to 24.1 ms from decoded to the screen at the median against 25.3 to 27.4 ms.
  If the display leaves no time after its callback, the median is 25.1 to 26.5 ms and the 99th percentile up to 3 ms
  longer than Balanced's. Debug builds name it in the StreamPerf launch line (`lock=p99/240`) and log its margin and
  window each second. Not verified on a device.
- Resolution choices on a display that is not 16:9 (iPad, iPhone, a 16:10 Mac) add the 720p, 1080p, 1440p and 4K line
  counts in the display's own shape, for example 1440x1080 and 1920x1440 on a 13" iPad Pro, so a stream fills the panel
  without black bars and the upscaler enlarges all of it. The 16:9 presets, Native and Custom stay.
- Settings and the stream menu show the upscaler's real sizes for this display: the resolution, upscaler and mode rows say
  what the stream becomes ("1440 × 1080 → 2752 × 2064"), the supersampling levels name the size they render at (or only
  the factor where that is over the upscaler's limit) and say when the stream is not at the display's size, and the
  statistics panel shows the stream, the upscaled size and the picture. The supersampling level's impact dims while it
  does nothing.
- VoiceOver: icons are no longer read as stray characters; every focusable item is one button with its texts (icon-only
  ones, the covers and the artwork tiles carry a label), double tap does what A does, a context menu is the Menu action,
  settings and stream menu rows read their value (switches On or Off) and choices and sliders adjust with a swipe up or
  down; selected avatars, PCs, tabs and chips say so, open menus and dialogs keep VoiceOver inside and the escape
  gesture goes back; a poor-connection notice is announced like a toast. Nothing looks different. Not verified with
  VoiceOver on a device.
- Texts: the local network prompt and the Mac's copyright line are translated into all ten languages; the CUSTOM badge
  of a per-app row is translated; the help of asynchronous decoding, of PyroWave and of the stream menu's sharpness no
  longer names MediaCodec, Vulkan or SGSR. `tools/l10n/check_usage.py` now also fails on a catalog entry without every
  language and on a text that names Android's platform.
- Every Settings row now does something on Apple. The metered bitrate applies when the network is expensive or in Low
  Data Mode at the stream's start (a quarter of the bitrate unless set). Wi-Fi keep-alive sends an empty packet to the
  PC every 20 ms during a stream. Asynchronous decoding switches VideoToolbox's asynchronous decompression in the Metal
  renderer (off: each frame is decoded before the next). Top center display puts a picture that does not fill the
  screen at the top (Fit) or cuts only its bottom (Fill), for touches too. Commit-text input sends what the system
  keyboard types as text; off, each character is pressed as its key on the US layout, as games that read single keys
  expect. A fractional custom refresh rate (59.94) is its own frame rate choice next to 60 and the PC is asked for
  exactly that rate. Not verified on a device or against a PC.
- The side menu's header shows the connected PC with a live dot and state (online, streaming, connecting, asleep,
  offline) under the profile name, and a card with the profile's whole streaming time (every game on every PC) and its
  last stream, in the library's stat-block style.
- Feedback and motion: a tap or a click plays the same cue and squeezes the element (.97) as A
- The stream menu opens with a tap of a controller's Home button, and holding Home for half a second sends Guide to the
  PC while it is held; the Home button's system overlay stays off during a stream. L3 + R3 no longer open the menu by
  default: Settings → Controls → Stream menu buttons records your own combination ("Not set" by default). On the touch
  screen the menu opens with a swipe up from a band above the bottom edge (Swipe up to open the menu, on by default)
  instead of the swipe from the left edge; touches starting in that band do not reach the PC. Not yet tried on a device.
- Feedback and motion as in DELOS for Android: a tap or a click plays the same cue and squeezes the element (.97) as A
  does, without a second sound (Cancel and Back to library are BACK only; the stream menu opens with OPEN and closes with
  BACK; the PC ending the stream shows a toast), Apple TV plays MOVE and SELECT through the focus engine, circle rows and
  tall menus scroll to the focused item, icons cross-fade between Regular and Fill, the focus curves are 420 ms and jump
  with reduced motion, covers get the light sweep, a settings choice slides its value and nudges its chevron, and the
  stream menu is a dock: four glass tiles, one gliding ring, the blurred stream and the staggered entrance.
- The repository is set up for DELOS: README, contribution and security policy, third-party record, commit and branch
  hooks. CI runs only for release tags.
- Streams no longer ask GeForce Experience to optimize the game's settings.
- The profile chip on the start screen opens the profiles menu instead of the profile screen; a PC that
  sleeps and can be woken says so.
- The side menu follows the finger: a drag in from the left edge pulls the panel, the scrim and the blur with it (a
  little past fully open with a rubber band), and on release it opens past 40 % of its width or with a quick flick and
  springs back otherwise; a drag to the left on the open menu closes it the same way. With reduced motion the drag only
  toggles the menu once it is long enough. On iPad and Apple TV the floating glass box has the same, larger gap to the
  left, top and bottom edges of the screen (the status bar and the home indicator no longer widen one of them) and
  materialises from the left edge (growing, sharpening from a blur, on a spring) and goes back into it; with reduced
  motion it fades. Not verified on a device yet.
- The game menu offers Metadata for every game except DELOS's own entries, also without a metadata service (its
  actions then say the service is unavailable). The home screen's notes for no paired PC and an offline PC point to
  the Devices screen.
- The info row's badges, when they do not fit, bounce like Android's: still for 0.7 s, linear to the end at 56 px/s, a
  0.9 s pause, back, a 0.9 s pause. Disconnect and Quit from the stream menu play SELECT when the library returns.
- MetalFX Spatial is the recommended upscaler mode (it was and stays the default, also of a new profile) and MetalFX
  Temporal is marked experimental in Settings and the stream menu: its help says it is meant for noisy, low-bitrate
  streams and costs several times more GPU. Measured on synthetic video, Temporal was better than Spatial only on a
  noisy moving picture, at about 4.7 times the GPU time.

### Removed

- Settings rows without an Apple meaning: Auto orientation and Auto invert resolution (the app is landscape only),
  PyroWave chroma (no PyroWave 4:4:4), the trackpad's drag-and-drop vibration and threshold, Force QWERTY (keys do not
  depend on the layout), LFR and Ultra low latency (MediaCodec options; VideoToolbox already decodes in real time), the
  Fast V-Sync frame pacing (Steady low latency is the bounded scheduler on Apple), and the on-screen virtual key rows
  with their layout import and export, until the virtual keys are ported. A stored Fast V-Sync becomes Balanced.
- The Moonlight for iOS/tvOS reference app it was forked from (Objective-C, storyboards, Core Data), its prebuilt
  FFmpeg, SDL2 and Opus libraries (71 MB without recorded sources) and the X1Kit and moonlight-common-c submodules.
- The inherited Moonlight workflow that ran on every push and pull request, and the Moonlight bot configurations.
- Settings → Display → Second display (Automatic, External display, Part of the device): an Apple device has no second
  panel built in, so every second screen is an external display and the choice changed nothing.
- MetalFX Temporal no longer reuses the previous frame's optical flow on every second frame when the GPU is busy. It
  saved about 0.07 ms a frame, and motion that was a frame old made the picture drift.

### Fixed

- The side menu's rows enter as on Android: top-down after the header (they rose bottom-up, in the order SwiftUI made
  them appear), and only their icon, label and value rise; the row keeps its place, so the focus ring no longer sits
  18 px low until the row has landed and then jumps up: it fades in together with its row's content, on the row's delay
  and curve (Android shows it from the first frame; the owner prefers it with its row). Every staggered entrance
  is now a render effect (opacity and offset where the view is drawn, Android's graphics layer): no body is evaluated
  and nothing is laid out again on each frame of a rise. The context menu's plate enters with the row it lies on, and the
  stream menu popover's rows take Android's timing (120 ms, then 46 ms a row). Not verified on a device.
- The start, home, devices, pairing, profile and avatar screens' entrances run top-down and left to right as on Android
  (the headline first, then the circles or covers in order): each element has its place instead of taking the next one
  as it appeared, which SwiftUI often did from the last element up. An element that appears more than 700 ms after its
  screen (a PC found later, a settings row a switch reveals) is just there, as on Android. The stream menu's Send keys
  and Commands pills rise in one after the other from the left, each with its focus plate. Not verified on a device.
- A long list of values that a tap on a settings row opens (Video resolution) starts below the top bar and the name
  under its focused button and scrolls, instead of running up under them.
- The animated game background on the home screen plays at its file's own frame rate, also in a debug build. Each frame
  was saturated, faded and laid over its extension by loops over the pixels in Swift, about 105 ms a frame unoptimized on
  an M6 Mac (Dredge's 24 fps background played at 9 frames a second there, about 4 on the owner's iPad Pro);
  CoreGraphics and Accelerate do it now, about 3 ms, and real SteamGridDB backgrounds of 10 to 60 frames a second play
  every frame (`AnimatedArtBenchmark`). Animations also decode two frames ahead instead of one, so Dredge's 62.5 fps
  cover keeps its pace while the main thread is busy. Not verified on a device.
- Settings search is a screen of its own, as on Android: the top navigation and the PC pill are hidden while it is open
  (the Settings button no longer takes the focus and shows its name), the hints are A Select and B Back, the focus starts
  on the field, the results keep Android's order (Appearance first), and B returns to the row that was focused. The back
  arrow closes the search instead of leaving Settings.
- Long texts scroll where they do on Android instead of ending in an ellipsis: the context menu's title, its line of
  facts and its rows (a row while focused), the stream dock's title, the stream menu popover's title, rows and values,
  the options of a choice popover, and on a narrow compact stage the streaming-time block above the badges when not
  even its short form fits. The right end of an overflowing text fades over its full 36 px however little of it is
  cut, as on Android.
- Latency presentation preserves a bounded one-frame jitter reserve instead of discarding paired arrivals. Metal's
  shown FPS now uses actual drawable presentation feedback, not selection or submission; CPU submission and GPU
  deadlines are reported separately. Sustained 120 FPS on physical devices is not verified for this change.
- MetalFX Temporal selects better per-pixel motion matches around stationary text and rejects conflicting motion-layer
  history without averaging away existing rejection. Synthetic fixtures show less halo, background noise and old-glyph
  error than Spatial, but small text is not uniformly as clean. Temporal remains experimental; live quality is not verified.
- On iPad the Native resolution is the whole panel (2752x2064 on a 13" iPad Pro), no longer the area inside the status bar
  and the home indicator (2752x1960) with the panel as "Native fullscreen"; only an iPhone's notch or Dynamic Island
  gives a fullscreen variant.
- The stream menu no longer hides the supersampling level when a 2× that does not fit leaves the stream unsupersampled,
  so 1.33× can be chosen again.
- The Metal renderer decoded every frame on the core's receive thread, which also takes every packet from the network:
  1.5 to 7 ms a 1080p frame on an M6 Mac, of the 8.3 ms a 120 fps frame has. The decoder now has its own thread (both
  with Asynchronous decoding on and off) and the receive thread spends about 0.1 ms a frame, and the start codes of a
  frame are found with a vectorized search instead of a byte-by-byte loop. Whether it was what held the iPad Pro below
  120 fps is not verified on a device.
- MetalFX Temporal uses its history. Its reactive mask was about 1 at almost every pixel of a moving picture: the
  flow's confidence counted flat areas and straight edges as unsure, a coarse pyramid level that fine detail aliased in
  pushed the finer levels into wrong matches, and the luma check failed on the interpolation of fine detail. MetalFX
  therefore ignored the history and only upscaled each frame on its own, softer than MetalFX Spatial. The motion
  passes now take about a fifth less GPU time (one compute encoder, the luma pyramid in one pass). Not verified on a
  device.

- Balanced with FPS limit paced frames at the display's highest refresh rate while the PC was capped below the rate the
  display really runs (Low Power Mode, a 60 Hz mode); both now use the same rate.
- Down from the top navigation returns to the cover the focus went up from, not to the cover under the button.
- The library's row of covers, the filter sheet's chip rows and every other row and list that follows the focus glide
  smoothly: one spring that every step retargets and that keeps its speed, driven at up to 120 frames a second, instead of
  SwiftUI's animated scroll, which restarted from rest after a still frame at every step (a held arrow or quick presses hopped
  one cover per step). A focus step now redraws only the two items whose focus changed, not the whole row. Not verified on a
  device yet.
- Every scrolling row and list fades at the edges where content is cut off: only the edge with content behind
  it, growing with how much is hidden, without clipping a chip's text or a focused item's ring and glow (the library filter
  sheet on an iPhone had none).
- On iPad a game controller's input goes to DELOS alone (through GameController), never to UIKit as well: the D-pad could stop
  moving between the covers and up to the navigation, while the buttons still worked, until the side menu was opened and
  closed (owner's iPad with a DualSense). Not verified on a device yet.
- App settings no longer widen as they open: the banner's art, wider than the stage, made the whole screen 180 stage px wider
  the moment it arrived, so the top bar, the list, the panel and the hints jumped outwards and the clock was cut off.
- On iPad only the PC's cursor shows over a running stream: the iPad's own pointer is locked and hidden (the trackpad and mouse
  move the PC's cursor relatively, as on the Mac), or hidden by its style where iPadOS refuses the lock (Slide Over, Stage
  Manager windows). It comes back on the stream menu, the loader and the result overlay, after the stream and in the
  background; the Mac's lock also lets go while the loader is up.
- The last input is the current input again with a controller connected: a touch on the screen switches the hints and the
  back arrow to touch, and they stay so until a controller button or the stick is used. A controller connecting or becoming
  the system's current one no longer counts as an input, and the pointer moving over the window switches to the pointer
  hints on iPad.
- Moving the focus no longer jumps to the wrong row: the focus finder uses beams and weights, so Right on the
  library's filter button or at the end of the Artwork grid stays where it is instead of jumping to a button above or a cover
  below, and Up from every cover goes through the filter button to the navigation. A library without games, or one still
  loading, puts the focus on the top navigation instead of on nothing, and a focus that lost its item falls to the nearest one,
  not to a random one.
- A screen that is leaving no longer takes the next screen's controller commands and button hints away (Settings, the library
  and the other screens with their own commands lost L1 and R1, Y and the adjust hint after a screen change).
- On Apple TV the top navigation and the covers cannot take the focus behind an open filter sheet, value list or search, and
  the covers cannot behind a game menu; a tap on the side menu's panel no longer closes it.
- The filter button of the library blurs with the rest of the screen under the filter sheet; it stayed sharp beside the sheet.
- The library's filter sheet covers the top bar with its scrim: the brand, the navigation, the back arrow and the clock were left
  bright above the dimmed screen. The backdrop and the bar blur under it like the screen does.
- The hint bar is no longer blurred and dimmed under the side menu, a context menu or a dialog: it is above the
  scrim and the layers and stays crisp.
- The circles of the Devices, Start, Profile, Pair and Create screens are fixed: the focus ring is no longer grown twice
  (it was 40 px too wide, so the glow showed through its gap), the glow's middle stop keeps a third of its alpha instead of
  replacing it (it was twice as bright), the discs and the profile chip are Liquid Glass tinted with the whole fill alpha,
  and the circle row no longer adds 40 px of air above and below the circles (the heading sat too high).
- The Keyboard tile of the stream menu raises the system keyboard on the iPhone and the iPad again and keeps it up: the key
  window's return to the app no longer takes the keyboard's first responder back for the interface's arrow keys, which are
  given back when the keyboard goes down, a raise the system refuses is tried again and shown honestly on the tile, the
  keyboard goes away with the running stream, and the keys of a hardware keyboard are no longer typed twice into the PC
  while it is up. Not yet verified on the iPad.
- A hardware keyboard on the iPad (Magic Keyboard) no longer scrolls the library, Settings and the other lists on top of
  the focus: the arrow, Space, Page, Home and End keys are taken from UIKit's own keyboard scrolling and focus movement
  (priority key commands, `allowsKeyboardScrolling` off), a key the keyboard repeats by itself is not another press, and
  a held arrow scrolls every list in short steps. Not yet verified on the iPad.
- The Moonlight reference app starts on iOS and tvOS 27, which stop apps without the scene lifecycle.
- The DELOS app no longer stops at launch: it finds the OpenSSL framework it embeds.
