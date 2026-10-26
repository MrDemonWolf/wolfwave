# TODO

Current native UX work, Stream Deck follow-ups (WW-45), and build hygiene.

## Native macOS UX — active, October 25, 2026

Work is local on `main`; the current changes have not been committed or pushed.
Keep existing worktrees and unrelated changes intact.

### Completed and verified

- [x] Research Apple documentation with the Swift, macOS, and SwiftUI skills; use Astra to investigate the Settings lifecycle.
- [x] Reproduce Settings failing to open: its action fired while the app was active, but the hidden scene bridge never appeared or received the request.
- [x] Remove the hidden helper window, notification relay, and 50 ms fronting delay. Use the App's `openWindow` action and retain the request until the actual Settings window attaches.
- [x] Restore/front an existing Settings window by exact identifier, including minimized windows, using normal macOS window activation.
- [x] Pass targeted UI tests for opening Settings and stock sidebar Down/Up navigation after that replacement. Evidence: `/tmp/wolfwave-scene-open-ui.log` (2 tests, zero failures).
- [x] Use native labeled switches, standard control sizes, wrapping secondary descriptions, and system disabled styling in the shared toggle component.
- [x] Pass all 2,098 unit tests after the scene replacement and named About assets (824 Swift Testing), plus signed Debug build, docs build, 45 docs tests, 109 design-system tests, schema/lint, SwiftLint, sync checks, and `git diff --check`. Unit evidence: `/tmp/wolfwave-verified-final-unit.log`; final signed build: `/tmp/wolfwave-ready-preview-build.log`.

### Implemented, awaiting final verification

- [x] Check repeated close/reopen with Cmd+comma three times and restore a minimized window. Both targeted UI regressions passed in `/tmp/wolfwave-compact-targeted-ui.log`.
- [ ] Check menu-only mode and bringing Settings forward from behind another app.
- [x] Verify the toolbar beside the sidebar button names the selected pane. All 40 captures and the running app show the matching title. The UI assertion was corrected to use macOS's `window.title`, not its distinct `label` attribute; its final rerun is pending runner access.
- [x] Verify consistent sidebar section labels using the shared heading typography.
- [x] Pass the 40-image matrix at 640-point minimum and 1240-point preferred widths, Light and Dark; review all ten compact pane layouts. Evidence: `/tmp/wolfwave-compact-matrix-ui.log`. Native minimum frame is 640 × 672 including chrome.
- [x] Exercise native Window → Move & Resize → Left on the current 1920-point display. Song Requests remains usable in the 960-point left half. Other MacBook display hardware is not directly tested; 640-point geometry covers a half-width 1280-point workspace.
- [x] Keep queue controls above the list with regular-size buttons; verify empty Hold changes to Resume in a compact window. Evidence: `testCompactQueueControlsRemainReachable` passed in `/tmp/wolfwave-compact-matrix-ui.log`.
- [ ] Verify playing, pending-approval, and long-queue states with real Apple Music/Twitch accounts. The running app currently reports Music access is needed and Twitch is disconnected. No access grants, sign-ins, or library mutations were performed.
- [ ] Rerun the final compact appearance snapshots after the last URL-action wrapping and About-asset corrections. The earlier 40-image matrix predates those final view refinements. Copy/Open actions now stack beneath URLs; Now Playing text allows two lines.

### About appearance — verified

- [x] Verify Settings → About shows blue/white in Light and black/cyan in Dark in the running signed app. DEV badge is preserved. The first runtime-image approach failed verification and was removed; standard Any/Dark assets come directly from the original Icon Composer sources. Regenerate with `bash scripts/generate-about-icons.sh`. All four exports were checked as valid 256 × 256 PNGs and reproduce identical bytes on this Xcode version. The original System appearance preference was restored after checking.

### Final checks and handoff

- [ ] Finish the full UI suite. The last three attempts failed before any tests executed with `Timed out while enabling automation mode`; closing the normal app did not resolve it. The test service remains responsive, so its unidentified sessions do not establish a hung daemon. No permissions were changed. A question about a visible macOS automation/password prompt is pending. Latest evidence: `/tmp/wolfwave-final-refreshed-ui.log`.
- [x] Check signed Debug build, SwiftLint, design-system schema/lint/tests, docs build/tests, sync checks, and `git diff --check`.
- [x] Keep README, Settings docs, both changelogs, component documentation, and generated artifacts in sync with the final behavior. Removed the superseded bridge description from release notes and added the current outcome to the historical spacing audit.
- [x] Open the actual signed Debug app, left-tiled on Song Requests, for Nathanial to review. The old screenshot-review browser tab is gone and its temporary HTTP server was stopped. No new mockup or review website was created.
- [ ] Commit/push only after verification; no release tag has been created.

Next: resolve UI-runner automation setup, rerun the remaining UI checks, then review live account/playback behavior before publishing.

---

## Stream Deck plugin

The plugin builds, typechecks, and passes its tests, but **has never run on a real device**. Verification and submission need hardware or an Elgato account, not CI.

### 1. Verify on a physical Stream Deck (or the Elgato simulator)

Every one of these is currently an assumption:

- Keys render and update from live state.
- Key presses produce the right command and the ok/alert flash.
- The `Offline` / `Token?` / `Update` states appear when they should.
- Two keys bound to the same action correlate acks in press order (the FIFO scheme has no correlation id, so this is the case most likely to be wrong).
- The Property Inspector saves global settings and the plugin picks them up.

### 2. Submit to the Elgato Marketplace

Packaging is done: `bun run --filter streamdeck pack` emits
`apps/streamdeck/dist/com.mrdemonwolf.wolfwave.streamDeckPlugin` (gitignored), and
CI runs it as a shippability check because packing validates the manifest and
every asset it points at.

What is left is the submission itself, which needs an Elgato Maker account. Do it
after item 1. Once it lands, drop the "not on the Marketplace yet" callout in
`apps/docs/content/docs/streamdeck.mdx` and close item 4.

### 3. Deferred v1 action: now-playing dial

Named in WW-45, out of scope for the first pass: a dial (encoder) with album art
and rotation-bound volume. It wants app-side seams that don't exist yet. Revisit
once the basic key set is confirmed working on hardware.

### 4. `sdPlugin` install is manual

`apps/docs/content/docs/streamdeck.mdx` documents copying the folder into `~/Library/Application Support/com.elgato.StreamDeck/Plugins/` by hand. That's fine pre-Marketplace, but revisit the page's install section once item 2 lands.

---

## Build hygiene

### 5. `widget#build` turbo warning

`turbo build` emits `no output files found for task widget#build`. Worth chasing separately so real drift isn't masked by an expected warning.
