# DELOS for Apple

DELOS is a controller-first game streaming client for [Vibepollo](https://github.com/Nonary/Vibepollo),
[Apollo](https://github.com/ClassicOldSong/Apollo) and [Sunshine](https://github.com/LizardByte/Sunshine). This repository
is the port to iPhone, iPad, Apple TV and Mac. The Android app lives in [Meitoncz/DELOS](https://github.com/Meitoncz/DELOS);
the website is [delos-stream.com](https://delos-stream.com).

> **Work in progress.** There is no DELOS build for Apple devices yet. The repository still contains the Moonlight for
> iOS/tvOS code it was forked from; that code is the reference for the new app and is removed once the new app streams on
> a device.

## Status

| Platform | Status |
|---|---|
| iPhone and iPad | In development |
| Apple TV | Planned after iPhone and iPad |
| Mac | Planned after Apple TV |

The work is tracked in the [issues](https://github.com/Meitoncz/DELOS-apple/issues) and their milestones.

## Technology

The new app is written in Swift 6 with SwiftUI, SwiftData, async/await and Metal. The streaming protocol comes from the C
core [Meitoncz/Delos-common-c](https://github.com/Meitoncz/Delos-common-c), which DELOS for Android uses too. The minimum
system versions are iOS 18, iPadOS 18, tvOS 18 and macOS 15.

## Lineage

DELOS for Apple is a fork of [Moonlight for iOS/tvOS](https://github.com/moonlight-stream/moonlight-ios). The `master`
branch mirrors that project; DELOS work happens on `main`.

## Contributing and security

- How to take part: [CONTRIBUTING.md](CONTRIBUTING.md)
- Reporting a vulnerability: [SECURITY.md](SECURITY.md)
- Third-party code and binaries: [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md)
- Changes: [CHANGELOG.md](CHANGELOG.md)

## License

DELOS is free software under the GNU General Public License v3.0: [LICENSE.txt](LICENSE.txt). It is free of charge.
