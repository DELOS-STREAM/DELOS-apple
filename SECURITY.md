# Security policy

## Supported versions

There is no release of DELOS for Apple yet. Reports against the current `main` are handled.

## Reporting a vulnerability

Report it privately through GitHub:
[Report a vulnerability](https://github.com/DELOS-STREAM/DELOS-apple/security/advisories/new) (repository → Security →
Advisories → Report a vulnerability). Do not open a public issue and do not post details in a discussion or a pull
request.

Include the commit, the device and system version, the host software and version, and the steps that show the problem.
Remove addresses, PC names and keys from logs.

DELOS is maintained by one person. A report is answered as soon as the maintainer can; there is no guaranteed response
time. A fix is published with a note in [CHANGELOG.md](CHANGELOG.md), and the reporter is credited unless they prefer
not to be.

## Scope

| In scope | Out of scope |
|---|---|
| This repository: the app, its packages and build files | The host software on the PC ([Vibepollo](https://github.com/Nonary/Vibepollo), [Apollo](https://github.com/ClassicOldSong/Apollo), [Sunshine](https://github.com/LizardByte/Sunshine)): report there |
| The streaming core fork [DELOS-STREAM/Delos-common-c](https://github.com/DELOS-STREAM/Delos-common-c) | DELOS for Android: report in [DELOS-STREAM/DELOS-android](https://github.com/DELOS-STREAM/DELOS-android/security/advisories/new) |

A problem inherited from Moonlight is in scope; it is also reported upstream.

## Security model

The security model of the finished app will match DELOS for Android
([SECURITY.md of DELOS-STREAM/DELOS-android](https://github.com/DELOS-STREAM/DELOS-android/blob/main/SECURITY.md#security-model)): pairing with a
PIN that is never sent, a pinned host certificate, encrypted input. It is documented here when the Apple implementation
exists and has been tested.
