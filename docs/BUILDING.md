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

## Building and running

| Command | What it does |
|---|---|
| `open DELOS.xcodeproj` | Opens the app in Xcode; the scheme `DELOS` runs on iPhone, iPad and Apple TV |
| `sh tools/sim.sh iphone /tmp/shot.png` | Builds, installs and starts DELOS in the iPhone 18 Pro Max simulator and saves a screenshot (`ipad`, `tv` or a simulator UDID work too) |
| `sh tools/test.sh` | The package tests, the app build for the iOS and tvOS simulators and the repository checks |
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
