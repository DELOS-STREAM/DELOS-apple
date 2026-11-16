# Changelog

All notable changes to DELOS for Apple are documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). The first version will be 0.1.0.

## [Unreleased]

### Added

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
  and touch as a trackpad to the PC. L3 + R3 or a swipe up from the bottom edge opens a small stream menu (Resume,
  Disconnect, Quit app); a stream that fails shows Android's result screen with Try again. Not yet tried with a real
  stream.
- Settings, with the Stream and Audio tabs of DELOS for Android: the video resolution (the presets and the display's
  own), the frame rate (up to what the display shows), the bitrate, the video codec (only the ones the device decodes)
  and playing audio on the PC. Each profile keeps its own; streams use them. A tap on a choice opens the list of its
  values, a tap on a switch flips it, and the help of the tapped setting shows beside the list. The library and the
  profile screen show the top navigation (Settings, Profile), and the left menu button of a controller opens the side
  menu with All settings.
- Holding a direction on a controller or the keyboard repeats it, as on Android.

### Changed

- The repository is set up for DELOS: README, contribution and security policy, third-party record, commit and branch
  hooks. CI runs only for release tags.
- Streams no longer ask GeForce Experience to optimize the game's settings, as DELOS for Android.

### Removed

- The inherited Moonlight workflow that ran on every push and pull request, and the Moonlight bot configurations.

### Fixed

- The Moonlight reference app starts on iOS and tvOS 27, which stop apps without the scene lifecycle.
- The DELOS app no longer stops at launch: it finds the OpenSSL framework it embeds.
