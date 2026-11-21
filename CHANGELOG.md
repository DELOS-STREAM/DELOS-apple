# Changelog

All notable changes to DELOS for Apple are documented in this file.

The format is based on [Keep a Changelog 1.0.0](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html). The first version will be 0.1.0.

## [Unreleased]

### Added

- **Game info**: press Down on a game's cover, swipe it up or tap Game info to continue from the dashboard into a page
  about the game. The cover flies into a header with its logo or title, ratings, age rating, Play, App settings and your
  streaming time; below are the summary and story, screenshots and trailers, details, links and similar games.
  Animated covers, logos and backgrounds keep playing, and the background blurs deeper as you scroll.
  Back, Up from the header or pulling down at the top returns to the dashboard; choosing a similar game you own opens its info.
- **Steam trailers and screenshots**: games with Steam media use its trailers and full-size screenshots first.
  Trailers play inside DELOS without ads, including on Apple TV, and each gets its own preview frame rather than sharing
  one poster; a preview that cannot be made falls back to the game's screenshot. Games without Steam media use IGDB
  screenshots and, on iPhone, iPad and Mac, YouTube trailers that allow in-app playback. Nothing opens a browser or the YouTube app.
- **Screenshot and trailer viewer**: open a media tile for a full-screen picture with a glass dock, a timeline, play/pause,
  5 s back and forward, previous/next, mute and volume; screenshots show page dots instead.
  L1/R1 browse with a controller, while Left/Right on a video's timeline seek and Down reaches the playback buttons.
  Swipe sideways with a finger, or with two fingers on an iPad trackpad, to bring the next item in; double-tap either side
  to seek 5 s, with repeated seeks adding to the on-screen total. A tap shows or hides the dock, which hides after
  3 s while playing but stays while paused or a slider is being dragged; hidden controls leave YouTube's own ad buttons usable.
- **Neural upscaling**: on OS 26 or later, the Neural mode uses Apple's machine-learning video scaler to reconstruct detail,
  then MetalFX Spatial enlarges the rest to the screen. It accepts supported 8-bit SDR stream sizes; HDR, 10-bit and
  larger streams use Spatial, as do the first moments while the model loads. Debug diagnostics include the Neural processing time.
- **PC discovery and pairing**: find PCs on the local network or add one by address, then pair with a PIN or a one-time
  code and passphrase from the PC's web interface. The library lists the paired PC's apps and cached box art, and subsequent
  connections trust that PC's certificate. The Devices screen lets you connect, choose a default PC, rename, wake,
  unpair or remove it; the default PC is kept per profile and focused first on the start screen.
- **Wake and connect**: connecting to a sleeping PC opens a progress portal, sends Wake-on-LAN when its address is known
  and waits for the PC to answer. Without the information needed to wake it, the portal asks you to turn it on yourself;
  B, a tap or a click cancels, and a PC that stays offline ends with an explanation. Real Wake-on-LAN and a real sleeping PC are not verified.
- **Profiles and first run**: create a named profile with one of sixteen avatars, then switch, rename or delete profiles
  from the profile menu. Each profile keeps its own appearance, stream settings and default PC, and deleting one offers
  a 10 s Undo toast. The start screen shows the current profile and its greeting, while the profile chip opens the switching menu.
- **Settings and appearance**: set resolution, frame rate, bitrate, codec and PC audio in the Stream and Audio tabs.
  Appearance offers dark and light themes, eight palettes, eleven animated backgrounds, reduced motion, clock format
  and interface scale; sound and haptics have their own controls. Changes apply immediately and are kept per profile,
  while the status bar shows the connected PC, Wi-Fi, battery, charging state and clock.
- **Game metadata**: when a metadata service is configured, the library shows HDR support, HowLongToBeat times and
  genre and theme badges in the game's colors, with Steam tags preferred where available.
  A game's Metadata menu lets you search, change its match, refresh or reset it, and About lists the data providers;
  built-in DELOS entries are excluded. Game details are cached for seven days, and without a configured service the
  app makes no metadata requests; live provider lookups are not verified.
- **Library filter**: Y, the keyboard's F or the Filter hint opens genre, theme, HDR and duration choices, including
  the number of games in each group. Choose several values in a row to match any of them, while all selected rows must
  match, then confirm with Show N apps; B closes without applying and Reset clears the choices.
  Filters are kept per PC, the hint counts selected values, and an empty result offers a reset.
  Physical-device and Apple TV presentation are not verified.
- **Artwork selection**: a game's Artwork screen lets you choose its cover, wide cover, background and logo from
  SteamGridDB's still and animated images, narrow the choices with filters, or search and match another game.
  Your choices survive automatic refreshes, and the library can use the game's colors, background and logo alongside
  its streaming time, Running and Last played badges. Desktop, Remote Input, Remote Monitor and Steam Big Picture
  have bundled artwork and are not looked up on SteamGridDB; their Artwork screen explains why it cannot be changed.
- **Animated artwork**: WebP, GIF and APNG covers, logos and backgrounds play in the library, game info and Artwork
  choices, with a download bar while an animation loads. Playback pauses off screen, under covering screens, in the
  background and with reduced motion; a game's background starts after focus settles and loops with a crossfade.
  Large artwork downloads go straight to disk, with support for files and a cache up to 2 GB.
  Physical-device playback and its cost are not verified.
- **Per-game settings and hidden apps**: App settings in a game's menu override resolution, frame rate, bitrate, codec,
  frame pacing and host audio for that app and profile, with CUSTOM labels, Reset all and Undo.
  Hide app and Show app keep library visibility per profile and PC, and Show hidden apps in the side menu reveals them
  with an eye-slash badge. Future streams use the game's overrides without changing the rest of the library.
- **Native Mac app**: DELOS runs in a resizable, full-screen-capable window on macOS 15 or later, with the same library,
  settings and profiles, a mouse back button and the Mac's battery in the status bar.
  During a stream, the keyboard, relative mouse and controllers go to the PC; holding Escape or pressing
  Control + Option + Shift + M opens the menu and frees the pointer. Quit, Command-Q and closing the window disconnect
  the stream first; real Mac streaming is not verified.
- **Apple TV controls**: the Siri Remote and game controllers navigate the app through the system focus engine,
  with Menu for Back and Play/Pause for context menus and the stream menu. Screens respect title-safe margins and
  readable text sizes, use system keyboard fields and keep artwork matches in their caches.
- **Mouse and trackpad in the interface**: hover focuses the item under the pointer without scrolling it into view,
  a click activates it, and a right click or two-finger click opens its menu; Mac also accepts Control-click.
  Lists and the library row scroll with the wheel or trackpad and retain momentum, and the hints show the last-used
  pointer's controls. On iPad, scrolling down over a focused cover opens game info, while upward and sideways scrolling
  remain available to the library; wheel-to-open and trackpad media browsing are not implemented on Mac.
- **Hardware keyboard**: the hint bar shows keys for every shell action, including arrows, Return, Escape, Tab for the
  side menu, O for a context menu, F for filtering or search, and [ / ] for tabs.
  Held directions repeat, while text fields and Command, Control or Option shortcuts remain available to the system.
  During a stream, Control + Alt + Shift with Z releases or grabs input, Q disconnects and C toggles the local pointer,
  with Command accepted instead of Control; right Option can act as the Windows key and mouse navigation buttons as X1/X2.
- **Full on-screen keyboard**: the stream menu's Keyboard tile opens a full keyboard on every device.
  Touch and pointer users can press several keys together; controllers move the focus with the D-pad or stick, use
  A to press, B to close, L3 for Shift, X for Backspace and Y for Space, while Apple TV accepts the Siri Remote.
  Sticky modifiers, Caps Lock, character previews and the profile's keyboard size, alignment, opacity and vibration
  settings apply. Controllers type instead of playing while it is open, and iPhone and iPad also offer the system
  keyboard under More → Open system keyboard.
- **Touch modes and Apple Pencil**: iPhone and iPad offer Multi touch, Mouse, Mouse with swapped buttons, Trackpad natural,
  Trackpad gaming and touch off, with the corresponding drag, scroll, acceleration and sensitivity options.
  Three-, four- and five-finger taps open the system keyboard, full keyboard and stream menu.
  The stream menu can change touch mode, pan and zoom the picture, and retain those choices when their Remember options
  are enabled; Apple Pencil can send pen pressure, tilt and hover or act as a mouse. These paths are not verified on a device or real PC.
- **On-screen game controls**: iPhone and iPad have a D-pad, face buttons, bumpers, triggers, sticks and menu buttons
  that accept multiple fingers and send input as controller 0.
  Use the gear to enable, move or resize controls, preview them in Settings → Controls, and toggle them or adjust opacity
  from the stream menu. They hide during controller use, support configured press vibration and controller-0 rumble
  on iPhone, and are not shown on Mac or Apple TV.
- **Controller features**: supported controllers send motion sensors, battery status and touchpad input to the PC and
  accept its light color, with gyro smoothing and optional iPhone or iPad sensors for player 1.
  Settings cover dead zone, face-button swaps, multiple controllers, touchpad-as-mouse and button combinations for
  controllers without Select or Guide; holding Start enables mouse emulation and a quick double Start opens the menu.
  Original, Soft, Kick-start and Pulsing rumble feels support live strength changes and optional device vibration,
  while DualSense feedback and trigger effects release unsupported resistance. Physical motion, light, touchpad,
  trigger and vibration behavior is not verified.
- **Controller Home button**: tapping Home opens the stream menu, while holding it sends Guide to the PC.
  Settings → Controls records an alternative menu combination, and iPhone and iPad can open the menu by swiping up
  from the bottom-edge band without sending that gesture to the game. On OS 27, a one-time notice explains when the
  system owns Home and links to the controller setting that lets DELOS use it; this is not verified on a device.
- **HDR and surround sound**: supported HDR displays and hardware decoders can request a 10-bit HDR stream through
  Settings → Stream or a game's App settings, including HEVC Main10 and AV1 Main 10 where available.
  Settings → Audio offers stereo, 5.1 and 7.1, with channels mapped to supported HDMI or AirPlay receivers and mixed down
  for fewer speakers. Streams also honor resolution scaling and the full-range video option; real HDR displays and
  surround receivers are not verified.
- **Metal renderer and upscaling**: an optional Metal renderer complements the default display-layer renderer, using
  VideoToolbox decoding, frame pacing and up to 120 Hz presentation.
  MetalFX Spatial, experimental MetalFX Temporal and Sharpen only offer contrast-adaptive sharpening and optional
  supersampling, with fallback to Sharpen only when MetalFX is unavailable.
  Spatial is the recommended default; Temporal targets noisy, low-bitrate streams and costs substantially more GPU work.
  The renderer can warn when upscaling cannot keep up; real-stream quality and GPU cost on devices are not verified.
- **Frame pacing and recovery**: Phase lock provides a low-latency choice alongside Balanced, Smoothest video and
  Balanced with FPS limit, with Balanced remaining the default.
  Warp Drive and Warp 2 request higher host frame rates rather than generating frames, and display settings control
  fit, fill, stretch and refresh-rate selection. HEVC and AV1 recover damaged references where possible, and a decoder
  that stops presenting while video still arrives requests a fresh frame; real-device pacing and recovery are not verified.
- **Launch and exit scenes**: connecting shows a hyperspace tunnel with the game's logo or title, stream format,
  connection steps and progress, then opens onto the live picture with a short arrival effect.
  B, Escape or Cancel stops only this client's attempt, even while the scene opens over the stream, and never quits
  the PC's game. Disconnecting or quitting shows an exit scene before the library returns, and reduced motion uses
  simpler fades; physical-device presentation is not verified.
- **Statistics overlays**: the stream menu's Overlay tile cycles through Off, the full panel and a compact top-center
  line, and the profile remembers its choice.
  The panel reports stream format, frame rates, bandwidth, network and host delay, missing frames, renderer and frame
  queue information, with additional latency, GPU and upscaling measurements where available.
  Unavailable measurements are omitted rather than estimated; live statistics on real streams are not verified.
- **Picture in Picture**: enable observer mode under Settings → Appearance on iPhone or iPad to keep a stream playing
  with sound in the system's Picture in Picture window when you leave DELOS.
  Held inputs are released and no input is sent to the PC while observing; restoring the window returns control, while
  closing it disconnects. Mac keeps streaming in its regular window and Apple TV has no automatic observer setting;
  physical-device behavior is not verified.
- **External displays**: Fully External Display Mode in Settings → Display moves a stream and its menu to an attached
  monitor or TV, or another Mac screen. The iPhone or iPad screen turns black and remains a touch surface for the stream;
  ending the stream brings it back, and unplugging the display disconnects. Real external-display behavior is not verified.
- **Link test and bitrate recommendation**: Settings → Stream offers Test link under bitrate to measure the PC
  connection with Vibepollo's network probe, with progress and B to cancel.
  Results are kept per PC and network type, and the bitrate help and App settings explain the recommendation.
  Nothing changes until you choose Use recommended bitrate; this is not verified against a real PC.
- **Live bitrate and clipboard support**: the streaming connection can request another bitrate from Vibepollo or Apollo
  and report whether the PC accepted it.
  Smart Clipboard Sync sends this device's clipboard at stream start and fetches the PC's on Disconnect, with feedback
  and a Hide clipboard content option. Dedicated stream-menu rows for bitrate changes and clipboard actions are not
  present, and these paths are not verified against a real PC.
- **Diagnostics and problem reports**: Settings → About can keep a rolling diagnostic log and show debug information
  about the device, displays and controllers, plus vibration tests and a rumble laboratory whose edits become a Custom feel.
  After a crash, hang or failed stream, a card offers to report it using a log cleaned of addresses, names, IDs and keys,
  then opens a prefilled GitHub draft; nothing is sent without you.
  Logs can be previewed, shared, copied, cleared or saved to Files on iPhone and iPad and Downloads on Mac, with upload
  when the build supplies a report service. Apple TV cannot save, share or copy the log or open the draft, and real-device reporting is not verified.
- **Links and shortcut files**: opening an `art://` link can pair a PC, open its library or start a game, and an `.art`
  shortcut can start its game. External requests ask for confirmation, wait for a sleeping PC and never quit another
  running game; unknown PCs or games get an explanation instead. Requests arriving before profile setup wait for it
  to finish, and physical-device handling is not verified.
- **App identity and languages**: DELOS has its own icon for iPhone, iPad, Mac and Apple TV, including dark and tinted
  variants where supported, and interface text in ten languages.
  iPhone and iPad offer a Language action in About that opens system Settings, while missing translations fall back to
  English. Controller hints use the complete Xbox, DualSense, DualShock 4 and Joy-Con symbols, and keyboard, mouse
  and trackpad hints have matching symbols; physical-device language switching and glyph rendering are not verified.
- **Development and troubleshooting tools**: debug builds record stream and animated-artwork performance in diagnostic
  logs so frame delivery, decoding, GPU work, thermal state and artwork playback can be investigated.
  An offline demo supplies sample games and artwork for simulator walkthroughs without touching real PCs, pairing or user data.
  The repository includes contribution, security and third-party records, commit checks and release-tag-only CI.
  Automated checks also cover missing translations, platform-specific wording, glass surfaces and documentation links.
- **Background progress**: artwork downloads and game-info lookups show a glass progress pill above the button hints,
  with the current task, completed count and progress bar. You can see what is still loading without leaving the library.
- **Streaming and stream menu**: starting or resuming an app opens a full-screen stream with controller, keyboard,
  mouse and touch input, and a failure offers Retry or a return to the library.
  The stream menu groups Resume, Disconnect, Quit and other actions in a glass dock, with additional pages and popovers
  for controls that need them. Opening the menu releases captured input, and closing it returns control to the game;
  real-stream behavior is not verified.

### Changed

- **Focus-first touch**: the first tap on an unfocused library cover selects it and shows its background and info;
  tapping the focused cover starts or resumes it. Settings rows likewise use the first tap for focus and help, with
  switches and choice arrows keeping their own actions. Pointer clicks still activate immediately because hover
  already focused the item; physical-device behavior is not verified.
- **Navigation and spacing**: Up and Down go to the first visible item of the new row rather than the nearest item,
  while returning to the library restores the cover you left.
  Artwork grids, avatars and search letters keep their column, and a missing or empty library leaves focus on the
  navigation rather than nowhere. Rings, glows and enlarged items keep clear of their neighbors, including wrapped
  tags, badges, links and filter rows.
- **Glass surfaces**: translucent panels, badges and pills blur what is behind them, including cover badges, search
  keys, popovers and stream-menu cards.
  Game info uses tinted surfaces where its background is already blurred, avoiding a separate glass blur on every chip.
  The viewer's dock remains real glass over screenshots and moving video.
- **Press, hover and motion**: taps, clicks and controller activation share one squeeze and feedback cue that starts
  as soon as you press, with no duplicate sound on Back or Cancel.
  Small pointer targets without a focus ring brighten and lift on hover, while other items take the normal ring.
  Covers have a light sweep, icons change between outline and fill, values and chevrons respond to changes, and reduced
  motion keeps the interface still or uses fades.
  Interface sounds follow media volume without changing an active stream's audio mode; hardware mixing and silent-switch behavior are not verified.
- **Game info motion** ([#27](https://github.com/DELOS-STREAM/DELOS-apple/issues/27)): the cover and page settle with
  gentler springs, with one positional overshoot instead of the cover's size stretching.
  Rating arcs ease past their final position once while the numbers count up without passing the score, and tags and
  age badges appear in sequence. Read the story fades the text at its expanding edge, and reduced motion replaces
  the flights with fades.
- **Game info background** ([#32](https://github.com/DELOS-STREAM/DELOS-apple/issues/32)): scrolling zooms and drifts the
  game's background and animated lines together while a deeper, darker and more saturated blur fades over them.
  Text shading stays in place, and media browsing keeps the game's background instead of swapping in full-screen
  media images. Returning to the top restores the original dashboard appearance.
- **Side menu**: its header shows the connected PC's live state and the profile's total streaming time and last stream.
  Dragging in from the left edge brings the menu, shade and blur with your finger; release far enough or flick to open,
  and drag left to close. On iPad and Apple TV the floating glass panel keeps equal safe-area gaps and enters from the
  left, while reduced motion uses simpler transitions; physical-device presentation is not verified.
- **Settings choices and search**: tapping a choice opens its complete value list, while a slider opens arrows, a
  draggable track and a value you can type; entered values are checked and kept within range.
  Settings remembers its last tab, long labels and help scroll when needed, and reduced motion leaves help manually scrollable.
  Search has its own screen, keeps results in Settings order and returns to the previously focused row when you go Back.
- **Display-shaped resolutions and upscaler sizes**: non-widescreen displays offer familiar resolution levels in the
  panel's own shape alongside 16:9, Native and Custom choices, so a stream can fill the display without black bars.
  On iPad, Native means the whole panel; iPhone keeps a separate fullscreen variant where its cutout requires one.
  Settings, App settings, the stream menu and statistics show the stream and upscaled sizes, and supersampling choices
  remain available even when the current level cannot fit.
- **Network and decoding settings**: metered bitrate applies on expensive networks and in Low Data Mode, with a lower
  default unless you set it yourself, and Wi-Fi keep-alive maintains traffic during a stream.
  Asynchronous decoding controls whether VideoToolbox decodes ahead, and fractional custom frame rates are sent to the
  PC exactly as selected. Physical-device and real-PC behavior is not verified.
- **Picture placement and text input**: Top center display places an unfitted picture at the top and keeps touch
  mapping aligned, whether you use Fit or Fill.
  Commit-text input sends system-keyboard text as text; turning it off sends individual US-layout key presses for
  games that expect them. These options are not verified on a device or real PC.
- **VoiceOver**: interactive items are announced as labeled buttons rather than stray icon characters, settings read
  their values and adjustable controls respond to VoiceOver swipes.
  Selected items announce selection, open menus and dialogs keep accessibility focus inside, and the escape gesture
  goes Back. Toasts announce their localized messages with error priority, without changing their appearance;
  physical-device VoiceOver delivery is not verified.
- **Compact layouts and long text**: narrow windows lay out the library top-down, keep another cover visible and move
  streaming-time information above badges when necessary.
  Profile names truncate before the status cluster, placeholder cover titles fit their space, and overflowing titles,
  badges, menu rows and values scroll with a faded edge rather than disappearing into an ellipsis.
  The problem-report card is wider and centered.
- **Clearer choices and wording**: familiar frame-pacing and codec choices come first, with Warp modes at the end and
  the GPU-impact badge using a chip symbol.
  System prompts, the Mac copyright and per-app CUSTOM labels are localized, and setting help describes the actual
  decoder and upscaler behavior. Stored legacy pacing and upscaler choices migrate to supported modes, and streams
  no longer ask GeForce Experience to optimize the game's settings.

### Removed

- **Settings that do not apply**: options without a working meaning on these devices have been removed, including
  orientation toggles, unused decoder controls, layout-dependent keyboard choices and unported virtual-key import/export.
  Supported on-screen controls remain available, and old Fast V-Sync selections become Balanced.
- **Redundant second-display choice**: the old Automatic, External display and Part of the device selector has been
  removed because it did not change behavior. Use Fully External Display Mode for a connected monitor or TV.
- **Legacy reference app and dependencies**: the old Moonlight reference app, its legacy interface and unused prebuilt
  media libraries and submodules have been removed. DELOS uses its current Swift app and streaming stack, with inherited
  per-push workflows and bot configuration removed in favor of release-tag-only CI.

### Fixed

- **Cover swipes and flights** ([#24](https://github.com/DELOS-STREAM/DELOS-apple/issues/24),
  [#25](https://github.com/DELOS-STREAM/DELOS-apple/issues/25)): horizontal finger drags scroll the library again, and
  a cover focused by a tap can immediately be swiped up. The cover follows a rubber band without being clipped, and
  opening or pulling game info closed continues from the finger's position, appearance and speed instead of jumping.
  The flight back lands on the resting card, with badges already in place and a held finger showing the pressed state.
- **Matching cover and media pictures** ([#28](https://github.com/DELOS-STREAM/DELOS-apple/issues/28)): opening game info
  keeps the card's actual picture in flight instead of briefly showing placeholder art while the portrait cover loads.
  Media tiles retain their picture proportions and parallax rim when entering or leaving the viewer, so they no longer
  grow at landing. A Steam trailer now starts with its tile's own still, and cached incoming pictures are available
  immediately instead of waiting for a task that could leave a black frame.
- **Viewer browsing stability**: finishing a swipe no longer commits a stale destination after another browse or
  a close, and further browse input waits until a committed slide lands.
  An iPad trackpad scroll locks its axis at the start, so a vertical scroll cannot suddenly jump sideways; cancellation
  returns the picture instead of browsing. Native-video snapshots render away from the main thread, and swipe movement,
  dock hints and synchronized background scrolling do less work in the surrounding interface; device smoothness is not verified.
- **Viewer dock and header** ([#28](https://github.com/DELOS-STREAM/DELOS-apple/issues/28)): the dock keeps round corners
  when changing between video and screenshot controls, and its focus ring is immediately on the selected control.
  Long galleries show a manageable window of page dots without overlaps, long trailer titles scroll while focused,
  and the timeline's white playhead stays visible.
  The top bar stays out of the full-screen viewer, duplicate back buttons are gone, and game info's remaining back
  button enters and leaves with the brand.
- **Trailer preview failures**: a trailer whose preview cannot be made is remembered for the rest of the app session,
  rather than downloading the same stream segments whenever a carousel or viewer asks.
  Changing carousel items also clears the previous item's preview state, so a reused tile cannot display another trailer's still.
- **Neural fallback reliability**: failure to prepare or encode a Neural frame now continues through MetalFX Spatial
  rather than dropping frames and potentially freezing the picture.
  Eligibility checks are reused for an unchanged stream, abandoned model requests are skipped and temporary texture
  resources are regularly released. Hardware failure recovery and its performance are not verified on a device.
- **Game info focus and backdrop** ([#23](https://github.com/DELOS-STREAM/DELOS-apple/issues/23),
  [#32](https://github.com/DELOS-STREAM/DELOS-apple/issues/32)): the page's ring follows the real layout instead of
  drifting outward as the focused item grows, and it stays aligned when the row scrolls.
  The background no longer remains darkened or shrunk after returning from media, and both background layers use the
  same scroll position. Play's focus treatment appears with its button, while touch shows the swipe-up cue on the focused cover.
- **Touch and pointer distinction**: a finger tap on iPad no longer occasionally opens a context menu as though it
  were a secondary pointer click. Touch menus require a hold, the first cover tap selects it and pointer clicks still
  activate immediately. Hints and the back arrow follow the last actual input again, even with a controller connected.
- **Menu focus and layering**: a leaving screen no longer steals commands or hints from the next screen.
  On Apple TV, navigation and covers cannot take focus behind an open filter, value list, search or game menu, and
  tapping the side-menu panel does not close it. Filter sheets dim and blur the whole underlying screen and top bar,
  while the hint bar stays crisp above menus and dialogs; tapping outside the stream menu closes its popover first
  and never sends the tap to the game.
- **Popovers and entrances**: first opening a Settings, context-menu or stream-menu popover does less initial glass
  work, reducing the pauses observed in simulator checks.
  Screens and menu rows enter in their intended top-down order, with focus plates staying aligned rather than jumping
  after the text lands. Items arriving later appear in place, long value lists stay below the header and reduced
  motion avoids unnecessary movement; physical-device performance is not verified.
- **Artwork playback and downloads**: animated backgrounds avoid expensive per-frame image work and decode ahead,
  allowing the tested artwork to retain its intended pace in local benchmarks.
  Busy or temporarily unreachable SteamGridDB requests retry before failing, and removed images are hidden from
  artwork choices unless they are currently in use. Physical-device playback improvements are not verified.
- **Focus scrolling and keyboard navigation**: held directions retarget scrolling smoothly instead of repeatedly
  restarting it, and only the items whose focus changed need updating.
  Lists fade only at edges with hidden content, without cutting off focused rings or chip text, and Down from the top
  navigation restores the cover you came from. Directional focus stays within the intended row or column rather than
  jumping to unrelated items; real-device smoothness is not verified.
- **iPad controller and keyboard input**: controller directions are no longer also handled as system-interface input,
  which could leave the D-pad stuck in the library.
  Hardware keyboard arrows and scrolling keys no longer scroll lists independently of focus or count repeats twice.
  The system keyboard stays open when requested, returns interface keys when dismissed and does not duplicate
  hardware keystrokes at the PC; these fixes still need verification on a physical iPad.
- **Pointer capture during streaming**: iPad hides and, where the system allows it, locks its pointer so mouse and
  trackpad motion control the PC's cursor relatively.
  The pointer returns for menus, loading and result screens, after the stream and in the background; Mac also releases
  capture while loading. This keeps local interface actions separate from input sent to the game.
- **Layout consistency**: App settings no longer widens as its banner appears and pushes the status bar off screen.
  Circular controls keep correctly sized rings and glass, without doubled growth, excessive glow or extra row gaps.
  Search hides unrelated navigation, keeps the correct hints and restores the previous setting on Back.
- **Connection errors and retry**: pairing waits for the trusted paired state, and manual-address entry explains when
  a PC could not be added.
  Unpaired and offline libraries point to Devices, missing addresses and unavailable virtual displays get clear
  feedback, and Retry checks that the PC answers and still has the game before reconnecting.
  The start screen updates its initial focus as discovery changes, and the app includes the framework needed to start reliably.
- **Frame delivery and latency**: Phase lock no longer risks freezing a stream while releasing a frame for presentation.
  Decoding runs separately from network reception, and frame handling avoids unnecessary scanning so receiving packets
  is not held up by decoding. Metal statistics use actual presentation feedback and distinguish CPU and GPU deadlines,
  while the scheduler preserves a bounded jitter reserve. Sustained 120 fps and the effect on physical-device latency are not verified.
- **Frame-rate limits**: Balanced with FPS limit now paces against the refresh rate the display actually uses, including
  Low Power Mode or a lower-refresh display mode. The PC's cap and the presentation scheduler therefore use the same
  rate instead of disagreeing about how often a frame can be shown.
- **Temporal reconstruction**: MetalFX Temporal uses previous frames again instead of rejecting almost all history
  on moving video, with improved motion matching around text and conflicting layers.
  Optical flow is no longer reused a frame late under load, avoiding the drift that could cause.
  Synthetic tests show cleaner reconstruction on some noisy moving pictures, but small text is not uniformly as clean
  as Spatial; Temporal remains experimental and real-stream quality is not verified.
