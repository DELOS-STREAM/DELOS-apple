# Engineering rules

The permanent rules of DELOS are defined once, in the Android repository:
[docs/ENGINEERING_RULES.md of DELOS-STREAM/DELOS-android](https://github.com/DELOS-STREAM/DELOS-android/blob/main/docs/ENGINEERING_RULES.md).
They apply here unchanged: tests, security, history, binaries, claims, documentation, releases, commit messages and
branch names. This page lists only what is specific to the Apple port.

## Technology

| Use | Do not use in new code |
|---|---|
| Swift 6 language mode with strict concurrency, SwiftUI, Observation, SwiftData, async/await, Metal, VideoToolbox, AVFAudio, GameController, CryptoKit | Objective-C, storyboards and XIBs, UIKit view controllers (except the thin host of the video layer), Core Data, SDL2, FFmpeg |

The C streaming core [DELOS-STREAM/Delos-common-c](https://github.com/DELOS-STREAM/Delos-common-c) is the only C code of the
app and is shared with Android. It is changed in its own repository first, then pinned here.

## Minimum systems

iOS 18, iPadOS 18, tvOS 18, macOS 15.

## Focus never touches the neighbour

A focused item's ring, glow and lift never touch or overlap the next item, on every screen and every platform: cards,
carousels, covers, buttons, pills, chips, list and settings rows, menu items, the top navigation, filter chips, keyboard
keys and the stream menu's tiles. Between two focusable siblings, on the axis they are neighbours on:

$$\text{gap} \ge 2 \times \text{reach} + 8\ \text{px}$$

- **reach** is how far a focused item stands out beyond its layout edge on that side: its growth on that side
  (size × (scale − 1) / 2, or size × (scale − 1) for an item that grows from its far edge), then the band between it
  and its ring and the ring's width. A ring drawn inside the item's scale (`focusLook`) grows with it: its outset and
  width count × scale. Example: a 520 px thumbnail at 1.06 with a 4 px ring around the grown frame reaches
  520 × 0.03 + 4 = 19.6 px, so its neighbours keep 48 px.
- **twice**: the item that loses the focus and the one that gains it both show it while the focus moves.
- **8 px** of clear space always stays.
- **Dense key grids** (a letter picker, a keyboard) may instead not grow on focus and draw the ring inside the key
  (0–2 px in): their reach is 0 and 8 px between keys is enough.
- A soft glow that fades out (a blurred shadow) is not counted; a ring, a sweep band or any hard edge is.
- **Wrapped rows** use their group's named horizontal gap vertically too: tags, badges and links share one `WrapLayout`
  spacing on both axes. Filter rows retain that minimum clearance vertically; library sections also count their heading and
  chip padding, rather than adding the full gap again between sections.

Sizes that depend on text use the widest label of every language. The rule lives in code as `FocusSpacing`
(DelosUI); every gap it governs is a named constant that `FocusSpacingTests` checks against the ring geometry. A layout
that cannot keep the gap grows the gap or the container, never shrinks the item; a ring's outset shrinks only where the
design allows it.

## A new row starts at its first item

Moving the focus one row down or up, with a controller or the keyboard, lands on the first item of the new row (its
leftmost focusable), never on the one horizontally nearest. A row is the focusable items whose vertical centres lie
within the frame of the nearest item that way. `FocusGeometry.next` does it for every screen; the exceptions, approved
by the owner:

- **Back to the row you came from**: a restoring group (`FocusModel.restoreFocus`, the dashboard's covers) gives the
  focus back to the item it left.
- **A row scrolled sideways** starts at its leftmost item on screen, not at an item scrolled out of view.
- **The viewer's timeline**: Down from it lands on Play.
- **2-D grids** keep the column (`FocusModel.keepColumn`): the artwork picker, the avatars, the search letters and the
  keyboards.

Any other exception needs the owner's approval.

## CI

The only workflow runs when a release tag (`vX.Y.Z` or `vX.Y.Z-rc.N`) is pushed. Nothing runs on a push or a pull
request, and no workflow is started by hand. The workflow (`.github/workflows/build.yml`) runs `tools/test.sh`: the
package tests, the app builds for the iOS and tvOS simulators and for macOS, and the repository checks.

## Commit messages and branch names

As in the Android repository: [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) with the types
and scopes of [tools/hooks/commit-msg](../tools/hooks/commit-msg), and
[Conventional Branch](https://conventionalbranch.org) names checked by
[tools/hooks/check-branch-name.sh](../tools/hooks/check-branch-name.sh). Enable the hooks once per clone with
`git config core.hooksPath tools/hooks`.

## Branches

`main` is the DELOS branch and the default. `master` mirrors
[moonlight-stream/moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) and receives no DELOS commits.
