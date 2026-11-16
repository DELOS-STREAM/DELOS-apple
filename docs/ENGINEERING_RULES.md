# Engineering rules

The permanent rules of DELOS are defined once, in the Android repository:
[docs/ENGINEERING_RULES.md of Meitoncz/DELOS](https://github.com/Meitoncz/DELOS/blob/main/docs/ENGINEERING_RULES.md).
They apply here unchanged: tests, security, history, binaries, claims, documentation, releases, commit messages and
branch names. This page lists only what is specific to the Apple port.

## Technology

| Use | Do not use in new code |
|---|---|
| Swift 6 language mode with strict concurrency, SwiftUI, Observation, SwiftData, async/await, Metal, VideoToolbox, AVFAudio, GameController, CryptoKit | Objective-C, storyboards and XIBs, UIKit view controllers (except the thin host of the video layer), Core Data, SDL2, FFmpeg |

The C streaming core [Meitoncz/Delos-common-c](https://github.com/Meitoncz/Delos-common-c) is the only C code of the
app and is shared with Android. It is changed in its own repository first, then pinned here.

## Minimum systems

iOS 18, iPadOS 18, tvOS 18, macOS 15.

## CI

The only workflow runs when a release tag (`vX.Y.Z` or `vX.Y.Z-rc.N`) is pushed. Nothing runs on a push or a pull
request, and no workflow is started by hand. The workflow (`.github/workflows/build.yml`) runs `tools/test.sh`: the
package tests, the app builds for the iOS and tvOS simulators and the repository checks.

## Commit messages and branch names

As in the Android repository: [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) with the types
and scopes of [tools/hooks/commit-msg](../tools/hooks/commit-msg), and
[Conventional Branch](https://conventionalbranch.org) names checked by
[tools/hooks/check-branch-name.sh](../tools/hooks/check-branch-name.sh). Enable the hooks once per clone with
`git config core.hooksPath tools/hooks`.

## Branches

`main` is the DELOS branch and the default. `master` mirrors
[moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) and receives no DELOS commits.
