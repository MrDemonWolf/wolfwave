# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WolfWave is a native macOS menu bar app that bridges Apple Music with Twitch, Discord, and stream overlays. It tracks the currently playing song via ScriptingBridge and broadcasts it to Twitch chat via bot commands (EventSub + Helix API), shows "Listening to WolfWave" (with Apple Music album art) on Discord via Rich Presence, and streams now-playing data to overlays via WebSocket.

**Stack**: Swift 6.0, SwiftUI, AppKit, macOS 26.0+, Xcode 26+. Minimal dependencies (Sparkle for auto-updates); all other functionality uses native Apple frameworks.

**Monorepo**: bun workspaces + Turborepo. The root `package.json` defines workspaces (`apps/*`, `apps/marketing/*`) and Turbo orchestrates `dev`, `build`, and `clean` tasks across packages.

## Skills: use them, every time, by what you're editing

These skills are not optional extras. Invoke the matching skill **before and while editing** the relevant code. Pick by what the change touches:

| Editing | Use these skills |
|---|---|
| Native app (any `.swift` under `apps/native/`) | `swift` (language patterns, concurrency, idioms) **and** `macos` (SwiftUI, AppKit bridging, macOS 26 APIs). For UI/view changes also pull `design` (Liquid Glass, animation, visual patterns). |
| SwiftUI views specifically | `macos` + `design` + `swift`. Review against HIG before finalizing layout, color, control choices. |
| Web frontend (docs site, landing page, OBS widget: `apps/docs/`, `apps/widget/`, any React/TS/CSS/HTML) | `frontend-design` (distinctive, production-grade UI; avoids generic AI look). |
| Tests | `testing` (TDD, characterization, snapshot, test contracts). |
| App Store / release prep | `release-review`, `greenlight`, `app-store-review-audit` as relevant. |

**Research the Swift docs when needed.** When unsure about a Swift / SwiftUI / AppKit / Apple-framework API (signature, availability, behavior, the modern idiom), look it up before writing code. Prefer official Apple developer docs and the Swift language reference over guessing. The `swift` and `macos` skills point at the right patterns; confirm specifics against the docs rather than assuming. Never invent an API or default to a deprecated one.

Default stance: if a change lands in Swift/SwiftUI, the `swift` + `macos` skills are in play. If it lands in web frontend, `frontend-design` is in play. Use them as the work demands, not just when asked.

## Build & Development Commands

### Monorepo (bun + Turborepo)

```bash
bun install                              # Install all workspace dependencies
bun dev                                  # Start all dev servers via Turbo
bun run build                            # Build every workspace in dependency order
bun run clean                            # Clean workspace build artifacts
bun run tokens                           # Regenerate design tokens (root task //#tokens)
bun run ds:lint                          # Design-system lint (root task //#ds:lint)
bun run ds:schema                        # Validate tokens.json against tokens.schema.json
bun run ds:test                          # Design-system lint rules + opaque text contrast guards
bun run dev --filter docs                # Start docs dev server only
bun run --filter wolfwave-announcement studio  # Open Remotion studio only
bun run build --filter docs              # Build docs site
bun run --filter widget build            # Rebuild OBS widget (Tailwind → inline)
bun run --filter widget test             # OBS widget tests (bun test + happy-dom)
bun run --filter streamdeck build        # Bundle the Stream Deck plugin
bun run --filter streamdeck test         # Stream Deck plugin tests (bun test)
```

> **Stream Deck plugin**: `apps/streamdeck/` is the Elgato plugin consuming the
> app's control API. Unlike the widget, its bundle is **not** committed and is
> **not** shipped inside the app; it's distributed through Elgato. `src/wolfwave/`
> is the TypeScript mirror of `Services/WebSocket/StreamDeckCommand.swift`: the
> action tokens are the Swift enum's raw values and `PROTOCOL_VERSION` must equal
> `StreamDeckControl.protocolVersion`. **Change one side, change the other**, and
> bump the protocol version on any breaking envelope change. Protocol v3 uses a
> dedicated `wolfwave.control.<hex>` credential and fixed loopback transport; the
> OBS widget uses a separate read-only `wolfwave.overlay.<hex>` credential that
> can never authorize commands. The plugin bundle
> lives at `apps/streamdeck/com.mrdemonwolf.wolfwave.sdPlugin/` (`manifest.json`
> plus the `ui/` Property Inspector); `manifest.json` is a `streamdeck#build` turbo
> input and both it and the Property Inspector have their own tests. The panel can
> only check a token's shape; whether WolfWave accepted it reaches the panel through
> `src/connection-status.ts` (pure, so it is testable apart from `plugin.ts`, which
> connects at import time). The `streamdeck`
> CI job runs `typecheck`, `bun test`, `pack`, and an icon-drift check on any change
> under `apps/streamdeck/`, so a protocol mismatch fails the PR. Icons are generated
> from the brand mark by `scripts/generate-icons.ts`; regenerate rather than hand-editing
> them, or the drift check fails. See `apps/native/docs/streamdeck-control-api.md`
> and `apps/streamdeck/README.md`.

<!-- Separates the two blockquotes; a bare blank line between them trips markdownlint MD028. -->

> **OBS widget**: source lives at `apps/widget/`; the bundled
> `apps/native/WolfWave/Resources/widget.html` is a **generated artifact**
> that is **committed** to the repo. Xcode does **not** rebuild it; the
> native build ships the committed file as-is, so contributors who only
> touch Swift never need `bun`. If you edit `apps/widget/`, run `make widget`
> (or `bun run --filter widget build`) with the pinned Bun from `package.json`
> `packageManager`: other Bun releases minify differently, so the drift check fails. If you edit design tokens or their
> generator, run `bun run tokens` first, or use the ordered root
> `bun run build`. Commit the regenerated `widget.html` (and any token
> outputs) with the source change. CI regenerates both layers and fails the
> PR on drift. The widget has its own suite (`bun run --filter widget test`,
> `apps/widget/tests/`, bun test + happy-dom), which the CI `test` job also runs.
> See `apps/widget/README.md` and the
> [OBS Widget Architecture](apps/docs/content/docs/widget.mdx) docs page.

### Native App (Make)

```bash
make build          # Debug build via xcodebuild
make clean          # Clean build artifacts
make clean-dev      # Reset WolfWave Dev to a fresh first run: quit, wipe its defaults + Keychain, clean, remove /Applications copy (never the prod app)
make test           # Run unit tests (prints total tests, failures, and the Swift Testing count)
make test-verbose   # Run unit tests with full xcodebuild output
make test-ui        # Run the XCUITest suite (launches and drives the real app)
make test-ci        # Run unit tests in CI mode (writes TestResults.xcresult)
make update-deps    # Resolve SwiftPM dependencies
make open-xcode     # Open Xcode project
make ci             # CI-friendly build (alias for test-ci)
make widget         # Rebuild the OBS widget into Resources/widget.html
make icons          # Regenerate the Debug app icon (AppIcon.icon -> AppIcon-Dev.icon)
make check-drift    # Regenerate widget/tokens/SponsorConfig/app icon and fail on drift (mirrors CI)
make sponsor-config # Regenerate SponsorConfig.generated.swift from FUNDING.yml
make prod-build     # Release build → DMG in builds/
make prod-install   # Release build → install to /Applications
make notarize       # Notarize the DMG (requires Developer ID + env vars)
make verify-notarize # Verify the stapled ticket (stapler validate) and Gatekeeper acceptance (spctl)

# Lint. Four validation targets run as blocking CI jobs; lint-baseline is maintenance-only.
# CI also runs the separate blocking ds-lint design-system job.
make lint           # SwiftLint against swiftlint-baseline.json
make lint-baseline  # Regenerate that baseline (ratchet: it may only shrink)
make lint-crash-safety # No new force_unwrapping / force_try / force_cast
make lint-headers   # Swift file-header convention check
make lint-sync      # Source-derived lists, component catalog, docs values (incl. ports), lint claims, plus the release-notes and version script tests
```

`sponsor-config` is a prerequisite of `build`, every `test*` target, and `prod-build`, so
it normally runs on its own. Invoke it directly only when regenerating after a
`FUNDING.yml` edit.

Xcode project is at `apps/native/WolfWave.xcodeproj` with scheme `WolfWave`. Build and run with Cmd+R in Xcode. The Debug action must resolve to `WolfWave Dev.app`, display as **WolfWave Dev**, and use bundle ID `com.mrdemonwolf.wolfwave.dev`; Release remains `WolfWave.app` / `com.mrdemonwolf.wolfwave`. Do not collapse those identities or point the Debug scheme runnable at the Release product.

Both configurations set `LSUIElement = NO`. Dock/menu visibility is controlled at runtime, including the early `.accessory` policy for menu-only launches. Do not hide the development app by changing its bundle to an agent app; Debug must exercise the same activation policy as Release. The hosted app-metadata test checks the packaged value.

Debug and Release also ship **different app icons**, so the two are distinguishable in the Dock, the app switcher, and Spotlight when both are installed. Both are Icon Composer bundles under `WolfWave/Resources/`:

| Config | `ASSETCATALOG_COMPILER_APPICON_NAME` | Bundle | Artwork |
|---|---|---|---|
| Debug | `AppIcon-Dev` | `AppIcon-Dev.icon` | brand blue + a bottom-centre `DEV` badge |
| Release | `AppIcon` | `AppIcon.icon` | brand blue |

The icon is **always the blue WolfWave icon**; the only thing Debug adds is the badge. `AppIcon.icon` is the hand-authored source of truth, and **`AppIcon-Dev.icon` is a generated artifact** derived from it by [`scripts/generate-app-icons.ts`](scripts/generate-app-icons.ts): same background fill, the same `logo` layer (light/dark `fill-specializations`, scale, group shadow and translucency all carried through verbatim), plus an `iconwolf-development-badge.svg` layer in its own group.

The badge follows the [iconwolf](https://github.com/mrdemonwolf/iconwolf) development-badge convention already shipping in ConPaws (`apps/native/assets/images/ConPaws-development.icon`): a fixed bottom-centre pill at `304,724,416x176,rx44`, lettering drawn as a grid of 16pt squares from a 5x7 pixel font. Two rules that are easy to undo by accident:

- **The lettering is rectangles, not SVG `<text>`.** A text node depends on a font being installed and resolving identically wherever the icon is compiled; rectangles render the same everywhere. Adding a letter means adding a glyph to `GLYPHS`.
- **The badge group is emitted first.** Icon Composer draws the first group on top, and the wolf fills the canvas, so a badge appended last renders behind the mark with the lettering struck through by the waveform leg.

Generation is pure string assembly with no rasterisation, so the output is byte-identical on every host and CI can diff it.

**Do not hand-edit `AppIcon-Dev.icon`.** When the mark changes, update `AppIcon.icon/Assets/logo.svg` and run `make icons`. `Resources/` is a `PBXFileSystemSynchronizedRootGroup`, so a new `.icon` bundle is picked up without editing the project file.

About uses named Any/Dark image assets exported from those same Icon Composer sources, so its artwork follows the app appearance independently of the Dock icon style. After changing either icon, run `bash scripts/generate-about-icons.sh` on a Mac with full Xcode selected and commit the four rendered PNGs. Keep this explicit renderer step separate from the portable `make icons` drift check; rendering depends on the installed Icon Composer version.

All `make test*` targets use the ignored `DerivedData/Tests` directory. This keeps test-host build products separate from the signed Debug app in Xcode's normal DerivedData. Test hosts also default `KeychainService` to process-local storage before any suite setup, so tests must never read, write, or prompt for the user's real dev Keychain.

## Build Configuration

`Config.xcconfig` holds `TWITCH_CLIENT_ID`, `DISCORD_CLIENT_ID`, `GITHUB_REPO_OWNER`, `GITHUB_REPO_NAME` and is **not committed** (gitignored). Copy from `Config.xcconfig.example` and fill in your keys. Values are expanded into `Info.plist` at build time.

> URL values must escape `//` with `$()` (e.g. `DOCS_URL = https:/$()/...`). xcconfig treats a bare `//` as a comment and silently truncates the value to `https:`, which breaks every derived in-app link (docs, privacy, acknowledgements, community Discord).

### Worktrees: copy the local Config.xcconfig

`Config.xcconfig` is gitignored, so a fresh git worktree under `.claude/worktrees/` won't have one and the native app can't build there. **When working in a worktree and `apps/native/WolfWave/Config.xcconfig` is missing, copy it from the primary checkout before building.** Find it via `git worktree list` (first entry is the main worktree) and copy that worktree's `apps/native/WolfWave/Config.xcconfig` into the current one. Only copy an existing real config; never synthesize one from `Config.xcconfig.example` to unblock a build without asking.

#### Each worktree has its own DerivedData

Xcode derives the DerivedData directory name from the project's **path**, so every worktree gets its own `~/Library/Developer/Xcode/DerivedData/WolfWave-<hash>/`. Inspecting a build product without confirming which one you are in is a reliable way to verify the wrong thing: a stale `WolfWave Dev.app` from another worktree looks exactly like a change that failed to take effect. This produced a false negative while verifying the Debug app icon (PR #406) — the built app appeared unchanged because the `.app` being read was a week-old artifact from a different worktree.

Resolve the path from the build itself rather than guessing:

```bash
# The DerivedData dir for THIS worktree
xcodebuild -project apps/native/WolfWave.xcodeproj -scheme WolfWave -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}'
```

If several candidates exist, the newest build wins; `find ~/Library/Developer/Xcode/DerivedData -name 'WolfWave Dev.app' -maxdepth 6` plus the timestamp disambiguates. Also note `xcodebuild ... -quiet` (what `make build` uses) suppresses the error detail on failure, so rerun without `-quiet` when a build result looks wrong.

`Info.plist` also contains `SUPublicEDKey` (Sparkle EdDSA public key) and `SUFeedURL` (appcast URL). These are committed and should not be modified unless rotating the Sparkle signing key.

### Entitlements: do NOT remove

`apps/native/WolfWave/WolfWave.entitlements` must keep **all** of the following keys for Music.app control to work under the App Sandbox. Removing any of them will silently break ScriptingBridge: distributed notifications still fire, but `value(forKey:)` reads return nil and the WebSocket broadcasts an empty `playback_state`. See PR #65 / PR #124 history for the regression that proved this the hard way.

| Key | Why it's required |
|---|---|
| `com.apple.security.automation.apple-events` (`true`) | Modern entitlement that lets the sandboxed app request the standard TCC Automation grant for any target. Required for the "WolfWave wants to control Music" prompt to ever appear. |
| `com.apple.security.temporary-exception.apple-events` → `["com.apple.Music"]` | Proven working entry from v1.x. Belt-and-suspenders for pre-existing TCC entries and older macOS revisions. |
| `com.apple.security.scripting-targets` → `com.apple.Music`: `["com.apple.Music"]` | The access-group name here is **not** a real Music.app sdef group, so this entry alone is a no-op; keep it but never rely on it as the only AppleEvents grant. |
| `com.apple.security.temporary-exception.sbpl` (Discord IPC socket regex) | Discord Rich Presence local Unix domain socket. The regex uses the canonical `/private/var/folders/...` path in **both** `WolfWave.entitlements` and `WolfWave.dev.entitlements`. |
| `com.apple.security.temporary-exception.files.absolute-path.read-write` → `/private/var/folders/` | Read-write reach into the per-user temp tree where Discord exposes its `discord-ipc-N` sockets (that dir has a random middle segment, so a path-prefix exception cannot be narrowed below `/private/var/folders/`). Treated as **load-bearing for Discord IPC, pending a removal-safety test**: a 2026-06 audit flagged it as broad, but removing it needs a real signed build plus a Discord-RPC `connect()` check across macOS versions first. Do **not** blind-delete. The dev entitlements file was corrected from `/var/folders/` to the canonical `/private/var/folders/` (the sandbox matches the resolved path, so the old `/var` form silently never matched). |
| `com.apple.security.keychain-access-groups` | Token storage. |
| `com.apple.developer.ubiquity-kvstore-identifier` (**injected at release signing, not in either committed plist**) | iCloud Key-Value Storage for the opt-in "Sync with iCloud" settings mirror (`SettingsSyncService`). Xcode refuses to build any target carrying this key without a provisioning profile that has the iCloud capability, so it lives in neither entitlements file. `scripts/codesign-app.sh` embeds the profile and adds the key only when the `PROVISIONING_PROFILE_B64` secret is set (Release + Nightly workflows pass it through). Until that secret exists the shipped build has no iCloud key, the toggle (default off) is harmless, and `NSUbiquitousKeyValueStore.synchronize()` returns `false`. Local dev builds can't exercise live sync; the unit suite uses an in-memory store. |
| `com.apple.security.files.user-selected.read-write` | Load-bearing for the Settings backup/restore export and import file pickers, and the log export file picker in the Advanced pane. Without it the sandbox blocks the open/save panels from accessing the user-selected destination. |

If you think one of the apple-events entitlements is redundant: it isn't. Don't remove it.

### `playerState` parsing: do NOT regress to `as? NSNumber`

`AppleMusicSource.checkCurrentTrack` reads Music.app's `playerState` via `SBApplication.value(forKey:)`. **Do not** narrow the parse back to a single `stateObj as? NSNumber` cast; that quietly collapses every other bridge result into `NOT_PLAYING`, which silently blanks the now-playing card, Discord Rich Presence, and the overlay while Music is actively playing. PR #134 fixed the nil-return case; PR #136 fixed the "non-nil but unexpected bridge type" case.

The current decision flow MUST be preserved:

| Layer | Rule |
|---|---|
| `extractPlayerState(_:)` | Tolerant FourCharCode extractor: accept `NSNumber`, `Int`, `UInt32`, `NSAppleEventDescriptor.typeCodeValue`, and 4-byte `String` (e.g. `"kPSP"`). Return nil only for genuinely unknown bridge types. |
| "Track loaded" set | `kPSP` (playing), `kPSp` (paused), `kPSF` (ffwd), `kPSR` (rewind). All four emit the track. **Pausing does not blank the UI** (deliberate: Discord/overlay should reflect the loaded track even while paused). Only `kPSS` (stopped) or empty `currentTrack` map to `NOT_PLAYING`. |
| Fallback emit | If `extractPlayerState` returns nil but `currentTrack.name` is non-empty, trust the track and emit. Log once via `state-parse-fallback` so unknown bridge types surface in Console without spam. |
| Diagnose log | When the parse + emit path resolves to `NOT_PLAYING` while Music is running, `diagnose-not-playing` log fires once with the raw value, bridge type, and currentTrack probe; keep it. Future regressions are invisible without it. |

If a future SDK introduces a new bridge type, **add a branch to `extractPlayerState`**; don't simplify the parser. Coverage is locked in by `AppleMusicSourceTests.testExtractPlayerState*` (7 cases).

### CrashReporter safety net: do NOT regress

`Core/CrashReporter.swift` installs the process-wide last-gasp crash handlers (`NSSetUncaughtExceptionHandler` plus `sigaction` for SIGABRT/ILL/SEGV/FPE/BUS/TRAP). It exists so a hard crash leaves a breadcrumb at `…/Application Support/WolfWave/State/last-crash.marker` before the process dies; the next launch reads it and the Advanced pane shows a one-time "Recovered from a crash" callout. `applicationWillFinishLaunching` installs it (gated off under XCTest). Keep these invariants:

| Rule | Why |
|---|---|
| The **signal handler** stays async-signal-safe (`man 7 signal-safety`): only `open`/`write`/`close`/`strlen`/`signal`/`raise` over the pre-baked malloc'd C path and the C label table. No Swift `String`/`Array` growth, no Foundation, no `Log`. | A signal can fire on any thread mid-allocation. Calling `malloc`, locks, or Foundation there deadlocks or double-faults. Rich work (backtrace, reason, `Log.flush()`) belongs only in the NSException handler, which runs in a normal runtime. |
| **SIGPIPE stays `SIG_IGN`**, never trapped or re-raised. | The app holds long-lived sockets (Discord IPC, WebSocket). A peer dropping mid-write raises SIGPIPE, and the socket code already handles `errno == EPIPE`. A re-raising handler would turn that handled case into a crash. |
| Both handlers **chain**: the exception path calls the previous handler; the signal path captures each prior `sigaction` at install and restores it (falling back to `SIG_DFL` only when none was set) before `raise`. Never `_exit` or swallow. | The OS crash report and MetricKit `MXCrashDiagnostic` (consumed by `DiagnosticsService`) only fire if the crash reaches the default disposition, and the debugger / Swift runtime backtracer install their own signal handlers that a bare `SIG_DFL` reset would drop. |
| The handler funcs and their file-scope globals stay `nonisolated` / `nonisolated(unsafe)`. | The module defaults to `MainActor` isolation, and a `@convention(c)` function cannot be actor-isolated. Marking them `MainActor` breaks the C-function-pointer conversion and won't compile. |
| An uncaught exception's marker **outlives the SIGABRT** that follows it: the exception path sets `crashReporterExceptionRecorded` only after its marker is on disk, and the signal handler checks it (a plain load, so still async-signal-safe) and skips its own write. Never reset it in production. | The chained default handler aborts, which raises SIGABRT, and the bare signal record used to truncate the richer marker (name, reason, backtrace). The flag is set after the write, so a signal that lands mid-write still records something. |

The crash-class lint gate is **blocking** on production source: `.swiftlint-crash-safety.yml` runs `force_unwrapping` / `force_try` / `force_cast` at error severity with `--strict` and no `continue-on-error` (CI job `lint-crash-safety`, local `make lint-crash-safety`). Do **not** add new force-unwraps, `try!`, or `as!` to `apps/native/WolfWave/`. The marker lifecycle is covered by `CrashReporterTests`; never raise a real signal or `NSException` in a test (it kills the xctest host).

## Architecture

**Pattern**: MVVM + Service-Oriented, with an NSApplicationDelegateAdaptor-based lifecycle.

### Core flow

`WolfWaveApp.swift` → AppDelegate manages the menu bar status item, initializes services (`AppleMusicSource`, `TwitchChatService`, `DiscordRPCService`, `SparkleUpdaterService`, `SongRequestService`), handles settings + onboarding window lifecycle, and wires song info callbacks into the Twitch and Discord services. AppDelegate is split into `AppDelegate+DockMenu.swift`, `AppDelegate+MenuBar.swift` + `AppDelegate+MenuSections.swift` (the menu's section builders), `AppDelegate+Services.swift` + `AppDelegate+Notifications.swift` (observers and handlers) + `AppDelegate+TwitchTokenValidation.swift`, `AppDelegate+StreamDeck.swift` (Stream Deck command router + state broadcasts), and `AppDelegate+Windows.swift`. The system tray menu is dynamic (rebuilt via `NSMenuDelegate` on each open) with now-playing info, quick toggles, hold/resume for the request queue, and conditional items. Its Twitch rows read an in-memory `TwitchMenuState`, never the Keychain (`menuNeedsUpdate` runs on the main thread while the menu is tracking); Clear Queue and Restart Integrations confirm before they run; and `MenuTitleFormatting` clamps long titles, keeping the full text in the tooltip.

### Source layout (`apps/native/WolfWave/`)

- **Core/** - `AppConstants.swift` split across per-namespace `extension` files: `AppConstants+Notifications.swift`, `AppConstants+Discord.swift`, `AppConstants+Twitch.swift`, `AppConstants+URLs.swift`, `AppConstants+UserDefaults.swift` (centralized config enums for keys, identifiers, timing, notification names; every key stays here) + `AppConstants+UserDefaultsExport.swift` (the backup / iCloud export rules and the account-linked and runtime-state key lists), the `AppDelegate+*` extensions, `KeychainService.swift` (macOS Security framework wrapper; Twitch access token, refresh token, resolved identity, and configured channel share one crash-atomic versioned record with copy-then-delete migration from legacy fields), `LogTailCursor.swift` (incremental log tailing: bounded priming, partial-line carry, re-prime on truncate/rotate), `Logger.swift` (structured logging; `LogCategory` is the ONLY accepted category type, there is no `String` overload, so a typo is a compile error; logfmt-style line `<ISO8601>  <LEVEL>  <Category>  <File.swift:line>  <message>[ key=value…]`, one invariant: a record starts with an ISO-8601 timestamp at column 0 and a line starting with whitespace is a continuation. Grammar + redaction rules in `apps/native/docs/logging-format.md`), `LogRecord.swift` (the pure, canonical **reader** for that format, used by the Debug log viewer, the diagnostics export, and external tooling. Do not hand-roll a second parser), `PowerStateMonitor.swift`, `NetworkInfoService.swift` (LAN IP cache), `StreamerMode.swift` (UI-only masking of sensitive values for on-camera safety; observable singleton read across settings views and the menu bar), `SongRequestItem.swift`, `BlocklistItem.swift`. Foundation utilities: `HTTPClient.swift` (shared async HTTP wrapper), `JSONCoders.swift` (shared `JSONEncoder`/`JSONDecoder`), `BugReportURL.swift` (pre-filled GitHub issue URL builder), `Bundle+InstallMethod.swift` (DMG vs Homebrew install detection), `Preferences.swift` / `FeatureFlags.swift` (typed `UserDefaults` accessors; strings/ints and bool toggles, so reads route through one place instead of scattered defaults calls), `DefaultsStore.swift` (the single `UserDefaults` instance every non-`@AppStorage` read and write goes through; resolves to an isolated suite under test so the hosted bundle can never edit the dev app's live domain, mirroring `KeychainService.backend`), `SharedFormatters.swift` / `ByteFormatting.swift` / `StringFormatting.swift` (shared date, byte, and string-truncation formatting; `SharedFormatters.httpDate` holds the cached RFC 9110 HTTP-date parsers; `String.truncatedForChat()` counts Unicode scalars, which is how Twitch measures its 500-character limit, and cuts on a `Character` boundary so an emoji is never split), `RetryAfter.swift` (the one `Retry-After` / server-delay parser: rejects non-finite, negative, or unparseable values and caps at 300 s; shared by Twitch OAuth, Helix redemptions, the chat rate limiter, and `ArtworkService`), `ThreadSafeStorage.swift` (`Atomic<Value>`, the `nonisolated @unchecked Sendable` + `NSLock` box used by actor→sync bridge seams like `DiscordRPCService.stateSnapshot` and the Twitch dispatcher flags). Also in Core/: `AppContainer.swift` (Application Support / temp directory resolution), `AppearanceController.swift` (app-wide `NSApp.appearance` override), `KeychainBackend.swift` (test-injectable storage behind `KeychainService`), `DiagnosticsService.swift` (opt-in MetricKit diagnostics + share card; turning it off deletes the stored payloads, and while it is on only the newest 50 from the last 30 days are kept), `MetricsService.swift`, `MenuStatusFormatter.swift`, `MenuTitleFormatting.swift` (pure: clamps a tray / Dock menu title to `maxTitleLength` characters with an ellipsis and hands back the full text for the tooltip), `TwitchMenuState.swift` (the in-memory slice of the stored Twitch account the menus need, a credential flag plus the channel name; `AppDelegate.refreshTwitchMenuState()` fills it off the main thread and only the newest refresh publishes, so `menuNeedsUpdate` never reads the Keychain), `ExternalLink.swift`, `Pasteboard.swift`, `ImageEncoding.swift`, `InlineMarkdown.swift`, `NotificationPayloads.swift`, `RecentTrack.swift`, `SponsorConfig.generated.swift`, `CrashReporter.swift` (process-wide last-gasp crash handlers; the marker now carries kind/signal/pid/version/build/epoch, pre-baked at install so the signal path stays async-signal-safe; an uncaught exception's marker outlives the SIGABRT that follows it, see the invariants above), `CrashMarker.swift` (parses that marker, plus the legacy shapes; read at launch and written into the log BEFORE the marker is cleared), `DiagnosticSnapshot.swift` (one environment block for the bug report and the export header; the Debug tab builds its own `DebugDiagnostics.Snapshot`. NOT `#if DEBUG` on purpose), `DiagnosticsBundle.swift` (composes the export: environment + crash + every rotated log, oldest first), `MusicProcess.swift` (resolves the running Music.app by pid so ScriptingBridge never relaunches a quit Music; see PR #392), `FreshInstallDefaults.swift` (day-one values written once per install at launch: fresh installs get them, existing installs get their old values pinned, so a new default never flips an upgrade; marker `freshInstallDefaultsVersion` is runtime state), `SettingsDeepLink.swift` (pure `wolfwave://settings/<pane>[/<section>]` parser; never fails, falls back to General) + `SettingsNavigation.swift` (`@MainActor @Observable` hand-off: `AppDelegate.navigateSettings(to:)` sets `pending`, `SettingsView` consumes it, so a link works with the window already open; replaced the old `selectedSettingsSection` UserDefaults hint), `UserFacingError.swift` (the `Sendable`, SwiftUI-free model every user-visible failure resolves to: `id`, `title`, `cause`, `fix`, `severity`, a docs anchor, and `ErrorAction` intents rather than closures, so a test can assert which fix was offered without rendering; shown by `ErrorCallout` for ambient state, `FieldValidationRow` for typed input, or an alert for a user-initiated action that failed), `UITestMode.swift` (the out-of-process test seam: `isUnderTestHarness` is what `DefaultsStore` and `KeychainService` branch on, so a UI test gets throwaway storage the same way the hosted unit bundle does; compiled out of Release, where `isActive` is a constant `false`), and the `Core/ListeningHistory/` subdir (`PlayLogStore`, `PlayRecord`, `LifetimeTally`, `DurationSanitizer` (clamps implausible track durations), `HistoryStoreSupport` (shared store filesystem + day-bucketing helpers)).
- **Monitors/** - Apple Music playback monitoring. `AppleMusicSource.swift` uses PID-targeted ScriptingBridge with a retained error delegate, distributed notifications, monotonic event deduplication, and 5s fallback polling throttled slower in low-power mode, and reports updates through `PlaybackSourceDelegate.swift`.
- **Services/Twitch/** - `TwitchChatService.swift` (actor-isolated EventSub WebSocket + Helix chat API, network path monitoring for reconnection, Twitch user ID redacted in logs; also dispatches `channel.channel_points_custom_reward_redemption.add` and qualifying `channel.bits.use` cheer events into the song-request pipeline), `TwitchChannelPointsService.swift` + `+Helpers` (Helix create / reconcile / fulfill / cancel for the WolfWave-managed "Request a Song" reward), `TwitchRedemptionResolutionOutbox.swift` + `+Queues` / `+Intake` / `+Persistence` (atomic disk-backed paid-event state: channel-point intake becomes a known fulfill/refund before Helix delivery, unknown startup intake refunds conservatively, and complete Bits boost/request actions replay until atomically acknowledged), `HelixClient.swift` (shared Helix API wrapper over `HTTPClient`: auth headers, body encode, status validation, Helix error mapping; used by `TwitchChatService` and `TwitchChannelPointsService`), `TwitchDeviceAuth.swift` (OAuth Device Code flow; token parsing in `+TokenParsing`) with `TwitchCredentialStore.swift` and `TwitchTokenRefresher.swift` beside it, `TwitchBootTokenValidationRunner.swift` (the app-lifetime token validation cadence and its bounded validate / refresh policy; moved out of `AppDelegate+Services.swift`). The chat-service actor is split across same-actor seam files: `TwitchChatService+Auth.swift`, `+Connection.swift`, `+EventSub.swift`, `+Redemptions.swift` (the redemption teardown gate + redemption helpers), `+RedemptionSubscriptions.swift`, `+RedemptionHandlers.swift`, `+RateLimiter.swift` (the nested Helix rate-limit actor), `+Sending.swift` (chat send, announcements, and the bounded retry queue), `+Types.swift` (nested types, EventSub dedup, connection-state hub), `+Wiring.swift`, `+ChannelLifecycle.swift`, `+APIRequests.swift`, `+WebSocket.swift` (socket management + keepalive watchdog), `+EventSubSubscriptions.swift`, `+EventSubDecisions.swift`, `+Polls.swift`, `+RedemptionResolution.swift`, and `+RedemptionTeardown.swift`. Stored properties stay in `TwitchChatService.swift`.
- **Services/Twitch/Commands/** - `BotCommand` protocol (`triggers`, `description`, `execute(message:) -> String?`), `AsyncBotCommand` for I/O-bound commands, `BotCommandContext`, `BotCommandDispatcher`. Concrete commands: `TrackInfoCommand` (drives `!song`, `!last`, and `!stats` via three configured instances), `InfoCommand` (`!wolfwave`, static reply styled by `WolfWaveReplyStyle`), `SongRequestCommand`, `QueueCommand`, `MyQueueCommand`, `SkipCommand`, `HoldCommand`, `ClearQueueCommand`, `VoteSkipCommand` (chat vote-to-skip), `SongListCommand` (`!playlist`). Streamer-authored commands run through `CustomBotCommand` (an `AsyncBotCommand` rebuilt per message from `CustomCommandStore`), backed by the `CustomCommand` model and the `CustomCommandRenderer` enum, which does variable substitution (`$user`/`$sender`, `$touser`, `$args`, `$1`–`$9`, `$song`, `$lastsong`) and `CommandPermission` gating (everyone/subscriber/vip/moderator/broadcaster). Each `CustomCommand` also carries a `ReplyDelivery` (reply / message / announce, decoded as `.reply` when absent from older storage); the dispatcher returns it in `CommandReply` and `TwitchChatService+EventSub` routes announce through `sendAnnouncement` (Helix `/chat/announcements`, never the `sendMessageOnce` 401→reauth path) with a reply fallback and an `AnnounceStatus` banner key. `CustomCommandStore.validationIssue(for:)` is the one place a draft is checked: it returns a `CustomCommandIssue?` (`CustomCommandIssue.swift`: empty trigger, spaces, bad alias, a duplicate that names the owning command, a built-in trigger or alias (`reservedTrigger`, checked against `BuiltInCommandCatalog`, which `BuiltInCommandCatalogTests` keeps in step with `registerDefaultCommands()`), empty reply, reply too long; each case knows which editor field owns it and carries its plain message), and `add` / `update` return `Bool`. A trigger or alias can't contain whitespace (chat matches only the first token of a message), so legacy storage with a spaced primary trigger is repaired on load (spaces removed, command turned off, or dropped if the name is taken) while import still refuses it. A stored or imported command that reuses a built-in trigger or alias is kept but turned off. A command that must refuse a caller before its cooldown is claimed adopts `PreflightCheckedCommand` (in `BotCommandDispatcher.swift`; `!sr` uses it for the audience gate and the "requests are off" reply): `preflightDenial(context:)` returns a `PreflightDenial` (`.silent` or `.reply`), and the reply is throttled on its own `<trigger>#denied` key, per viewer and channel-wide, so a refused viewer never starts the cooldown allowed viewers share. `StatsCommandFormat` supplies the `!stats` window formatting. `CooldownManager` enforces global + per-user cooldowns.
- **Services/SongRequest/** - `SongRequestService.swift` + `+SetupHealth` / `+PlaybackMonitoring` / `+QueueControl` / `+Playback` (request flow orchestrator; `processRequest(query:username:source:)` takes a `RequestSource` so chat commands, channel-point redemptions, and bit cheers share the same pipeline; opt-in approval screening (`isApprovalRequired`, `approve`/`decline`) holds every request in a pending state until the broadcaster acts; `skip()` returns a `SkipOutcome`, `started` / `drained` / `busy` / `retained`, so `SkipCommand` only says the queue is empty when it really drained), `SongRequestAccess.swift` (`RequestAudience` chat-command gate, with `RequestAudience.current(in:)` as the one reader of the stored audience, shared by the service and the `!sr` pre-cooldown check, `RequestSource`, `SongRequestPreset` one-tap configurations, `RedemptionStatus` for the settings re-auth banner, `SongRequestPriorityMode` + `SongRequestPriority` for the Sub/VIP perk), `SongRequestQueue.swift` (fair-share round-robin ordering with Sub/VIP priority applied within rounds, hold mode, Music.app-closed buffering, and a `boost(username:)` method for bit-cheer boosts), `SkipVoteManager.swift` + `+Configuration` / `+Types` (chat vote-to-skip sessions: chat tally or Twitch Polls), `SongSearchResolver.swift` + `LinkResolverService.swift` (MusicKit search / Apple Music link resolve, including slug-less `/<storefront>/song/<id>` links), `AppleMusicController.swift` + `+AppleScript` / `+Search` (main-thread NSAppleScript playback with structured failures, PID-addressed events, exact request matching, and guarded focus restoration), `AppleMusicLibraryService.swift` (MusicKit library add + WolfWave Requests playlist probe), `PlaylistVisibilityWait.swift` (bounded re-probe, every 2 s for about 40 s, until Music.app's local library sees the cloud-made requests playlist; used by the setup step and `runSetupHealthCheck(forceWait:)` so iCloud sync latency never reads as Sync Library being off), `SongBlocklist.swift` (`TrackTextNormalizer.artistCandidates(_:)` builds the match set for an artist entry: the whole credit, each credited name, and each run of adjacent names re-joined with its original separators, so a comma-named act such as "Tyler, The Creator" is blockable inside a collaboration).
- **Services/SettingsBackup/** - `SettingsBackup.swift` (payload model), `SettingsBackupCoder.swift` (pure encode/decode), `SettingsBackupService.swift` (`@MainActor` export/import orchestration), `SettingsSyncService.swift` (opt-in iCloud KVS mirror of that same payload under key `settings.v1`; whole-blob last-write-wins by `exportedAt`, never reconnects Twitch, `SettingsSyncStore` protocol is the test seam so a hosted test never touches real iCloud; `flush()` pushes a pending change immediately and `applicationWillTerminate` calls it, so a change made in the last couple of seconds still reaches iCloud). Credentials and resolved account IDs are excluded; the public Twitch channel name is the sole integration metadata. See `apps/docs/content/docs/backup.mdx`.
- **Services/Discord/** - `DiscordRPCService.swift` (Discord Rich Presence via local IPC Unix domain socket, auto-reconnect with backoff), split into `DiscordRPCService+IPC.swift` (connect), `+FrameIO.swift` (socket frame reads and writes), `+Presence.swift`, `+TempDirectory.swift` (Discord's `TMPDIR` lookup) and `DiscordPresenceBuilder.swift` (pure presence-payload construction).
- **Services/UpdateChecker/** - `SparkleUpdaterService.swift` (Sparkle framework wrapper for auto-updates, EdDSA-signed appcast verification, Homebrew install detection disables Sparkle, DEBUG mode allows manual check via bundled `dev-appcast.xml`), `UpdateChannel.swift` (`nonisolated` Stable/Nightly enum backing the dual-feed picker).
- **Services/WebSocket/** - `WebSocketServerService.swift` + `+Lifecycle` / `+Connections` / `+Broadcasting` (overlay broadcast plus role-separated authentication: read-only `wolfwave.overlay.<hex>` clients may connect from loopback or LAN, while command-capable `wolfwave.control.<hex>` clients are accepted only from literal loopback; parses Stream Deck control commands via an injected `onCommand` handler and pushes `queue_state` / `health` broadcasts; progress work exists only while enabled, overlay-visible, playing, and serving clients, and each fan-out encodes once), `StreamDeckCommand.swift` (pure `StreamDeckAction` / `StreamDeckCommand` / `CommandAck` + `StreamDeckControl.parse` protocol envelope decoder (versioned by `StreamDeckControl.protocolVersion`), see `apps/native/docs/streamdeck-control-api.md`; `overlay_toggle` changes card visibility without stopping the authenticated transport), `WidgetHTTPService.swift` + `+Connections` (static widget HTTP server; injects only the overlay token for literal loopback Host requests, returns those responses with `no-store`, and enforces `no-referrer` for every widget document; generated widget tokens are already build-inlined), `WebSocketAuthToken.swift` (separate per-install overlay/control token generation, persistence-first Keychain rotation, constant-time role matching, and literal-loopback classification).
- **Services/ListeningHistory/** - `ListeningHistoryService.swift` + `+Loading` (opt-in, on-device append-only NDJSON play log; records a track only after it crosses the half-length or 4-minute mark so skips don't count), `StatsAggregator.swift` (top artists / listening time / 7-day trend / listening-by-hour rollups powering History & Stats), `MonthlyWrap.swift` (per-month "wrapped"-style summary + share-card export), `HistoryFormatting.swift` (date/duration formatting helpers).
- **Services/Notifications/** - `NotificationService.swift` (opt-in macOS banners via `UNUserNotificationCenter`; song-change, skip-vote-started, and skip-vote-passed each reuse a stable per-type identifier so a new banner replaces the previous one of its kind instead of stacking. Skip-vote-started is silent; skip-vote-passed uses the default system sound. Static `make…Content` builders keep the text pure and unit-testable. Skip-vote events arrive via `SkipVoteManager.onVoteEvent`, gated in `AppDelegate.handleVoteEvent` on both `voteSkipEnabled` and the matching per-event toggle. The service is also the `UNUserNotificationCenterDelegate` (installed at launch) so banners still present while WolfWave is frontmost, and it owns the Twitch re-auth banner via `postTwitchReauthNeeded()`, which only posts when authorization is already granted - boot paths must never trigger the system permission prompt).
- **Services/** - `ArtworkService.swift` (iTunes Search artwork fetch + cache), `ArtworkImageLoader.swift` (retains the displayed cover while a replacement loads, rejects stale completions), `ArtworkTint.swift` (album-art representative-color sampler for the Monthly Wrap share card), `LaunchAtLoginService.swift`. (`DiagnosticsService.swift` now lives in Core/.)
- **Views/** - SwiftUI settings shell `SettingsView.swift` with `NavigationSplitView` sidebar. Per-section views decomposed into `GeneralSettingsView.swift`, `MusicMonitor/MusicMonitorSettingsView.swift`, `AppVisibility/AppVisibilitySettingsView.swift`, `WebSocket/WebSocketSettingsView.swift` (Stream Widgets: connection, browser source, appearance, then the raw feed) + `WebSocket/WebSocketServerCard.swift` (the Stream Widgets server switch, its where-it-can-be-reached summary, and the "Couldn't start" callout; the parent hands it the live `serverState`, so the header chip and the card can't disagree) + `WebSocket/WebSocketCustomOverlayCard.swift` (port, overlay token, and the two WebSocket addresses; a port field reverts an invalid entry and confirms a saved one through `FieldValidationRow`) + `WebSocket/WebSocketTokenEditorRow.swift` (the one credential editor both panes render, so overlay and control validation cannot drift), `StreamDeck/StreamDeckSettingsView.swift` (Stream Deck: the `streamDeckControlEnabled` capability switch, the control token, setup steps) + `StreamDeck/StreamDeckPaneStatus.swift` (the pure `nonisolated` header-chip resolver; the shared server outranks the command switch, because commands on a stopped server produce a key that silently does nothing, and Ready appears only for a server that is really `.listening`: Server off, Server error, Starting, Commands off, then Ready), `Twitch/TwitchSettingsView.swift` (+ `+SignedIn`), `Discord/DiscordSettingsView.swift` (+ `+Sections`; its "When the music isn't playing" card is two segmented pickers, **When you pause** and **When music stops**, over the unchanged `discordClearWhilePaused` / `discordShowIdleStatus` Bools via `DiscordNotPlayingChoice.swift`), `SongRequest/SongRequestSettingsView.swift` (cards in `+QueueAccess` / `+VoteSkip` / `+Redemptions` / `+PlaybackCommands` / `+Blocklist`) + `SongRequestQueueView.swift`, `Notifications/NotificationsSettingsView.swift`, `HistoryStats/HistoryStatsSettingsView.swift` (+ `+Dashboard` / `+Management`) + `StatsChartsView.swift` + `MonthlyWrapView.swift` (SwiftUI Charts powered, gated on the opt-in Listening History setting), `Appearance/AppearanceSettingsView.swift`, `SoftwareUpdate/SoftwareUpdateSettingsView.swift`, `About/AboutSettingsView.swift` + `AboutCopy.swift` (pure copy strings incl. the displayed copyright year), `Advanced/AdvancedSettingsView.swift` (+ `+LogActions` / `+Backup`) + `SettingsImportSheet.swift` + `DiagnosticsShareCardView.swift`. The shell uses `SettingsSidebarView.swift` for native navigation. `WolfWaveApp` observes retained open requests and uses its `openWindow` action directly; `SettingsWindowConfigurator` tags the actual window and acknowledges requests when it attaches. Existing windows are restored and fronted by exact identifier. Do not reintroduce a hidden helper window or timing-based notification relay. Per-pane supporting views: `Discord/DiscordPreviewCard.swift` + `DiscordButtonConfigRow.swift`, `MusicMonitor/MusicPermissionState.swift` + `PermissionDeniedView.swift`, `Twitch/TwitchCommandsCard.swift` + `CustomCommandsCard.swift` (stays editable while Twitch is disconnected; commands start replying once it connects) + `DeviceCodeView.swift` (takes `expiresAt` and `onRequestNewCode` for the countdown and "Get a new code"), `WebSocket/WidgetAppearancePreview.swift`, and `SongRequest/Setup/SongRequestSetupView.swift` (+ `+Steps`) + `SongRequestSetupViewModel.swift` (the guided setup gate). `TwitchViewModel` is the main observable for auth/connection state, with its user-facing error builders (`TwitchViewModel.Failure`) in `Twitch/TwitchFailure.swift`; `retryTarget(for:)` maps a failure to the work its Try Again button repeats (sign-in, sign-out, or join) and `deviceCodeExpiresAt` drives the code countdown.
- **Views/Onboarding/** - macOS 26 Liquid Glass onboarding wizard. The `OnboardingStep` enum (in `OnboardingViewModel.swift`) defines the 7-step order: Welcome → Permissions (Apple Music automation only; second because everything builds on it) → Discord (presence switch, live "Discord is open" check, Listen-buttons switch) → Twitch (sign-in, channel join, and the `!song` / `!last` switches) → OBS Widget (one "Stream overlay" switch drives the WebSocket + HTTP widget servers, then the overlay link) → Notifications (an Allow button, never a switch, + the song-change / skip-vote alert toggles) → Preferences (launch at login, history, iCloud sync; its button reads Finish), followed by `OnboardingCompletionView`. Permissions and Notifications are deliberately two separate screens so each has a single job. One file per step: `OnboardingWelcomeStepView`, `OnboardingPermissionsStepView`, `OnboardingDiscordStepView`, `OnboardingTwitchStepView`, `OnboardingOBSWidgetStepView`, `OnboardingNotificationsStepView`, `OnboardingPreferencesStepView`, all hosted by the `OnboardingView.swift` wizard container. Components in `Onboarding/Components/` (`PillButton`, `BrandTile`, `OnboardingStepScaffold` (top-aligned, so every title sits at the same Y), `OnboardingToggleCard`, `WolfHeroMark`, `MenuBarPointer`). The container shows a "Step N of 7 · Name" progress header and ONE primary button: it reads **Skip** while the Twitch sign-in or Music grant is undone, **Next** otherwise, **Finish** on the last step. Next takes Return except on the Twitch step, whose channel field owns it; Escape is Back (never anything that ends setup); **Skip setup** sits beside it. `OnboardingCompletionView` has two styles, `.completed` and `.skipped` (Skip setup, via `completeOnboarding(skipped:)`), shows the `MenuBarPointer` (the old Menu Bar step, now reached by every ending), a Done button bound to Return, auto-dismisses after `autoDismissDelay` (5 s), and never auto-dismisses while VoiceOver is running.
- **Views/Debug/** - **DEBUG-only** developer tooling tab. `DebugSettingsView.swift` shell plus cards: `DebugInspectorsCard`, `DebugLogViewerCard` (live tail of the log file: level/category filters, search, follow toggle, backed by `Core/LogTailCursor.swift` for incremental reads and `Core/LogRecord.swift` for parsing), `DebugLogsAndEventsCard`, `DebugMetricsCard`, `DebugServiceControlsCard`, `DebugUIPreviewsCard` (the What's New / onboarding / simulated-update triggers), over the `DebugDiagnostics.swift` snapshot helpers (Connections vs Preferences are separate tables on purpose: a preference being on is not evidence a service connected). `Debug/DesignSystem/` holds the design-system gallery: `DebugComponentGalleryCard` (+ one `ComponentGallery+<Group>.swift` extension per group) renders every `Views/Shared/` view in the states its `#Preview` blocks declare, and `DebugTokenGalleryCard` renders every token family by iterating the generated `DSColor.groups` / `DSFont.Size.all` / `DSSpace.all` / `DSRadius.all` / `DSMotion.Duration.all` / `DSMotion.Spring.all` / `DSOpacity.all` / `DSDimension.groups` lists, so it cannot drift from `tokens.json`; `MotionGallerySection` (the contentTransition / symbolEffect / input-driven progress / AsyncImage demos) lives there too. Debug renders only the selected tool, using a native grouped list when wide and a native menu picker when compact. Switching tools unmounts the previous card and cancels its polling task. `DebugSection.railGroups` and `DebugSectionCoverageTests` keep both navigation modes complete and ordered consistently; `DebugToolsUITests` checks replacement at minimum and ideal sizes. Copy Diagnostics uses `AsyncActionButton` and checks cancellation before writing the clipboard. Not compiled into release builds.
- **Views/Shared/** - Shared UI components: `StatusChip` (its glyph or dot is drawn through `DSColor.glyph(for:in:)`, defined beside it, which also serves `CalloutBanner` and the settings rail), `ToggleSettingRow`, `SuccessFeedbackRow`, `SectionHeaderWithStatus`, `CardEyebrowHeader`, `NowPlayingHeroCard`, `AlbumArtView`, `IntegrationDashboardView`, `CalloutBanner` (consolidated info/success/warning/error/neutral tinted callout that replaced the old `WarningBanner` / `ConfigRequiredBanner` / `ConnectionTestButton` variants), `ErrorCallout` (renders a `UserFacingError` as a `CalloutBanner` with its fix buttons beside it; actions arrive as `ErrorAction` intents, not closures, so the view model owns what a fix does and a test can assert which one was offered), `FieldValidationRow` (inline feedback directly under a text field: idle / validating / valid / invalid / failed; `.failed` shows the real reason inline instead of in a tooltip), `Binding+Sanitized` (`snapped(to:fallback:)` / `clamped(to:fallback:)`; wrap any `@AppStorage`-backed `Picker` selection or `Slider` value with these, because a persisted value outside the control's tags or bounds traps inside SwiftUI and takes the settings window down), `CopyButton` (`disabledHint`: the VoiceOver reason it is disabled), `CopyableURLRow` (`actionsDisabledReason`: the tooltip and VoiceOver hint for its disabled buttons; Streamer Mode always wins with its own fixed reason), `OpenInBrowserButton`, `SharePickerButton`, `DestructiveButton`, `DSIconButton`, `AsyncActionButton` (one button owning one `async` action: spinner replaces the label, control disabled while in flight, brief success checkmark, width pinned by `stableWidth` so no phase change resizes the row. Not for a button that fire-and-forgets a `Task`, and not usable inside `.alert` / `.confirmationDialog`, which only accept plain `Button`s), `WhatsNewView` (takes an `onClose` closure because `dismiss` does nothing in an AppKit-hosted window), `ActionGrid`, `LoadingRow`, `HintRow`, `MusicPermissionBanner`, `MusicPermissionRecheckButton` (the shared "Try again" for the Music Automation grant: awaits the recheck through `AsyncActionButton` and reports the actual result, not elapsed time), `StatTile`, `LabeledSlider`, `CooldownSliderPair`, `CommandAliasField`, `CommandSettingRow`, `ResponsiveRow`, `QRCodeImage`, `StreamerModeBadge`, `TwitchConnectionNotice`, `ViewModifiers` (incl. `.motionSafe(_:value:)` and `withMotionSafeAnimation(_:reduceMotion:_:)`, the one place Reduce Motion is honored for state-change motion), `SettingsPaneScroll` (the scrolling content column used by the shell's shared wrapper, General, Song Requests, and the selected Debug tool. It centers on the scroll view's own width, so the column lands at the same x whether or not the pane scrolls and whatever the scroll-bar style), `DeepLinkAnchor` (`.deepLinkSection("slug")`: the scroll target + accent-ring flash for a settings deep link; slugs are kebab-case, unique per pane, and listed in the Deep links table of `settings.mdx`, so add the new row there when you tag a card), `SettingsNavRail` (two-column jump-nav rail + scroll-sync retained for the component gallery and preview; no current settings pane uses the rail layout; sections conform `SettingsRailSection` and tag their top view with `.railSection(_:)`; panes that use it bypass `standardDetailScroll` in `SettingsView.detailPane` to own the full pane width; `SettingsRailGroup` is `Identifiable` so `ForEach` survives reordering, the rail width is `DSDimension.Settings.navRailWidth`, and the selected row carries the `.isSelected` trait). Sensitive fields wrap their value in a `StreamerMode.shared` check before rendering; when Streamer Mode is on, the value is replaced with a "hidden" placeholder ("hidden (streamer mode)" for URLs and tokens, from `StreamerMode.mask`) and Copy/Open buttons are disabled.

### Key patterns

- **Settings hierarchy**: The native window toolbar names the selected pane. Do not repeat that title in the content column. Keep section labels and helpful descriptions, and place status chips beside the controls they describe (for example, the server or connection row).

- **Credentials**: All tokens/secrets stored via `KeychainService` (never UserDefaults). Twitch access, refresh, username, user ID, and configured channel are one revisioned atomic grant; never split an account transition back into per-field writes. A channel restored from backup may exist in UserDefaults only as a pending, nonauthoritative hint until OAuth commits it with the account. Keys defined in `AppConstants.Keychain`.
- **Settings**: User preferences in `UserDefaults` via `@AppStorage`. Keys centralized in `AppConstants.UserDefaults`. Twitch and Discord defaults live in one place, `AppConstants.UserDefaults.Defaults`: every `@AppStorage` seed and every `Preferences.bool(_:default:)` read for those keys references it, so a pane and its service cannot disagree. A default that differs for **new** installs never changes what an unset key reads as (that would flip existing installs on update); it goes in `FreshInstallDefaults` instead, which writes explicit values once per install at launch: day-one values for a fresh install, the old values pinned for an existing one (onboarding finished or a Twitch channel saved). Today that is `!song` and `!last`: unset still reads `false`, fresh installs get `true`. `widgetHTTPEnabled` defaults to `false`. `streamDeckControlEnabled` is the one security-relevant capability that defaults to **`true`**, and must keep doing so: the capability shipped already gated by the control token, so defaulting it off would disarm every Stream Deck in the field on the first launch after an update. Read it through `FeatureFlags.streamDeckControlEnabled` (which passes the explicit default), never `defaults.bool`, which reports `false` for "never set".
- **Settings deep links**: `wolfwave://` is registered in `Info.plist` (`CFBundleURLTypes`) and lands in `AppDelegate.application(_:open:)`. Pane ids are `SettingsSection.slug`, never `rawValue` (that is the visible title). Section ids are the string passed to `.deepLinkSection`. One `ScrollViewReader` in `SettingsView` scrolls every pane, including the ones that own their own `ScrollView`.
- **Notifications**: Loose coupling via `NotificationCenter` (e.g., `TrackingSettingChanged`, `DockVisibilityChanged`). Names in `AppConstants.Notifications`.
- **Thread safety**: `TwitchChatService` uses actor isolation; its synchronous observation bridges use small lock-backed snapshots. `DiscordRPCService` is an actor; its blocking socket I/O runs on a serial `ipcQueue`, and synchronous readers use lock-backed `Atomic` snapshots. Logger uses a serial `DispatchQueue` for thread-safe file I/O.
- **Bot commands**: Register new commands in `BotCommandDispatcher.registerDefaultCommands()`. Each command implements `BotCommand` protocol. Max response 500 chars, target <100ms execution.
- **Discord IPC**: Unix domain socket at `$TMPDIR/discord-ipc-{0..9}`. SBPL entitlements enable socket access within App Sandbox.
- **ADHD-friendly text**: All user-facing text should be short, punchy, and jargon-free.

## Design System

Single source of truth: [`design-system/tokens.json`](design-system/tokens.json). The generator [`design-system/scripts/generate.ts`](design-system/scripts/generate.ts) emits four platform outputs; **do not edit generated files by hand**:

| Output | Path | Consumer |
|---|---|---|
| Swift | `apps/native/WolfWave/Core/DesignSystem/Tokens.generated.swift` | Native app: `DSColor`, `DSFont`, `DSSpace`, `DSOpacity`, `DSRadius`, `DSMotion`, `DSDimension` |
| CSS | `apps/docs/app/tokens.generated.css` | Fumadocs site (`--ds-*` custom properties) |
| Widget JS | `apps/native/WolfWave/Resources/widget-tokens.generated.js` | `apps/widget/build.ts` inlines `window.WW_TOKENS` into the shipped `widget.html` |
| Docs widget themes TS | `apps/docs/app/(home)/_widgets/widget-themes.generated.ts` | `USER_THEMES`, `WIDGET_THEMES`, `WIDGET_LAYOUTS`, `DEFAULT_THEME`, `DEFAULT_LAYOUT` for the landing-page OBS overlay preview |

### Regenerating

```bash
bun run tokens          # Direct
bun turbo tokens        # Via Turbo (cached when inputs unchanged)
bun turbo build         # `tokens` is a build prerequisite; runs automatically
```

`turbo.json` declares two root tasks:

| Root task | Script | Inputs |
|---|---|---|
| `//#tokens` | `bun run tokens` | `design-system/tokens.json`, `design-system/scripts/generate.ts`. Outputs the four generated files above. |
| `//#ds:lint` | `bun run ds:lint` | `apps/native/WolfWave/Views/**/*.swift`, `design-system/scripts/lint.ts`, `design-system/lint-allowlist.txt` |

`lint.ts` exports `RULES` and guards its own execution behind `import.meta.main`, so `lint.test.ts` can import the patterns without the import linting the tree and calling `process.exit`. A lint rule that silently stops matching is indistinguishable from a clean tree, which is what that suite exists to catch.

Both `build` and `dev` `dependsOn` `//#tokens`, so it runs automatically. `//#ds:lint` is
invoked on its own (locally, and as the `ds-lint` CI job).

### Widget themes (`window.WW_TOKENS`)

`widget.html` consumes build-inlined `WW_TOKENS.themes`: five selectable themes (`Default`, `Dark`, `Light`, `Glass`, `Neon`) plus the hidden internal `WolfWave` theme. `WW_TOKENS.layouts` contains five layouts (`Horizontal`, `Vertical`, `Compact`, `Vinyl`, `Classic`). Themes and layouts live in `tokens.json` under `widget`; add or edit them there, regenerate, then rebuild the widget. `WidgetHTTPService` may serve `/widget-tokens.generated.js` as a fallback asset route, but the shipped self-contained HTML does not fetch it at runtime.

### Component catalog

[`design-system/components/`](design-system/components/) - one markdown entry per reusable view, indexed by [`design-system/components/README.md`](design-system/components/README.md). The catalog covers three source directories, not just one: `Views/Shared/`, `Views/Onboarding/Components/`, and `Views/HistoryStats/`. Every entry follows the same template (Purpose, API, Tokens used, Anatomy mermaid, Accessibility, Do/Don't, Example); see [`status-chip.md`](design-system/components/status-chip.md) as the quality bar.

**When you touch any of these views, update the matching catalog entry in the same change.** That keeps token usage docs and anatomy diagrams from drifting.

### Design-system discipline

These rules are enforced by [`design-system/scripts/lint.ts`](design-system/scripts/lint.ts) (`bun run ds:lint`, also run in CI):

- **Never** use literal numbers in `font(.system(size:))`; use `DSFont.Size.*` (`xs=10`, `sm=11`, `body=12`, `base=13`, `md=14`, `lg=17`, `xl=20`, `x2xl=22`, `x3xl=26`). Heading ramp: `.paneTitle()` (22 bold, for standalone titles such as sheets; Settings panes are named by the window toolbar) → `.sectionHeader()` (17 semibold, H2) → `.sectionEyebrow()` (11 semibold secondary, H3); body via `.fieldSubtitle()` (13) / `.captionText()` (10). The old `.sectionSubHeader()` (15) was retired 2026-06-05 because it collided with the 17pt pane title; `x3xl` (26) is for hero titles (the onboarding welcome and completion screens).
- **Never** use literal numbers in `spacing:` or `.padding(N)` (including `.padding(.edge, N)` and `.padding([.a, .b], N)`); use `DSSpace.*` (`s0=2`, `s1=4`, `s1h=6`, `s2=8`, `s3=10`, `s4=12`, `s5=14`, `s6=16`, `s7=20`, `s8=24`, `s9=28`, `s10=32`, `s11=44`). `DSSpace` is a *spacing* scale: for a `.frame(width:)` reach for `DSDimension.*` instead.
- **Never** use literal numbers in `cornerRadius:` or `.cornerRadius(N)`; use `DSRadius.*` (`xs=4`, `sm=6`, `md=8`, `lg=10`, `lg2=12`, `xl=14`, `x2xl=16`). Enforced by the `raw-radius` lint rule.
- The `raw-spacing`, `raw-padding`, and `raw-radius` rules only flag values that have a token (a whole-number float such as `12.0` counts; `12.5` does not), because an off-scale literal has nothing to point at: add the token first. `Views/Onboarding/` is carved out of `raw-font-size`, `raw-spacing`, `raw-padding`, and `raw-radius` (its own visual language); the motion and `raw-status-color` rules still apply there. The lint is line-based, so a call split across lines is not seen, and `.frame(width:/height:)` literals are a staged follow-up, not yet linted.
- **Never** pass a raw system color as a `StatusChip` / `SectionHeaderWithStatus` state tint. Use `DSColor.success` / `.warning` / `.error` / `.info` / `.neutral`; the state-to-token table is in [`status-chip.md`](design-system/components/status-chip.md). `DSColor.neutral` is the off / disconnected state, and exists because `Color.secondary` is translucent, so the chip's own 10% background wash landed near-invisible beside opaque siblings. Enforced by the `raw-status-color` lint rule, which is scoped to the `color:` / `statusColor:` argument labels (so `.foregroundStyle(.secondary)` on body text is untouched) and reaches across a ternary. Its one blind spot, pinned by a test: a bare `return .gray` carries no argument label, so a line-based rule cannot see it. Two deliberate exceptions are outside the banned set and carry a comment: `.accentColor` for Software Update's "update available" (follows the system accent) and `Color.white.opacity(0.35)` for the Discord preview off dot (fixed brand surface, where neutral reads 1.9:1).
- Draw a glyph or dot that sits on a wash of its own status tint (`StatusChip`, `CalloutBanner`, the selected settings rail row) with `DSColor.glyph(for: tint, in: colorScheme)`. In Light appearance the bright semantic tints fall under 3:1 on their own 10% wash (success and warning near 2:1), so each maps to a darker `glyph…Light` token generated from `color.glyph.light`; dark appearance and non-semantic colors such as a category tag pass through. Keep the wash itself on the semantic tint, and take its opacity from `DSOpacity.wash` / `washStrong` rather than a literal. State-change motion goes through `.motionSafe(_:value:)` or `withMotionSafeAnimation(_:reduceMotion:_:)`, so Reduce Motion is honored in one place instead of a per-view ternary. These two are conventions, not lint rules.
- For single-glyph bordered buttons, use [`DSIconButton`](apps/native/WolfWave/Views/Shared/DSIconButton.swift); do **not** hand-roll `Button { Image(...) } .buttonStyle(.bordered) .controlSize(.small)`. Hand-rolled icon-only buttons collapse to a narrower frame than text-label neighbors like `CopyButton`, causing visible drift.
- When you touch a component under `Views/Shared/`, `Views/Onboarding/Components/`, or `Views/HistoryStats/`, update its catalog entry in [`design-system/components/`](design-system/components/) in the same change.

[`design-system/lint-allowlist.txt`](design-system/lint-allowlist.txt) is empty and the tree passes every rule. Do **not** add entries to it; fix the source. The `DSIconButton` rule above is a convention, not a lint rule (a multi-line pattern does not fit the line-based linter).

## Testing

Unit tests live in `apps/native/WolfWaveTests/` and use XCTest + Swift Testing with `@testable import WolfWave`. The test target is a hosted unit test bundle (`TEST_HOST` = `WolfWave Dev.app` for Debug and `WolfWave.app` for Release). Run `ls apps/native/WolfWaveTests/*.swift | wc -l` for the current file count.

> Auto-discovery: `apps/native/WolfWaveTests/` is a `PBXFileSystemSynchronizedRootGroup`; dropping a new `*.swift` file in is enough, no Xcode project edit required.

Test taxonomy is boundary-based:

- **Unit/service tests** exercise in-process logic, models, view models, and injected collaborators.
- **Integration tests** cross a real subsystem or transport boundary and assert an observable result. Loopback HTTP/WebSocket tests belong here.
- **End-to-end/UI tests** launch and drive the app as a user would. These live in `apps/native/WolfWaveUITests/` (target + scheme `WolfWaveUITests`, run with `make test-ui`), never in the hosted unit bundle. Hardware-, account-, and live-service journeys remain explicit manual release checks; `apps/native/docs/end-to-end-testing.md` is the current list of what is automated and what still needs hands.

### XCUITests (`apps/native/WolfWaveUITests/`)

A UI test runs the app in its **own process**, so `WolfWaveApp.isRunningTests` is false there and every isolation seam keyed on it would resolve to the live one. `Core/UITestMode.swift` is what closes that: the test bundle sets `WOLFWAVE_UI_TEST=1` on `launchEnvironment`, and the app then routes `DefaultsStore.store` and `KeychainService.backend` to throwaway storage and leaves `AppleMusicSource`, `TwitchChatService`, `DiscordRPCService`, and Sparkle down. **Never launch the app from a UI test without that flag** — it would edit the developer's real `com.mrdemonwolf.wolfwave.dev` domain and real Keychain, and the Music probe would park a TCC dialog over the runner.

- `WOLFWAVE_UI_TEST_ONBOARDED=1` starts past the wizard; `WOLFWAVE_UI_TEST_NO_WHATS_NEW=1` suppresses the What's New window; `WOLFWAVE_UI_TEST_SONG_REQUESTS_ENABLED=1` renders configured Song Requests without external accounts. These are declared in `UITestMode` and mirrored in `UITestEnvironment` in the test bundle (a UI test target cannot import the app). Change one side, change the other.
- `WOLFWAVE_UI_TEST_QUEUE=populated-held` seeds one playing, two upcoming, and one pending request for compact queue checks. It requires active Debug UI test mode and skips playback monitoring and setup health checks, so the queue stays fixed without checking the real Music playlist. The hosted test checks the held control, upcoming count, and approval-button geometry.
- Screenshot captures use `WOLFWAVE_UI_TEST_SETTINGS_SIZE=minimum|ideal` and `WOLFWAVE_UI_TEST_APPEARANCE=light|dark`. Both require UI test mode; Release ignores them. The capture test checks window width and horizontal pane containment before saving the 40-image matrix.
- Subclass `WolfWaveUITestCase` and declare state through `launchOptions`. Its `setUp` calls `app.activate()`, which is load-bearing: an inactive macOS app reports its whole window tree as disabled, so elements are findable but nothing is `isHittable` and clicks silently do nothing.
- Query by accessibility identifier, never visible label (panes repeat their section name, so a label matches the sidebar row and the content both). Sidebar rows are `settings.sidebar.<title>`; wizard buttons are `onboarding.<button>`. Check the element **type** against the real tree first — a sidebar `Label` maps to a `staticText`, not a button.
- `make test-ui` uses `UI_SIGN`, not `LOCAL_SIGN`: XCUITest attaches to the launched product, and a wholly unsigned app cannot be attached to, so the no-identity fallback is ad-hoc signing rather than `CODE_SIGNING_ALLOWED=NO`.
- The suite is **not** in `make test-ci`. Release and nightly stay unit-only so a UI run never gates a release.

### Test files

- `SparkleUpdaterServiceTests.swift` - Sparkle feed resolution (channel vs DEBUG resolver) and the bundled dev appcast
- `TrackInfoCommandTests.swift` - `TrackInfoCommand` covering both `!song`/`!currentsong`/`!nowplaying` and `!last`/`!lastsong`/`!prevsong` trigger sets via shared fixtures (trigger matching, case insensitivity, enable/disable, callback, default message, 500-char truncation)
- `BotCommandDispatcherTests.swift` - Message routing, callback wiring, length guards, whitespace handling, and preflight refusals (a refused viewer never claims the shared cooldown; the refusal reply is throttled per viewer and channel-wide)
- `CooldownManagerTests.swift` - Global + per-user cooldown enforcement
- `SongRequestServiceTests.swift`, `SongRequestQueueTests.swift`, `SongRequestCommandTests.swift`, `HoldCommandTests.swift`, `SongBlocklistTests.swift` - Song Request system (queue, hold mode, request command parse and `!sr` preflight refusals, blocklist incl. a comma-named act inside a collaboration)
- `SkipVoteManagerTests.swift`, `VoteSkipCommandTests.swift` - Chat vote-to-skip (threshold, dedup, window expiry, cooldown, subscriber gate, Polls mode, reply formatting)
- `SongRequestAccessTests.swift` - `RequestAudience` permission rules, `SongRequestPreset` apply/detect, `RedemptionStatus` banner messages
- `SongRequestQueueBoostTests.swift` - bit-cheer boost: moves a user's oldest queued item to the front
- `RequesterBlocklistTests.swift` - Blocking a person vs a song (a Twitch login matches case-insensitively, is never stored twice, and never crosses with song / artist blocks), plus the `RequestAudience` cycle behind the Stream Deck Request Access key
- `TwitchChannelPointsServiceTests.swift` - Helix create / reconcile / fulfill / cancel for the WolfWave-managed "Request a Song" reward
- `TwitchBitsParsingTests.swift` - `channel.bits.use` message parsing (cheermote fragment stripping)
- `StatsCommandTests.swift` - `!stats` live-gating via `stream.online` / `stream.offline` EventSub
- `StreamerModeTests.swift` - masking rules + Streamer Mode toggle persistence
- `ListeningHistoryServiceTests.swift`, `PlayLogStoreTests.swift`, `RecentTracksBufferTests.swift`, `HistoryFormattingTests.swift`, `StatsAggregatorTests.swift`, `MonthlyWrapTests.swift`, `LifetimeTallyTests.swift` - opt-in History & Stats pipeline (NDJSON append incl. closing a torn last line, rollups, monthly wrap, lifetime totals)
- `NotificationServiceTests.swift` - song-change notification banner dedup + identifier reuse
- `MetricsServiceTests.swift`, `DiagnosticsServiceTests.swift`, `DebugDiagnosticsTests.swift`, `DiagnosticsBundleTests.swift` - Opt-in MetricKit diagnostics, Debug-tab diagnostics, and the exported diagnostics bundle (environment header, crash block, every rotated log oldest first, stamped filename); payload pruning (newest 50, last 30 days) and delete-on-opt-out run against an injected temp directory
- `WebSocketServerAuthTests.swift` - role-prefixed overlay/control handshakes, credential separation, selected-subprotocol revalidation, and loopback-only command authorization
- `TwitchEventSubDedupTests.swift` - EventSub `message_id` dedup (at-least-once delivery: TTL expiry, cap eviction, no timestamp refresh on dup)
- `TwitchConnectionStateHubTests.swift` - per-subscriber connection-state streams (multi-subscriber fan-out, single-subscriber termination, finish-all)
- `PreferencesResolvedPortTests.swift` - clamped widget/WebSocket port resolution (0 falls back to default, out-of-range clamps instead of trapping)
- `AppleMusicControllerTests.swift` - PID-targeted AppleScript dispatch, structured errors, sanitization, timeout budgets, and guarded focus preservation
- `LinkResolverServiceTests.swift`, `SongSearchResolverTests.swift` - MusicKit search + Apple Music link resolve
- `MenuStatusFormatterTests.swift`, `OnboardingCompletionViewTests.swift`, `ActionGridTests.swift`, `LoadingRowTests.swift`, `CalloutBannerTests.swift` - Shared view + onboarding state coverage (`MenuStatusFormatterTests` also covers `MenuTitleFormatting` and `TwitchMenuState`, `OnboardingCompletionViewTests` the Skipped copy and the VoiceOver auto-dismiss policy, `CalloutBannerTests` the Light-mode glyph tokens)
- `HTTPClientTests.swift`, `TwitchDeviceAuthNetworkTests.swift`, `AppConstantsConfigOverrideTests.swift` - Foundation utilities + config plumbing
- `ArtworkImageLoaderTests.swift` - Delayed cover replacement, stale and cancelled completions, and resolved misses
- `ArtworkServiceNetworkTests.swift` - Stubbed iTunes request parsing, retry policy, cache keys, persistence, and eviction
- `AppleMusicSourceTests.swift` - Playback source lifecycle, ScriptingBridge error delegate/status mapping, monotonic timing, and player-state parsing
- `OnboardingViewModelTests.swift` + `OnboardingViewModelEdgeCaseTests.swift` - The 7-step order (Apple Music second, Permissions and Notifications separate), the "Step N of 7" progress text, step navigation, boundary conditions, UserDefaults persistence, the Skip setup ending
- `TwitchViewModelTests.swift`, `TwitchChatServiceTests.swift`, `TwitchDeviceAuthTests.swift`, `TwitchDeviceAuthErrorTests.swift` - Twitch auth + EventSub + view model state (device-code expiry copy, which work Try Again re-runs, a stale error cleared on a new attempt)
- `DiscordRPCServiceTests.swift` - IPC framing, reconnect backoff
- `DiscordIPCFramingTests.swift` - The IPC wire format through the real handshake over a `socketpair(2)`, with the test playing Discord: header encoding, READY completing it, two frames in one write, a reply split across reads, a header that never finishes, an oversized length rejected without waiting for its body, and a non-READY reply followed by CLOSE
- `DiscordPresenceBuilderTests.swift` - Rich Presence payload construction (state/details, buttons, timestamps)
- `WebSocketServerServiceTests.swift`, `WebSocketServerIntegrationTests.swift`, `WidgetHTTPServiceTests.swift` - Overlay broadcast + widget HTTP
- `StreamDeckCommandTests.swift` - Stream Deck control-command envelope parse (type/protocol/action gating, args, ack JSON shape)
- `StreamDeckPaneStatusTests.swift` - Stream Deck header-chip precedence (server off, then server error, then starting, then commands off; Ready only for a `.listening` server) and a distinct glyph per state
- `StreamDeckControlIntegrationTests.swift` - The same command across a real loopback WebSocket: a control client's frame reaches the injected handler and is acked on the originating connection, an overlay client's identical frame is refused `unauthorized` and never reaches the handler, and a stale protocol version is rejected without running. Covers the seam the parse suite and the auth suite each leave to the other.
- `StreamDeckControlGateTests.swift` - The `streamDeckControlEnabled` capability switch: defaults to on, an explicit off is honored (not treated as unset), it is independent of the shared server switch, and a refusal ack names its reason
- `StreamDeckClearQueueTests.swift` - Stream Deck `clear_queue` goes through `SongRequestService.clearQueue`, so Music.app's queue is cleared too (and it fails with `unavailable` when there is no service)
- `HealthPayloadTests.swift` - The `health` frame shape: `discord` stays the legacy boolean, and the additive `discordState` keeps "off" distinct from "disconnected"
- `RetryAfterTests.swift` - `Retry-After` delta-seconds and HTTP-date parsing, rejection of invalid values, and the 300 s cap
- `MusicPermissionBannerTests.swift` - The `music.automationDenied` error mapping (copy, severity, Open System Settings + Learn More)
- `KeychainServiceTests.swift` - Atomic Twitch grant migration and failure prefixes, save/load/delete, Unicode, and concurrent access
- `DefaultsStoreTests.swift` - Pins the `UserDefaults` isolation seam: a test host resolves to the dedicated suite, and a write through it never reaches the live app domain
- `SharedTestStateIsolationTests.swift` - Pins the `SharedTestStateIsolation` lock: a nested scope re-enters instead of deadlocking and keeps the outer scope's settings, the suite trait really opens a scope, and a fresh scope starts and ends on a clean slate
- `PreferencesResolvedDomainTests.swift` - Domain-resolved reads (`resolvedInt` / `resolvedDouble`) and the sanitized `Binding` helpers against NaN, infinity, negatives, values past `Int.max`, and values outside a picker's tag set
- `LoggerTests.swift`, `PowerStateMonitorTests.swift` - Core utilities (logging incl. log clearing and `\r` escaping / framing, power state). Log-clear tests are direct members of the `.serialized` "Logger Tests" suite so the truncating `clearLogFile()` can't race the file-readback tests.
- `LogRecordTests.swift`, `LogTailCursorTests.swift` - The log reader: writer-to-parser round trips (so `Log` and `LogRecord` cannot drift) and the tail cursor (bounded priming, partial-line carry, re-prime on truncate / rotate)
- `BugReportURLTests.swift` - Pre-filled GitHub issue URL construction and encoding
- `BundleInstallMethodTests.swift` - DMG vs Homebrew (cask) install detection
- `AppConstantsTests.swift` + `AppConstantsEdgeCaseTests.swift` - Constant values, URL validity, dimension bounds, cross-references
- `AppContainerTests.swift` - Application Support path composition and container wipe
- `CrashReporterTests.swift` - Crash-marker lifecycle (never raises a real signal or `NSException`; that would kill the xctest host); an exception marker survives the signal that follows it (the signal path is simulated, never raised)
- `CrashMarkerTests.swift` - Pure parsing of the crash breadcrumb: current signal / exception schema, writer-reader agreement, legacy markers, and the summary / detail text. Raises no real signal
- `SettingsBackupCoderTests.swift`, `SettingsBackupServiceTests.swift`, `SettingsBackupKeyCoverageTests.swift`, `SettingsSyncServiceTests.swift` - Backup encode/decode, export/import orchestration, the exportable / account-linked / runtime-state key classification, and the iCloud mirror (push/pull ordering, own-push no-echo, disabled never writes, `flush()` only when a change is pending) against an in-memory store
- `SettingsDeepLinkTests.swift`, `SettingsWindowConfiguratorTests.swift`, `SettingsFeedbackTests.swift` - Settings shell: `wolfwave://` parsing and the pinned pane slugs the docs link to, the sidebar-width repair that runs once per window, and feedback paths (Music permission recheck copy, aborted and incomplete factory reset, login-item failure, share temp-file cleanup)
- `BuiltInCommandCatalogTests.swift` - Built-in trigger reservation: catalog/dispatcher parity, editor refusal naming the built-in, stored and imported clashes turned off
- `CustomCommandTests.swift`, `InfoCommandTests.swift`, `WolfWaveReplyStyleTests.swift` - Custom bot commands (variable substitution, permission gating, draft validation, legacy trigger repair on load), the `!wolfwave` info command, and reply styling
- `QueueCommandTests.swift`, `MyQueueCommandTests.swift`, `ClearQueueCommandTests.swift`, `SkipCommandTests.swift`, `SongListCommandTests.swift` - Remaining song-request chat commands
- `SongRequestQueuePendingTests.swift`, `SongRequestPriorityTests.swift` - Approval-screening pending state and the Sub/VIP priority perk
- `PlaylistVisibilityWaitTests.swift` - The bounded wait for Music to see the requests playlist (scripted probe + sleep: early stop on visible / unknown, attempt budget, cancellation), the setup step's `PlaylistMusicState` machine, and the health check's wait policy
- `SongRequestSetupHealthTests.swift`, `SongRequestSetupViewModelTests.swift`, `PlaylistSetupStatusTests.swift`, `AppleMusicLibraryServiceTests.swift`, `MusicPermissionCheckerTests.swift` - Song Requests setup gate, playlist health check, and MusicKit library access
- `TwitchEventSubLifecycleTests.swift`, `TwitchTokenRefreshTests.swift`, `TwitchTokenLifecycleTests.swift`, `TwitchTokenValidationLifecycleTests.swift`, `TwitchRateLimiterTests.swift`, `HelixClientTests.swift`, `MapHelixErrorTests.swift` - EventSub lifecycle, token refresh/validation ownership, rate limiting, and the shared Helix wrapper
- `TwitchChannelValidationResultTests.swift` - Channel and token validation results: an unknown login, a refused request (status kept), a rate limit vs an outage, and a missing scope are all distinct, so only a real 401 blames the sign-in
- `TwitchRedemptionResolutionOutboxTests.swift` - Durable channel-point outcomes and Bits action replay, corruption recovery, duplicate tombstones (kept when the clock moved backwards), and the fsync'd write path
- `BotCommandGlobalGateTests.swift`, `TrackInfoCommandAliasTests.swift`, `StatsCommandFormatTests.swift`, `StatsWindowSummaryTests.swift` - Dispatcher gating, alias handling, and `!stats` formatting
- `UpdateChannelTests.swift` - Stable / Nightly channel resolution for the Sparkle dual feed
- `DiscordIdlePresenceTests.swift` - Idle Rich Presence payload
- `DiscordNotPlayingChoiceTests.swift` - The Discord pane's "When you pause" / "When music stops" pickers: each round-trips through its stored Bool (`discordClearWhilePaused` / `discordShowIdleStatus`), and the outcome table (a hidden paused song falls through to the stop choice) matches `DiscordRPCService`
- `FreshInstallDefaultsTests.swift` - Day-one values reach fresh installs only: an install that finished onboarding (or saved a Twitch channel) gets its old values pinned, a value the user set is never overwritten, the pass runs once, and its marker never travels in a backup
- `DiscordConnectionFailureTests.swift` - Why Discord is disconnected: `failureSnapshot` mirrors every assignment, a good connect clears the reason, the reason vocabulary round-trips (running-but-refused is not "not running"), and the state notification carries it
- `MonthlyWrapExportTests.swift`, `ArtworkTintTests.swift` - Monthly Wrap share-card export and album-art tint sampling
- `StreamerModeMaskingSweepTests.swift` - Sweeps every sensitive field for Streamer Mode masking
- `AtomicTests.swift`, `ByteFormattingTests.swift`, `InlineMarkdownTests.swift`, `FeatureFlagsDefaultsTests.swift`, `JSONSerializationGuardTests.swift`, `PasteboardTests.swift` - Core utility coverage (incl. sensitive copies clearing only while the clipboard is unchanged)
- `StringFormattingTests.swift` - `truncatedForChat()` counts Unicode scalars (Twitch's limit), not `Character`s, and never splits an emoji or a flag
- `HintRowTests.swift`, `LabeledSliderTests.swift`, `StatTileTests.swift`, `DestructiveButtonTests.swift`, `AsyncActionButtonTests.swift`, `SectionEyebrowTests.swift`, `NowPlayingHeroCardTests.swift`, `TwitchConnectionNoticeTests.swift` (state resolution, `expiredError`, and the reconnect action row a handler adds), `WidgetAppearancePreviewTests.swift` - Shared view components
- `StatusChipGlyphTests.swift`, `SettingsNavRailGroupTests.swift` - Shared design contracts: the Light-appearance glyph mapping behind `StatusChip` / `CalloutBanner` (every semantic state gets its darker glyph, dark keeps the tint, a category tag passes through) and `SettingsRailGroup`'s `ForEach` identity (unique, stable, independent of position)
- `UserFacingErrorTests.swift`, `ErrorCalloutTests.swift`, `FieldValidationRowTests.swift` - The `UserFacingError` model (message composition, accessibility label, action ordering, docs-anchor action, `Sendable` boundary) and the callout / inline-validation views that render it
- `DebugSectionCoverageTests.swift`, `DesignTokenCatalogTests.swift` - Debug-tab guards: every `DebugSection` is reachable from the jump-nav rail, and the generated token lists the design-system gallery iterates (incl. `DSOpacity`) stay complete and uniquely named
- `ThrowawayDefaultsTests.swift` - A `ThrowawayDefaults` suite never lands in the host's `Library/Preferences/`, suites are isolated from each other, and `destroy()` empties one
- `TestSongFactory.swift` - Helper, not a suite: `makeTestSong` builds a real MusicKit `Song` (it has no public initializer), so a mocked search can return a match and the request-pipeline gates are actually reached

### Non-Swift test suites

- `apps/widget/tests/widget.test.ts` - The OBS widget (`bun run --filter widget test`, bun test + happy-dom): loads `src/widget.ts` into a happy-dom window with a fake `WebSocket` and drives it with the frames the native server sends. Covers rendering, idle clearing, malformed and oversized frames, theme and layout config, reconnect backoff, a hostile artwork URL, and port validation. Runs in the CI `test` job.
- `apps/streamdeck/tests/` - The Stream Deck plugin (`bun run --filter streamdeck test`): protocol mirror, state reducer, client (ack correlation, late acks, handshake rejection), key rendering, manifest, Property Inspector, and `connection-status`. Runs in the `streamdeck` CI job.
- `scripts/check-sync.test.mjs`, `scripts/release-notes.test.mjs`, `scripts/version.test.mjs` - Node tests behind `make lint-sync`: the sync checker's patterns (incl. the docs port check), the release-notes renderer (a flat CHANGELOG section renders, an indented or wrapped line or a `*` bullet exits non-zero, and the real `CHANGELOG.md` renders), and `version.sh` (channels, the build-number floor, tag overrides, the shallow-clone refusal).
- `design-system/scripts/lint.test.ts` + `contrast.test.ts` - Design-system lint patterns against known-good and known-bad lines and AAA contrast for opaque text tokens on matching solid surfaces (`bun run ds:test`). Widget preset contrast is separately checked by `apps/widget/tests/contrast.test.ts` against composited light/dark scenes.

### Writing tests

- Use `@testable import WolfWave` (module name matches `PRODUCT_NAME`)
- Test hosts default to `InMemoryKeychainBackend`; never replace it with `SystemKeychainBackend` or access the user's real Keychain
- **Swift Testing runs separate suites in parallel.** `.serialized` only orders tests *within* one suite, and those suites also overlap XCTest in the same process, so anything reached through a process-wide global is shared with whatever else is running. Three globals matter here: `KeychainService.backend`, `Preferences.twitchReauthNeeded`, and every key in `DefaultsStore.store`. One lock covers all three — `SharedTestStateIsolation` — deliberately, because a second lock is a deadlock waiting for the first suite that wants both. Take it one of three ways:

  | Suite kind | How it takes the lock |
  |---|---|
  | XCTest | subclass `WolfWaveTestCase` (its `setUp` acquires; a teardown block always releases) |
  | Swift Testing | the `.isolatedSharedTestState` suite trait |
  | one block | `SharedTestStateIsolation.withIsolatedSharedState { }` |

  Scopes are re-entrant (a `@TaskLocal` marks the holding task tree), so a suite trait plus an inner explicit block is safe. **Subclassing `WolfWaveTestCase` is not optional for an XCTest suite that touches those globals** — that is the only thing putting it under the lock. A `@MainActor` suite must acquire with `acquireAsync()` from `setUp() async throws`; a blocking `acquire()` on the main thread deadlocks whenever the current holder is a `@MainActor` test suspended mid-`await`. Guarding only the suites that *write* is not enough: an ordinary reader racing a write was itself the flake. `SongRequestServiceTests` set `songRequestEnabled = true` in `setUp()` and asserted several `await`s later while `TwitchChatServiceTests` and the setup-gate suites wrote the same key, which surfaced as `testRequestWhileMusicAppClosedBuffers` intermittently failing with `featureDisabled` and passing every time in isolation.
- A suite that installs its own Keychain backend also binds `KeychainService.backendBox` (a `@TaskLocal`) via the `.isolatedKeychainBackend` trait, which makes that backend unreachable from any other task tree; `KeychainServiceTests` uses it, and two tests in that suite pin the property so the trait cannot silently stop binding. **A `@TaskLocal` does not reach code that leaves the task tree** — a test that drives `KeychainService` from a `DispatchQueue` block or a `Task.detached` sees the process-wide backend instead, and must rebind with `KeychainService.$backendBox.withValue(box) { }` inside the block (this works off-task; `testConcurrentAccess` does it). The same limit is why the XCTest lock path uses a plain `acquire`/`release` pair rather than the task-local: XCTest runs `setUp` and the test body in different tasks.
- **Never touch `UserDefaults.standard` in a test.** The test bundle is hosted, so `.standard` inside a test process is literally the dev app's live preference domain (`com.mrdemonwolf.wolfwave.dev`). Tests writing there edited the developer's real settings; one such write (`voteSkipWindowSeconds = 1`, not a valid picker tag) crashed the Song Requests pane inside SwiftUI on the next launch. Read and write `DefaultsStore.store` (production routes through the same seam, so a test write is visible to the code under test), or hand a SUT a `ThrowawayDefaults` suite. Enforced by `DefaultsStoreTests` and the blocking `user_defaults_standard` SwiftLint rule. Note the seam is one suite per *process*, not per test: it stops tests corrupting the dev app, not tests corrupting each other. That is the lock's job.
- **A test that needs its own settings store uses `ThrowawayDefaults`** (`WolfWaveTests/Support/ThrowawayDefaults.swift`), never `UserDefaults(suiteName:)` directly. A suite opened by *name* becomes a plist in the host's `Library/Preferences/` that cannot be removed reliably: `removePersistentDomain(forName:)` empties it, then cfprefsd rewrites the empty file on its own schedule, after any delete. UUID-named suites piled ~16,000 files into the dev container that way. `ThrowawayDefaults` names each suite by an absolute path inside a per-process temp directory instead (CFPreferences treats that domain as the plist file), so nothing reaches `Library/Preferences/` and the directory goes at process exit. Call `destroy()` in teardown (or a Swift Testing class suite's `deinit`). Enforced by the blocking `throwaway_defaults` SwiftLint rule and `ThrowawayDefaultsTests`.
- `@AppStorage` is deliberately **not** routed through `DefaultsStore`, so do not drive `@AppStorage` bindings from a hosted unit test: those writes would land on the live domain
- `WolfWaveTests` uses `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`; annotate UI-facing tests or helpers with `@MainActor` explicitly
- Test files are auto-discovered via `PBXFileSystemSynchronizedRootGroup`; just add `.swift` files to `apps/native/WolfWaveTests/`
- Prefer pure logic (version comparison, command matching, state machines). Network integration tests must own a loopback endpoint, await observable readiness, and use bounded timeouts; never depend on a public service.

## CI/CD

### Shared CI plumbing (change it here, not per workflow)

CI, Release, and Nightly used to carry their own copy of the build preamble and
the signing block. They now share one composite action and a set of scripts, so
a fix lands once and every workflow gets it. Local `make` targets call the same
scripts, so a green run locally means the same thing it means on a runner.

| Shared piece | Used by | What it does |
|---|---|---|
| `.github/actions/setup-native-build` | CI `test`, Release ×2, Nightly ×2 | Bun + caches, `bun install`, design tokens + widget build, `Config.xcconfig`, `SponsorConfig`, SwiftPM cache. Takes `twitch-client-id` / `discord-client-id` inputs (default `placeholder` for test builds). |
| `make test-ci` | CI, Release, Nightly | The single `xcodebuild test` invocation. Do not inline a different one in a workflow. |
| `scripts/check-generated-drift.sh` | CI `test`, `make check-drift` | Fails on drift in `widget.html`, the four generated token outputs, `SponsorConfig.generated.swift`, or `AppIcon-Dev.icon`, naming the fix command per group. |
| `scripts/check-sync.mjs` | CI `lint-sync`, `make lint-sync` | Fails when token-derived Swift lists are copied, component catalog coverage/template shape drifts, active widget docs disagree with source values, a docs page names a WolfWave port that drifts from `AppConstants`, or `lint.ts` rule claims disagree with `RULES`. |
| `scripts/import-signing-cert.sh` | Release, Nightly | Developer ID `.p12` into a throwaway keychain. |
| `scripts/codesign-app.sh` | Release, Nightly, `make prod-build` | Inside-out app signing (never `--deep`; see the comments in the script before touching it). |
| `scripts/notarize-dmg.sh` | Release, Nightly, `make notarize` | Sign + notarize + staple, dumping the notary log on rejection, then `stapler validate` and `spctl --assess` so a bad ticket fails here and not on a user's Mac (`make verify-notarize` runs the same two checks). |
| `scripts/generate-appcast.sh` | Release, Nightly | Sparkle appcast generation plus the edSignature / inline-`<description>` / no-`releaseNotesLink` guards. In CI it takes `generate_appcast` only from the pinned SPM artifact (`SourcePackages/artifacts/sparkle/...`); a Homebrew copy is a local-only fallback. |

- `.github/workflows/test.yml` (workflow name `CI`) - Runs on every push/PR to `main`. A single `changes` job runs `dorny/paths-filter` once and every other job gates on its outputs at the **job** level, so a docs-only PR shows the native jobs as skipped rather than running a job full of no-op steps (branch protection counts a skipped job as passing):

  | Job | Name | What it gates |
  |---|---|---|
  | `changes` | Detect changes | One paths-filter pass feeding every other job's `if:`. Add a new path filter here, not in the consuming job. |
  | `test` | Build & Test | `make test-ci` on `macos-26`, plus `scripts/check-generated-drift.sh` (widget, design tokens, SponsorConfig) and the widget's own tests (`bun run --filter widget test`). Sets `MallocNanoZone=0` as insurance against a since-fixed runner-image allocator crash. |
  | `ui-test` | UI Tests | `make test-ui` on `macos-26`. Separate job on purpose: it launches the real app, so it runs in minutes and fails for a different class of reason than `test`. Needs no account or network (see `UITestMode`). |
  | `docs` | Docs Build | `types:check`, `lint`, a full docs build, then `bun run --filter docs test` (unit tests plus the SEO guard over the built `out/`) |
  | `streamdeck` | Stream Deck Plugin | `typecheck`, `bun test`, `pack`, and an icon-generator drift check for `apps/streamdeck/`. Keeps the TS protocol mirror honest against `StreamDeckCommand.swift`, which is in the path filter so a Swift-only change still re-runs the TS tests; `assets/logo-mono.svg`, the icon generator's input, is in the filter too |
  | `lint` | SwiftLint | SwiftLint against `swiftlint-baseline.json` |
  | `lint-crash-safety` | SwiftLint (crash-safety) | **Blocking.** No new force unwrap, `try!`, or `as!` |
  | `lint-headers` | Swift file headers | **Blocking.** File-header convention |
  | `lint-sync` | Source and docs sync | **Blocking.** Token-derived lists, component catalog parity/template shape, widget docs values, design-system lint claims, and every docs page's ports against the `AppConstants` defaults (`FOREIGN_DOC_PORTS` in `check-sync.mjs` lists non-WolfWave ports such as the docs dev server). Also runs `release-notes.test.mjs` (renders the real `CHANGELOG.md`, so a malformed entry fails the PR, not the tag release) and `version.test.mjs`. Its path filter covers every input these read |
  | `ds-lint` | Design-system lint | `bun run ds:test` (pins the lint regexes against known-good and known-bad lines), `bun run ds:lint`, plus `bun run ds:schema`, which validates `tokens.json` against `tokens.schema.json` |

- **Timeouts and dependency updates.** Every workflow job sets `timeout-minutes` (longest for the signed release and nightly publish builds), so a hung runner fails fast instead of burning the 6-hour default. `.github/dependabot.yml` groups weekly minor + patch updates for GitHub Actions, SwiftPM (`/apps/native`: Dependabot reads `Package.resolved` inside the `.xcodeproj`), and bun (the root `bun.lock`).
- `.github/workflows/build_release.yml` - Builds, signs, notarizes, and creates a GitHub Release on tag push (`v*`). Required secrets: `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`, `TWITCH_CLIENT_ID`, `DISCORD_CLIENT_ID`, `SPARKLE_PRIVATE_KEY`. Optional: `PROVISIONING_PROFILE_B64` (Developer ID profile with iCloud; see the entitlements table).
- `.github/workflows/docs.yml` - Builds and deploys the Fumadocs site to GitHub Pages. Path-filtered, so a Swift-only push to `main` doesn't burn a Pages deployment; use `workflow_dispatch` to force one. A published stable release also triggers it, but that run only dispatches a fresh run on `main` (`gh workflow run docs.yml --ref main`): a release run sits on the tag ref, which the `github-pages` environment's branch policy (`main` only) refuses. The build checks out full history (`fetch-depth: 0`, `filter: blob:none`) because `sitemap.ts` dates each page from `git log`.
- `.github/workflows/update_homebrew.yml` - Opens a PR on the Homebrew tap after a GitHub Release is published.
- `.github/workflows/nightly.yml` - Nightly cron (05:00 UTC, midnight Chicago) signed + notarized build off `main` that publishes the rolling `nightly` GitHub prerelease feeding the opt-in Nightly update channel. `workflow_dispatch` builds on demand. A scheduled run is skipped when nothing that ships in the app changed since the last nightly: the `guard` job checks out `main` and diffs the last published `built-from:` sha against HEAD with an exclude list (`apps/docs`, `apps/marketing`, `apps/streamdeck`, `*.md`, `*.mdx`, `LICENSE`, the `docs` / `update_sponsors` / `license-year` / `dependency-review` / `update_homebrew` workflows, `.swiftlint*.yml`, `swiftlint-baseline.json`, `scripts/check-headers.mjs`, and `scripts/check-sync*.mjs`), because `schedule` triggers ignore `paths-ignore`; `nightly.yml`, `build_release.yml`, `test.yml`, and `.github/actions/**` stay build-relevant on purpose. Docs-only and housekeeping-only days cost nothing.
- `.github/workflows/update_sponsors.yml` - Refreshes the GitHub Sponsors list. `.github/workflows/license-year.yml` - Keeps the `LICENSE` year current.

### Sparkle Auto-Updates

Sparkle uses EdDSA (Ed25519) signing for update verification. The public key is in `Info.plist` as `SUPublicEDKey`. The private key is stored in the developer's macOS Keychain and as the `SPARKLE_PRIVATE_KEY` GitHub secret for CI.

- **DEBUG builds**: Sparkle is instantiated with `startingUpdater: false` (no background checks). Manual "Check Now" works and the `SPUUpdaterDelegate.feedURLString(for:)` callback points Sparkle at the bundled `dev-appcast.xml` (dummy v99.0.0 entry), so the full Sparkle UI is exercisable without a real release.
- **Release builds**: Sparkle checks the remote appcast at the `SUFeedURL` in Info.plist.
- **In-app release notes**: At release time, `scripts/release-notes.mjs` renders the version's `CHANGELOG.md` section into a styled, self-contained HTML file named to match the DMG (`WolfWave-X.Y.Z.html`). `generate_appcast` embeds that matching-name HTML as the appcast item `<description>`, so Sparkle's update dialog shows what's new. The `### Developer` block is dropped from the in-app notes (it stays on the web changelog), and a footer links out to the full changelog. `dev-appcast.xml` carries a styled sample so DEBUG "Check for Updates" previews the same rendering. The workflow runs the script via `bun` before the "Generate Sparkle appcast" step in `build_release.yml`. The renderer handles a flat subset only (`###` headings, `-` bullets, `**bold**`, `_italics_`, code spans, links) and exits non-zero on a nested or indented bullet, a wrapped line, or a `*` bullet, so keep each CHANGELOG bullet on one line; `scripts/release-notes.test.mjs` renders the real `CHANGELOG.md` in `make lint-sync` and the CI `lint-sync` job, so a bad entry fails the PR instead of the tag release.
- **Homebrew installs**: Sparkle is fully disabled (updates managed by Homebrew).
- **Key management**: Run `generate_keys` from Sparkle's tools to view/export/import keys. The tool is at `SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys` in DerivedData.

## Documentation

Docs site built with Fumadocs (Next.js) at `apps/docs/`. Content in `apps/docs/content/docs/` as `.mdx` files. Sidebar defined in `apps/docs/content/docs/meta.json` with Getting started, Using WolfWave, Help & updates, Developers, Design System, and Legal sections. Public release notes stay in the marketing navigation; the old docs changelog URL remains available for existing links. The Design System group is docs-facing (`design-system/{index,foundations,components,brand}.mdx`), separate from the source-of-truth `design-system/` directory at the repo root. Deployed to GitHub Pages. Run with `bun run dev --filter docs` from root.

> **Two Stream Deck pages, one character apart.** `streamdeck.mdx` is the user-facing
> plugin walkthrough (Guide group); `stream-deck.mdx` is the control API reference
> (Developers group). Check which one you opened before editing.

### Keep docs in sync (do not let these drift)

Any change that is user-facing or changes structure updates the docs in the **same PR**. Match the change to what it touches:

- **New or changed feature / command** → `README.md` (Features + Usage) **and** the affected docs pages (`features.mdx`, `settings.mdx`, `bot-commands.mdx`), plus a `CHANGELOG.md` entry under the top unreleased `## [x.y.z]` heading and the matching top block in `changelog.mdx`. The `### Developer` subsection is contributor-only: it is stripped from Sparkle's in-app notes and is deliberately absent from `changelog.mdx`, so a developer-only entry needs no docs-site change.
- **New service, renamed file, moved directory** → `architecture.mdx` source map **and** the Source-layout list in this file.
- **Changed numbers** (widget sizes, ports, theme/layout counts, minimum macOS) → grep the docs for the old value and fix every copy (`make lint-sync` already fails on a docs page that names a WebSocket or widget port differing from the `AppConstants` defaults).

Never hardcode a value that drifts. Read it from the source of truth instead: test count from `ls apps/native/WolfWaveTests/*.swift | wc -l`, app version from `MARKETING_VERSION` in `project.pbxproj`, widget dimensions / themes / layouts from `design-system/tokens.json`. The PR template checklists gate all of this.

> The site is a **static export** (GitHub Pages), served at `https://wolfwave.mrdemonwolf.dev` with an empty base path in production and dev. A fresh git worktree under `.claude/worktrees/` has no `node_modules`, so run `bun install` once before `bun run dev`/`build` there. The preview launch config is named `docs` (port 3000); in dev the OG routes serve at `/opengraph-image` (no `.png`).

> **Docs card styling gotcha.** Fumadocs heading permalink anchors carry `data-card=""`, and current versions may omit `.peer`. Style real cards with `a[data-card]:not(.peer):not([href^="#"])` so fragment links never become bordered cards.

### Docs website design flow

- **Docs navigation and components:** Keep install and feature orientation first, everyday guides together, help and updates next, then contributor and legal references. The docs home is a compact introduction, three entry cards, and integration setup tabs. Shared tabs use an underline active state, wrapping labels, 44px targets, visible keyboard focus, and 16px panel copy. Keep these styles in `global.css` so every MDX page inherits them.

- **Public pages:** `/changelog/` shares the existing MDX release source but excludes Unreleased sections before compilation (including search, TOC, LLM exports, and OG summaries). `/docs/changelog/` remains a noindex compatibility page with the public canonical. `/design-system/` is the visual showcase; `/docs/design-system/` remains the contributor reference. Showcase values come directly from `design-system/tokens.json`.
- **Web typography:** Montserrat headings, Roboto body, JetBrains Mono code follow the MrDemonWolf website reference. `app/layout.tsx` self-hosts them through `next/font`; `global.css` uses those variables with generated token fallbacks. Web sizes are additive `webSmall`, `webBody`, `webSection`, `webHero` tokens so native control sizes remain independent. Text token pairs target AAA on matching solid surfaces; components and transparent scenes need their own checks.
- **Shared layout:** Long-form pages use `app/docs/[[...slug]]/page.tsx` and Fumadocs. Keep typography, prose rhythm, and mobile navigation in `app/global.css`; avoid per-page spacing overrides. The docs home is a custom MDX landing page in `content/docs/index.mdx`.
- **Spacing:** Body copy stays left-aligned with `1.75` line height. Keep page descriptions close to their first MDX block; account for spacing already supplied by Fumadocs before adding margins. Use screenshots to check the relationship between each page title, description, first paragraph, and first section heading.
- **Review flow:** Inspect the landing page, `/download/`, `/docs/`, and representative paragraph-first and heading-first docs pages at desktop (`1280×720`) and mobile (`390×844`). Sweep every MDX route at the mobile width for horizontal overflow because all routes share the same layout. Keep review reports temporary when the user asks to remove review notes.
- **Current download path:** The landing hero and closing CTA use `getLatestDmgUrl()` for the primary direct `.dmg` action; the secondary hero action goes to `/download/`. The download page offers the latest `.dmg` and Homebrew command. Keep the macOS 26+ and Apple Silicon requirements visible next to those actions. On phones and touch-first screens (below the `sm` breakpoint, or `hover: none` with `pointer: coarse`) the hero, the closing CTA, and the `/download` hero swap the `.dmg` primary for **Send to my Mac** (`SendToMac`: a real `mailto:` link to the absolute `/download/` URL that upgrades to `navigator.share` once hydrated), because a phone can't install a `.dmg`. The swap is CSS-only (`.ww-cta-desktop` / `.ww-cta-phone` / `.ww-phone-only`), so the static export ships one markup for everyone; desktop is unchanged.
- **Landing preview:** The hero’s single now-playing product window is `_widgets/HeroPlayer.tsx` (`.ww-product-window`) and shares `useCyclingTrack` with the demos further down the page. The other interactive demos live in `_widgets/` (`DiscordPresenceCard`, `OBSOverlayWidget`, `TwitchChatPreview`, and `ComparisonTable`).

### Landing page (`app/(home)`)

The marketing home is `app/(home)/page.tsx`, an **async server component** resolving the latest download and release at build time through `lib/site.ts`. It has five focused sections: one product hero, core features, the interactive overlay, six common questions, and the closing download action. Detailed commands, comparison, privacy, and developer guides stay in the docs. Keep the hero to one preview with a quiet install-options link.

- **Section spine.** Preserve `audiences` (01, core features), `overlay` (02), `faq` (03), and `cta`. Earlier anchors remain as feature-card IDs or zero-height aliases near the features so shared links still resolve. The navbar is Features → Changelog → Docs; Download is a separate action. Supporting links stay in the footer.
- **Motion.** `_widgets/ScrollMotion.tsx` observes explicitly marked heading groups, cards, and previews without animating nested containers. A restrained entrance moves each block 6px over 280ms when it enters the readable viewport, replaying after it leaves and returns. Content is never hidden; reduced-motion changes cancel animations and disconnect observation. `ScrollMotion.test.ts` guards entry, preference changes, and cleanup. Do not restore the short CSS view-timeline effect that completed before readers could notice it.
- **Widgets.** The page renders `HeroPlayer` and `OBSOverlayWidget`, sharing `useCyclingTrack`. `DiscordPresenceCard`, `TwitchChatPreview`, and `ComparisonTable` remain reusable widgets outside the current landing composition. `SendToMac` provides the phone download action. `AlbumArt` and `sample-tracks.ts` provide invented demo content. The timer runs only while a widget is visible and reduced motion permits it. The hero pause button freezes the shared demos and releases its pause when unmounted.
- **FAQ.** `lib/faq.tsx` feeds the six visible answers and homepage `FAQPage` JSON-LD. `content/docs/faq.mdx` is the longer, grouped support reference. Keep visible and structured answers aligned; verify Twitch API eligibility separately from dashboard access.
- **Demo truthfulness.** Every simulated widget has a visible fictional/demo caption. Never use real artist names, songs, viewers, or album art as sample data.
- **Styling** uses `ww-*` utility classes in `app/global.css` (`ww-kicker`, `ww-stat`, `ww-proof`, `ww-chip`, `ww-card`, `ww-glass`, `ww-btn`, `ww-pill`, `ww-to-top`). Reuse these instead of one-off styles. Brand color tokens (`--brand-*`, `--bg-*`, `--txt-*`, `--hairline`) flip per theme.
- **Apple corner geometry.** Rounded surfaces opt into `corner-shape: squircle` (Apple's continuous superellipse) via an `@supports` block; Chromium renders the true squircle, every other browser falls back to the existing `border-radius`. The app-icon squircle uses Apple's **22.37%** ratio. Capsule/pill controls keep true-capsule ends; do **not** squircle them.
- **Flat by default.** Resting elements are flat; defined by a hairline border (and optional *subtle* shadow), never by bevels or float. No inset white highlights, no glassy `::before` sheen, no heavy multi-layer drop shadows. `.ww-glass` is a flat frosted card (frost + border only). Keep drop shadows shallow (e.g. `0 8-10px 24-28px -16px` at low alpha). **Hover-lifts are fine** (subtle `translateY` + brand-tinted shadow on `:hover` only). The OG image (`og-card.tsx`) is a rendered social card, not an on-page element, so it keeps real depth; don't flatten it.
- **Mobile gutters.** Sections use `px-[10%] md:px-6` → content is ~80% width (centered) on phones/tablets, reverting to the `max-w-*` cap on desktop. Use this pattern on new sections rather than a fixed `px-6`.
- **Mobile centering.** Section headers and short feature intros center on mobile (`text-center md:text-left`); card bodies and docs long-form stay left-aligned for readability.

### SEO & Open Graph images

The docs site generates Open Graph / Twitter card images at build time. Both paths are wired so changing page copy updates the social card. Do **not** hand-edit generated PNGs.

**Per-page docs cards (automatic).** Each MDX file under `content/docs/` drives its own card via `apps/docs/app/og/docs/[...slug]/route.tsx`, which reads these optional frontmatter fields and falls back to a section preset in `apps/docs/app/og/_components/og-presets.ts`:

| Frontmatter field | Card slot | Fallback |
|---|---|---|
| `ogTitle` | headline | `title` |
| `ogDescription` | sub-line | `description` |
| `ogEyebrow` | pill | preset by first slug segment |
| `ogChips` | chip row | preset by first slug segment |
| `keywords` | `<meta keywords>` | none |
| `metaTitle` | `<title>` only: search-intent wording ("Install on Mac: DMG, Homebrew & Setup Wizard"), never shown on the page or in the sidebar | `title` |

The changelog page is special-cased: its card is built from the latest `## vX.Y.Z` block in `changelog.mdx`, not from chips. The shared card visual lives in `apps/docs/app/og/_components/og-card.tsx` (`OgCard` + `ChangelogOgCard`).

> `OgCard` renders its headline **one word per flex item** so Satori wraps on word boundaries instead of clipping a single long flex child; don't collapse it back to one text node. Long descriptions are truncated (~120 chars) so the chip row never falls off the 1200×630 frame, and the body is top-aligned so a tall block can't overflow up into the wordmark header.

**Homepage / root card (single source of truth).** Homepage social copy lives in one constant, `homepageSeo` in `apps/docs/lib/site.ts`. It feeds `app/layout.tsx` (root meta + JSON-LD), `app/(home)/page.tsx` (homepage meta), `app/opengraph-image.tsx`, and `app/twitter-image.tsx`. Edit `homepageSeo` once and the meta tags plus both images update on the next build.

**The rule when you touch SEO or visible copy:**

- Changed a docs page's title, description, or pitch: update that page's frontmatter (`ogTitle` / `ogDescription` / `ogChips` / `keywords`) so its card matches.
- Changed the homepage or landing pitch: edit `homepageSeo` in `lib/site.ts`. Never hardcode homepage strings back into `layout.tsx`, `opengraph-image.tsx`, or `twitter-image.tsx`.
- Added a new docs page: start from the frontmatter template below so the card and SEO match the rest of the site.
- Page URLs in metadata (canonical, `og:url`, JSON-LD, the sitemap) go through `pageUrl()`: absolute, trailing slash, base path included. `absoluteUrl()` is for assets. The root layout deliberately sets no canonical or `og:url`, because every route would inherit the homepage's; each page sets its own. A title that already names WolfWave uses `title.absolute` so the root template doesn't brand it twice.

**Structured data** lives in `apps/docs/lib/seo.ts` and is emitted per page, never from the root layout (a docs page or the 404 must not claim to be the app). Home: `WebSite` + `Organization` + `SoftwareApplication` in one `@graph`, plus the `FAQPage` from `lib/faq.tsx`. Download: the same `SoftwareApplication`. Docs: `TechArticle` (git-derived `dateModified`) + a Home › Docs › Page `BreadcrumbList`. Do **not** add `HowTo` (Google retired that rich result) or a `FAQPage` whose questions are not visible on that page, and never invent a rating or review for `SoftwareApplication`. A docs `<title>` that already says "WolfWave" goes out as `title.absolute`, so the template never brands it twice.

**New-page frontmatter template:**

```yaml
---
title: Short page title
description: One-sentence search snippet, around 150 chars, keyword-rich.
ogTitle: Card headline (defaults to title)
ogDescription: Card sub-line (defaults to description)
ogEyebrow: Small pill label
ogChips:
  - Three
  - Or four
  - Short
  - Chips
keywords:
  - primary long-tail phrase
  - secondary phrase
---
```

**OG image standards (what a good card follows):**

- 1200x630 px (1.91:1). This is `OG_SIZE`; do not change it.
- Keep total weight well under 8 MB. Text cards from `next/og` are tiny, so no action needed unless you embed heavy raster art.
- Leave roughly 60 px of breathing room around key text. X, iMessage, and Discord crop the frame differently, so center-weight the message.
- One headline plus three or four chips. High contrast, large type, no paragraphs.
- Use absolute image URLs (`absoluteUrl(...)`; `metadataBase` is set) and `twitter:card = summary_large_image`.
- Give every image real `alt` text.

**Validate after a change:**

1. `bun run build --filter docs`. The OG routes are `force-static`, so they build here and fail the build on a code error.
2. `bun run --filter docs test`. Runs the SEO guard (`apps/docs/lib/seo.test.ts`) over the built `out/`: one `<h1>`, a unique title of at most 65 characters naming WolfWave once, a unique 50-160 character description, a canonical equal to the page's own trailing-slash URL, full OG/Twitter tags with a 1200x630 image, valid JSON-LD of the right types, a noindex 404, and a sitemap listing exactly the indexable pages. The CI `docs` job runs it after the build.
3. Eyeball the PNGs locally (`bun run dev --filter docs`): `/opengraph-image.png`, `/twitter-image.png`, and a page card such as `/og/docs/installation/image.png`.
4. After deploy, re-scrape with opengraph.xyz, the Facebook Sharing Debugger, the X Card Validator, and the LinkedIn Post Inspector. Social platforms cache cards hard, so a rebuild alone will not refresh what people already saw.

## Marketing

Remotion-based video projects live in `apps/marketing/`. Each subfolder is a standalone Remotion project (React + TypeScript) for producing announcement/promo videos.

- **wolfwave-announcement** - v1.0 launch announcement video. Run `bun run --filter wolfwave-announcement studio` from root to open the Remotion editor.

## Known Harmless Runtime Noise

These lines appear in Xcode console / stdout but are emitted by macOS itself, not WolfWave. Safe to ignore; do not chase them as bugs:

- `Rule path is not accessible: /var/protected/xprotect/...` and `Error reading rules: (null)` - XProtect / sandbox introspection denial.
- `FSFindFolder failed with error=-43` - legacy Carbon API noise from a system framework.
- `CoreSVG has logged an error. Set environment variable "CORESVG_VERBOSE" to learn more.` - system SVG renderer; unrelated to our assets. Set `CORESVG_VERBOSE=1` only if you want to investigate.
- `Unable to obtain a task name port right for pid …: (os/kern) failure (0x5)` - sandbox blocks task-port introspection of other processes.

## Code Conventions

- Swift 6.0 with async/await concurrency (no DispatchQueue for new async work)
- MARK sections organize every file (Properties, Public Methods, Private Helpers, etc.)
- DocC-style `///` comments on all public APIs
- No force unwrapping; use optionals and guard
- MVVM for views: ViewModels use `@Observable` macro (migrated from `ObservableObject`/`@Published`)
- Prefer structs for data models, classes for services
- camelCase for variables/functions, PascalCase for types
- **File header.** Every `.swift` file starts with the header Xcode generates from `apps/native/WolfWave.xcodeproj/xcshareddata/IDETemplateMacros.plist`:

  ```swift
  //
  //  AppConstants.swift
  //  WolfWave
  //
  //  Created by Nathanial Henniges on 2026-01-14.
  //  Copyright © 2026 MrDemonWolf, Inc. All rights reserved.
  //
  ```

  Line 3 is the **project** name, so test-target files say `WolfWave` too (the template uses `___PROJECTNAME___`, not `___PACKAGENAME___`). The date is the file's creation date per `git log --diff-filter=A --follow` (`--follow` matters: without it a later-moved file reports the move commit). Dates stay ISO `YYYY-MM-DD` even though Xcode's `___DATE___` expands to a locale short date, so reformat that one line after creating a file. `*.generated.swift` is exempt and keeps its generator banner. Enforced by `make lint-headers` (`scripts/check-headers.mjs`) and a blocking CI job.

## Versioning

Follows [Semantic Versioning (SemVer)](https://semver.org/): `MAJOR.MINOR.PATCH`:

- **MAJOR** - Breaking changes (API incompatibility, dropped platform support)
- **MINOR** - New features, backward-compatible
- **PATCH** - Bug fixes, security patches, code quality improvements

Version is set in `MARKETING_VERSION` in `project.pbxproj` (every occurrence; `grep -n MARKETING_VERSION apps/native/WolfWave.xcodeproj/project.pbxproj` lists them). Git tags use `v` prefix (e.g., `v1.0.1`). The release workflow triggers on `v*` tag pushes. Homebrew cask, CHANGELOG.md, and GitHub Release notes must all be updated to match.

### Build numbers: do NOT hand-bump

`CURRENT_PROJECT_VERSION` in `project.pbxproj` is a **dev-only placeholder**. Both release workflows override it at build time from [`scripts/version.sh`](scripts/version.sh), which is the single source of truth for marketing version + build number. The full rationale, including the platform limits that force this design, is in [`docs/build-versioning-standard.md`](docs/build-versioning-standard.md) — that doc is the portable house standard, written to be copied into the iOS/Android repos.

The short version:

| Rule | Why |
|---|---|
| Build number = `git rev-list --count HEAD` (floored). Stable **and** Nightly draw from the same counter. | Sparkle compares build numbers and **never offers a lower version**. Two counters means whichever channel has the bigger number strands its users on the other. |
| Never a timestamp (`$(date -u +%Y%m%d%H%M)`). | ~2×10¹¹ — about 100× over Android's `versionCode` cap of 2,100,000,000, so it can't be the house standard. It also floats so far above any hand-set int that no release can overtake it. This is the exact bug the previous nightly scheme shipped. |
| Never reset the counter per release. | The macOS App Store requires `CFBundleVersion` unique across *all* marketing versions. |
| Every `actions/checkout` in a job that resolves a version needs `fetch-depth: 0`. | The default shallow clone makes the commit count `1`. `version.sh` hard-fails on a shallow repo rather than emitting a wrong number. |
| A release tag must sit on a commit **later** than the last nightly's. | Same commit = same count = same build number, and Sparkle would never offer the release to nightly testers. The CHANGELOG + version-bump commit normally guarantees this; `build_release.yml` asserts it and fails the release if not. |

Marketing version stays hand-maintained: `MARKETING_VERSION` in the pbxproj, overridden by the `v*` tag at release time.

```bash
scripts/version.sh --channel nightly
```

### Release Checklist

Run through every item before pushing the release tag.

1. **`apps/native/WolfWave.xcodeproj/project.pbxproj`** - bump every `MARKETING_VERSION` occurrence. Leave `CURRENT_PROJECT_VERSION` alone: it is a dev placeholder and CI overrides it from `scripts/version.sh` (see [Build numbers](#build-numbers-do-not-hand-bump)).
2. **`CHANGELOG.md`** - add `## [X.Y.Z] - YYYY-MM-DD` entry in Keep-a-Changelog format. The release workflow renders this exact section into Sparkle's in-app update notes via `scripts/release-notes.mjs`, so write it for users first and keep developer-only items under `### Developer` (that subsection is stripped from the in-app notes), and keep every bullet flat (one line, `-` bullets only: `release-notes.mjs` fails on nested or indented bullets, wrapped lines, and `*` bullets).
3. **`apps/docs/content/docs/changelog.mdx`** - add `## vX.Y.Z. Month DD, YYYY` entry in MDX format (the OG card reads the latest `## vX.Y.Z` block).
4. **Push git tag** - `git tag vX.Y.Z && git push origin vX.Y.Z` triggers the release workflow (builds, signs, notarizes, creates GitHub Release).
5. **Homebrew cask** - auto-updated by `update_homebrew.yml` after the GitHub Release is created. Verify the workflow ran successfully.
6. **Bump every `MARKETING_VERSION` to the *next* version** and open the new `## [X.Y.Z] - Unreleased` block in `CHANGELOG.md` + `changelog.mdx`, and move the example nightly version (`X.Y.Z-nightly+a1b2c3d`) in `apps/docs/content/docs/nightly.mdx` to match. Do this right after the release lands, not at the start of the next one. Nightly builds advertise the committed `MARKETING_VERSION`, so until it's bumped every nightly claims the version you just shipped. `scripts/version.sh` warns on stderr when it detects this (committed version == newest `v*` tag).

> After tagging, verify the GitHub Actions release workflow completes cleanly before announcing.
