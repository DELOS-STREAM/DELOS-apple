# Diagnostics: logging, crash capture and problem reports

## Purpose

DELOS keeps a small log of what it did, on the device, so a problem can be reported with facts. **Nothing leaves the device
unless the user starts it**: there is no analytics, no automatic upload, no account and no token. What the user can start is
**Report** (the cleaned log goes to the report service and a GitHub draft opens), **Save the log instead**, **Share** or
**Copy diagnostic summary**. Issue #71.

## What is logged

`DiagLog` (`DelosCore/DiagnosticsLog.swift`) writes to `Application Support/diagnostics/diag-0.log` and `diag-1.log`:

- Two files of at most 1 MiB each. When the current file would grow past that, the older one is deleted and the current one
  becomes the older one, so the log holds 1 to 2 MiB of the newest lines.
- INFO and above in a release build, DEBUG as well in a debug build. A line is
  `2026-11-10 12:34:56.789 I/Stream [main] message`, in the device's time zone; one message is cut at 8 KiB.
- `DiagLogWriter` does the disk work on a background queue. A call formats the line and offers it to a queue of 1024 lines; a
  full queue drops the line and a later line says how many were dropped. Nothing blocks the stream, the render or the input.
- **Switch:** Settings → About → Diagnostics → **Keep diagnostic logs** (on by default, device-wide, key `diag_logs_enabled` in
  the standard defaults). Off stops new lines and the crash file; what is on disk stays until Debug info clears it.

| Source | Tag | What |
|---|---|---|
| Process start | `App` | version, build type, build, pid |
| Streaming core | `Core` | the core's own log messages (connection stages, RTSP, errors), at most 60 a second |
| Stream session | `Stream` | started, negotiated video (codec, chroma, HDR, size, rate, bitrate), encryption, start failed or cancelled, stopped, the result of a failed stream, the PC closing it |
| Toasts | `Toast` | every warning and error toast |
| Displays | `Display` | each display at the start and whenever one connects, disconnects or changes mode: the system's name, role, size, scale, refresh rate |
| Problems and reports | `Problem`, `Report`, `Crash` | an offer, its handling, an upload's outcome (never the link or the text), an uncaught exception |

## What the scrubber removes

`LogScrubber` (`DelosData/DiagnosticsScrubber.swift`) runs over the whole text of every report, summary and draft address after
it is built; the file on disk stays raw (it is private to the app). It errs on the side of removing. Names and addresses get a
number, the same for the same value within one report (`<ip-1>`, `<pc-2>`).

| Rule | Replaced by |
|---|---|
| PC names (their own and the names given in DELOS), whole words, case-insensitive, at least 3 characters | `<pc-N>` |
| Addresses, host names and MAC addresses stored for the PCs | `<host>` |
| Profile names, the device's name; on the Mac the computer name and the user's short and full name | `<name>` |
| The client id, profile ids, PC ids | `<id>` |
| The SteamGridDB API key | `<secret>` |
| IPv4 and IPv6 addresses (zones, brackets, IPv4-mapped) | `<ip-N>` |
| MAC addresses | `<mac-N>` |
| URLs: user info removed, host replaced (public services such as steamgriddb.com and github.com kept), every query value replaced except small numbers, resolutions and booleans, fragment dropped | the same URL with placeholders |
| `key=value` / `key: value` for ids, tokens, secrets, passwords, PINs, authorization, serials and host names; `Bearer` / `Basic` credentials | `<redacted>` |
| Wi-Fi names (`SSID`, `BSSID`) | `<redacted>` |
| UUIDs, hexadecimal runs of 16 or more, tokens of 32 or more letters, digits, `-` and `_` | `<uuid>`, `<hex>`, `<token>` |
| User names in paths (`/Users/x`, `/home/x`, `C:\Users\x`), external volume names | `<user>`, `<volume>` |
| E-mail addresses; host names ending in `.local`, `.lan`, `.home`, `.internal`, `.ts.net`, … | `<email>`, `<host>` |

The values known only to this install are read when the report is built (`ScrubFacts` in `DelosUI/DiagnosticsModel.swift`), so a
PC added a minute ago is covered.

## The device block

`DeviceInfo` (`DelosData/DiagnosticsReport.swift`): DELOS version, build type and build number; the kind of device and its model
identifier; system name, version and build; chip and architecture; the Metal GPU's name; the main display's size, refresh rate
and scale; the kind of network (Wi-Fi, Ethernet, cellular; never its name); locale; the UTC offset (not the region); and a fixed
list of stream settings (codec, resolution, frame rate, bitrate, PyroWave chroma, HDR, frame pacing, variable refresh rate,
upscaler). No PC names, addresses, keys or game list.

## Debug info

Settings → About → MISC → **Debug info** (`DelosUI/DebugInfoScreen.swift`). The panel on the right (a dock under the list on a
compact stage) shows the focused row's description and its technical details.

| Section | Rows |
|---|---|
| Device | the system and its build, the Darwin kernel (full version line in the details), the model (identifier, chip, system build), the vibration motor |
| Displays | each display, main or external |
| Diagnostics | **Diagnostic log** (size and line count of exactly what Share sends; the panel previews the header, the device block and the newest 40 lines of the scrubbed text); **Report a problem** and **Save the log … instead** (only with the report service); **Share diagnostic log**; **Copy diagnostic summary** (device block and last 100 lines); **Clear diagnostic logs** (both files and the shared copy); **Stream encryption** of the last stream; **Trigger test crash** (debug builds only) |
| Device haptic capabilities, Vibration test, Rumble laboratory, Rumble patterns, Rumble advanced | the device's haptic engine and the rumble translation (`DelosUI/DebugRumbleLab.swift`); advanced edits are stored as the profile's **Custom** rumble feel, which the stream then uses |
| On-screen controls | the preview (iPhone and iPad) |
| Controllers | each connected controller (vendor, product category, motion sensors, vibration test) and continuous vibration on all of them |

Platform differences:

| | iPhone, iPad | Mac | Apple TV |
|---|---|---|---|
| Save the log | Files app, DELOS folder (the app's Documents) | Downloads | not possible |
| Share | share sheet | sharing picker | not possible (row dimmed) |
| Copy summary | pasteboard | pasteboard | not possible (row dimmed) |
| Open the GitHub draft | browser | browser | not possible |

A shared copy is written to `Caches/diagnostics/delos-diagnostic-<time>.txt`; the earlier one is removed first.

## Crash capture and the report offer

Markers in `Application Support/diagnostics` (`DelosCore/DiagnosticsCrash.swift`):

- `crash.txt` + `crash.marker`: an uncaught Objective-C exception (`NSSetUncaughtExceptionHandler`, chained) logs it, flushes the
  log and writes the name, reason, call stack and the last 200 log lines. A fatal signal (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT,
  SIGTRAP; a Swift runtime error traps with SIGTRAP) writes the signal and the raw stack with async-signal-safe calls only, on its
  own signal stack where the system has one, then restores the previous handler and raises the signal again. The marker is
  written last: a file without it is ignored. Frames are read back as `at <symbol> (<image>)`, Swift symbols demangled.
- `session.marker`: `foreground|background pid startedAt updatedAt`, updated when the app becomes active or leaves it.
- `exits.json`: MetricKit's crash and hang diagnostics of earlier runs (iPhone, iPad, Mac), at most 16, kept until offered.

Detection (`ProblemDetector`, `DelosData/DiagnosticsProblems.swift`), at the start and again when MetricKit delivers diagnostics:

| Case | Result |
|---|---|
| crash file | `CRASH`, summary `NSInvalidArgumentException: reason (at DelosUI.Foo.bar)` or `SIGSEGV (signal 11) (at …)` |
| MetricKit crash of another process | `NATIVE_CRASH` with the system's description (`EXC_BAD_ACCESS, signal 11 (SIGSEGV)`) |
| MetricKit crash of the crash file's process | the same crash, never a second offer |
| MetricKit hang | `HANG` (`hang of 2.5 s`) |
| Apple TV (no MetricKit): previous process ended in the foreground, no crash file | `UNCLEAN_EXIT` |
| several | one offer: crash, native crash, hang, unclean exit; the newest of a kind; all count as offered |
| older than 7 days | dropped |
| a failed stream | `STREAM_FAILED`, at most once per 30 minutes |

The ledger (`diag_problems_*` keys in the standard defaults) is written at detection, so a problem is never offered twice.

**The card** (`DelosUI/ProblemOfferCard.swift`): a Liquid Glass card, 936 stage px wide (48 px from the edges on a compact stage),
in the middle of the start and home screens, only with no layer, side menu or portal up. It shows what happened, the summary and a
note on what Report does. Focus starts on **Report this problem** (A, with the GitHub mark, `Symbols.reportIssue`); left and right
move to **Dismiss**; B dismisses; with the report service a second row saves the log instead. While it shows it takes the
controller's commands (the menu button still opens the side menu); touch reaches the screen under it. On Apple TV Report is offered
only with the report service.

**Report** (`ProblemOffers.report`): builds the scrubbed report with a Problem section (full stack), uploads it when the service is
configured (toast *Uploading the cleaned log…*), else or after a failed upload saves it, shows a toast that says where the log is
and why an upload failed (no connection, no answer in time, service busy, too large, not accepted), then after 0.9 s opens the
draft in the browser. Dismiss and Report both delete the crash files.

## The draft and the report service

The draft is `https://github.com/DELOS-STREAM/DELOS-apple/issues/new?template=app_report.yml` with `title`, `what-happened`,
`area` (`Other` or `Pairing/connection`), `device`, `build`, `stream-settings` and `logs` (`IssueURL`,
`DelosData/DiagnosticsIssue.swift`). Every free-text field passes the scrubber; the address stays under 6000 characters (`logs`
cut first, then `what-happened`, never inside an escape); the log link (`Diagnostic log: <link>` first) and the note on where the
log is are added after the scrubber and never cut. There is no `labels` parameter: the form sets `bug`, `from-app` and
`needs-triage` itself, so these labels must exist in the repository.

**Field-id contract:** `.github/ISSUE_TEMPLATE/app_report.yml` and the ids `what-happened`, `area`, `device`, `build`,
`stream-settings`, `logs` and the two `area` options are never renamed or removed; a field the app fills keeps its type; new fields
are optional. `IssueFormContractTests` checks this.

The report service is used only when the build sets `DELOS_REPORTS_URL` (Info.plist `DelosReportsURL`, see
`Config/Local.example.xcconfig`); empty means Report saves the file. `ReportUploader` (`DelosData/DiagnosticsUpload.swift`):

| Fact | Value |
|---|---|
| Request | `POST <service>/v1/reports`, `text/plain; charset=utf-8`, gzip; HTTPS only (loopback in debug builds); redirects not followed; 20 s without an answer, 30 s in all |
| Size | 128 KiB; a larger report keeps its header, device block and Problem section and loses its oldest log lines |
| Accepted answer | 201 with `{id, url, expires}` where `url` is exactly `<service>/r/<22-character id>` |
| Failures | offline, timeout, 429, 503 `daily_limit`, 413, other 5xx, other status, malformed answer: the log is saved instead |
| Kept | 30 days; anyone with the link can read it, so it is public once the issue is submitted |

## Code map

| Path (`Packages/DelosKit/Sources/`) | Role |
|---|---|
| `DelosCore/DiagnosticsLog.swift` | the log, its writer, `StreamLogLines` |
| `DelosCore/DiagnosticsCrash.swift` | crash file, session marker, exception and signal handlers |
| `DelosData/DiagnosticsScrubber.swift`, `DiagnosticsReport.swift` | scrubber, device block, report text |
| `DelosData/DiagnosticsProblems.swift`, `DiagnosticsMonitor.swift` | detection, ledger, MetricKit |
| `DelosData/DiagnosticsIssue.swift`, `DiagnosticsUpload.swift` | draft address, upload, the choice between upload and save |
| `DelosUI/DiagnosticsModel.swift` | start-up, device facts, export, toasts, `ProblemOffers` |
| `DelosUI/DebugInfoScreen.swift`, `DebugRumbleLab.swift`, `DiagnosticsRows.swift` | Debug info |
| `DelosUI/ProblemOfferCard.swift` | the card |

## Verification

Automated: `swift test` in `Packages/DelosKit` (`DiagnosticsLogTests`, `CrashFileTests`, `DiagnosticsScrubberTests`,
`DiagnosticsReportTests`, `ProblemDetectorTests`, `IssueURLTests`, `IssueFormContractTests`, `ReportUploadTests` against a
URLProtocol stand-in service, `RumbleLabTests`, `AboutRowsTests`).

On a device with a debug build: Debug info shows a size and the preview; Share, Copy and Clear work; Keep diagnostic logs off keeps
the size; **Trigger test crash** closes DELOS and the next start shows the card once; Report saves the file and opens the draft
(with `DELOS_REPORTS_URL`: uploads, and the draft starts with the link); a failed stream offers the card after Back to library.

### Not verified

- None of the above was run on a device or simulator: layout, focus and touch of Debug info and the card, the share sheet, saving
  to Files and Downloads, the browser draft, haptics and controllers.
- A real crash through the signal handler, MetricKit delivery, an upload to the deployed service, the form rendered on GitHub.
- The scrubber does not remove game titles, and names shorter than three characters are not recognised.
