# Building DELOS for Apple

## Requirements

| What | Version |
|---|---|
| macOS | 26 or newer, on Apple silicon |
| Xcode | 27.2 or newer, with the iOS and tvOS simulators and the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) |
| Python | 3, for the repository tools |

The repository path must not contain spaces.

## First setup

```sh
git clone --recurse-submodules https://github.com/Meitoncz/DELOS-apple.git
cd DELOS-apple
git config core.hooksPath tools/hooks
cp Config/Local.example.xcconfig Config/Local.xcconfig   # only for a real device: put your team id there
```

## Optional game metadata

Set `DELOS_METADATA_URL` only in the untracked `Config/Local.xcconfig`. Leave it empty to disable every metadata
request, including direct HowLongToBeat access. `Config/Shared.xcconfig` defaults it to empty, and `Config/Info.plist`
expands it as `DelosMetadataURL`; `MetadataConfiguration.bundled()` reads that key. No endpoint or provider credential
is in tracked configuration. An xcconfig treats `//` as a comment: write the URL as `https:/$()/host/path`, as shown in
`Config/Local.example.xcconfig`. HTTPS is required except for localhost, 127.0.0.1 and Android's 10.0.2.2 development
bridge. The endpoint must implement the DELOS metadata Worker's `/v1/igdb/games`, `/v1/pcgw/*` and `/v1/steam/tags`
routes. Provider credentials stay at the Worker; no new Apple Keychain item is needed.

This is a data-layer port only. No library screen starts metadata lookups yet. Its fixture tests use injected fake
transports/providers, never the configured endpoint or the owner's paired PC.

## Building and running

| Command | What it does |
|---|---|
| `open DELOS.xcodeproj` | Opens the app in Xcode; the scheme `DELOS` runs on iPhone, iPad, Apple TV and My Mac |
| `sh tools/sim.sh iphone /tmp/shot.png` | Builds, installs and starts DELOS in the iPhone 18 Pro Max simulator and saves a screenshot (`ipad`, `tv` or a simulator UDID work too) |
| `sh tools/mac.sh /tmp/shot.png` | Builds DELOS for this Mac (ad-hoc signed), starts it and saves a screenshot of its window (`sh tools/mac.sh build` only builds) |
| `sh tools/test.sh` | The package tests, the app build for the iOS and tvOS simulators and for the Mac, and the repository checks |
| `cd Packages/DelosKit && swift test` | Only the package tests, on the Mac |
| `python3 tools/l10n/import_android.py ../Delos` | Regenerates the String Catalog from a DELOS for Android checkout (after editing `tools/l10n/keys.txt`) |

Debug builds read launch arguments for screenshots of each background, theme and palette: `-DelosBackground <kind>`
(`aurora`, `tide`, `silk`, `contour`, `nebula`, `plasma`, `lava`, `caustics`, `bokeh`, `orbit` or `still`),
`-DelosTheme light`, `-DelosPalette <name>` (`delos`, `ember`, `rose`, `orchid`, `dusk`, `iris`, `graphite` or `mint`),
`-DelosScale <percent>` (the interface scale, 100 to 130), `-DelosClock <format>` (`system`, `h12` or `h24`),
`-DelosBattery <percent>` (a battery for the status bar, which a simulator lacks; `c` after the number: charging, such
as `40c`) and, once a profile exists, `-DelosSettings <tab>` (`stream`, `audio`, `controls` or `appearance`), which
opens Settings on that tab, focused on its first row or on `-DelosFocus <row id>` (Android's key, such as
`ui_palette`). With an
installed app:

```sh
xcrun simctl launch <UDID> io.github.meitoncz.delos.debug -DelosBackground nebula -DelosTheme light -DelosSettings appearance
```

The same arguments work on the Mac: `sh tools/mac.sh /tmp/shot.png 5 -DelosBackground nebula` ([below](#a-mac)).
Apple TV: `sh tools/sim.sh tv /tmp/shot.png` shows the start screen in the Apple TV 4K simulator. The simulator has no remote
input from `simctl`; a throwaway XCUITest bundle that calls `XCUIRemote.shared.press(.select)` and the like (and
`XCUIScreen.main.screenshot()`) drives the real focus engine, Menu and Play/Pause against the installed debug app.

## Project layout

The app target is thin: `App/` holds the entry point and is a folder-synchronized group, so a new file there needs no
change of `DELOS.xcodeproj`. Everything else lives in the Swift package `Packages/DelosKit`; see
[ARCHITECTURE.md](ARCHITECTURE.md). Build settings are in `Config/*.xcconfig`, not in the project file.

## A real device

A free Apple ID is enough: sign in to Xcode (Settings → Accounts), turn on Developer Mode on the device, put the team
id into `Config/Local.xcconfig` and run the `DELOS` scheme on the device. An app signed this way stops starting after
seven days and has to be installed again.

## A Mac

The scheme `DELOS` also runs on My Mac (macOS 15 or later): choose the destination in Xcode, or run
`sh tools/mac.sh [/tmp/shot.png]`. The script builds into `/tmp/delos-dd-mac` without a team (an ad-hoc signature, no
Developer ID), turns the hardened runtime on, quits the copy it started before, starts the new one and saves a
screenshot of its window; `DELOS_PROFILE=<name>` first puts a profile into the app's container, because Settings and
the start screen need one:

```sh
DELOS_PROFILE=Player sh tools/mac.sh /tmp/mac.png 5 -DelosSettings stream -AppleLanguages "(en)"
```

The screenshot needs the Screen Recording permission of the terminal. The app is sandboxed: its preferences and caches
are in `~/Library/Containers/io.github.meitoncz.delos.debug`. An ad-hoc build gets a new signature identity at every
build, so the first read of the client identity after a rebuild can make macOS ask for the login password to let the
build use the keychain item (Always Allow); running from Xcode with the team of `Config/Local.xcconfig` keeps one
identity. The entitlements are in `Config/DELOS-macOS.entitlements` (sandbox, network client and server for the stream
and Bonjour); the ad-hoc copy adds `Config/DELOS-macOS-adhoc.entitlements`' library-validation exception, since an
ad-hoc signature has no team and the hardened runtime would not load the app's own `OpenSSL.framework`.
