# AGENTS.md

Guidance for coding agents (Claude Code, Codex, and others) working in this repository. This file holds the rules that apply everywhere. Each area has its own `AGENTS.md` with the rules for that code; **read the one for the directory you are editing before you change anything in it.**

| Editing | Also read |
|---|---|
| The native app or its tests (`apps/native/`) | [`apps/native/AGENTS.md`](apps/native/AGENTS.md) |
| Design tokens, the component catalog, or any SwiftUI view styling | [`design-system/AGENTS.md`](design-system/AGENTS.md) |
| The docs site or landing page (`apps/docs/`) | [`apps/docs/AGENTS.md`](apps/docs/AGENTS.md) |
| The OBS widget (`apps/widget/`) | [`apps/widget/AGENTS.md`](apps/widget/AGENTS.md) |
| The Stream Deck plugin (`apps/streamdeck/`) or `StreamDeckCommand.swift` | [`apps/streamdeck/AGENTS.md`](apps/streamdeck/AGENTS.md) |
| The announcement video (`apps/marketing/wolfwave-announcement/`) | [`apps/marketing/wolfwave-announcement/AGENTS.md`](apps/marketing/wolfwave-announcement/AGENTS.md) |

One topic lives in one file. Do not copy a rule into a second `AGENTS.md`; link to it.

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

## Build & Development Commands (monorepo: bun + Turborepo)

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

> **Stream Deck plugin** rules live in [`apps/streamdeck/AGENTS.md`](apps/streamdeck/AGENTS.md); **OBS widget** rules live in [`apps/widget/AGENTS.md`](apps/widget/AGENTS.md).

## Non-Swift test suites

- `apps/widget/tests/widget.test.ts` - The OBS widget (`bun run --filter widget test`, bun test + happy-dom): loads `src/widget.ts` into a happy-dom window with a fake `WebSocket` and drives it with the frames the native server sends. Covers rendering, idle clearing, malformed and oversized frames, theme and layout config, reconnect backoff, a hostile artwork URL, and port validation. Runs in the CI `test` job.
- `apps/streamdeck/tests/` - The Stream Deck plugin (`bun run --filter streamdeck test`): protocol mirror, state reducer, client (ack correlation, late acks, handshake rejection), key rendering, manifest, Property Inspector, and `connection-status`. Runs in the `streamdeck` CI job.
- `scripts/check-sync.test.mjs`, `scripts/release-notes.test.mjs`, `scripts/version.test.mjs` - Node tests behind `make lint-sync`: the sync checker's patterns (incl. the docs port check and the bug-report form-field check), the release-notes renderer (a flat CHANGELOG section renders, an indented or wrapped line or a `*` bullet exits non-zero, and the real `CHANGELOG.md` renders), and `version.sh` (channels, the build-number floor, tag overrides, the shallow-clone refusal).
- `design-system/scripts/lint.test.ts` + `contrast.test.ts` - Design-system lint patterns against known-good and known-bad lines and AAA contrast for opaque text tokens on matching solid surfaces (`bun run ds:test`). Widget preset contrast is separately checked by `apps/widget/tests/contrast.test.ts` against composited light/dark scenes.

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
| `scripts/check-sync.mjs` | CI `lint-sync`, `make lint-sync` | Fails when token-derived Swift lists are copied, component catalog coverage/template shape drifts, active widget docs disagree with source values, a docs page names a WolfWave port that drifts from `AppConstants`, `lint.ts` rule claims disagree with `RULES`, or a `BugReportURL.FormField` id names no text field in `bug_report.yml`. |
| `scripts/import-signing-cert.sh` | Release, Nightly | Developer ID `.p12` into a throwaway keychain. |
| `scripts/codesign-app.sh` | Release, Nightly, `make prod-build` | Inside-out app signing (never `--deep`; see the comments in the script before touching it). |
| `scripts/notarize-dmg.sh` | Release, Nightly, `make notarize` | Sign + notarize + staple, dumping the notary log on rejection, then `stapler validate` and `spctl --assess` so a bad ticket fails here and not on a user's Mac (`make verify-notarize` runs the same two checks). |
| `scripts/generate-appcast.sh` | Release, Nightly | Sparkle appcast generation plus the edSignature / inline-`<description>` / no-`releaseNotesLink` guards. In CI it takes `generate_appcast` only from the pinned SPM artifact (`SourcePackages/artifacts/sparkle/...`); a Homebrew copy is a local-only fallback. |

- `.github/workflows/test.yml` (workflow name `CI`) - Runs on every push to `main` and on every pull request, whatever its base branch (so a stacked PR is tested too). A single `changes` job runs `dorny/paths-filter` once and every other job gates on its outputs at the **job** level, so a docs-only PR shows the native jobs as skipped rather than running a job full of no-op steps (branch protection counts a skipped job as passing):

  | Job | Name | What it gates |
  |---|---|---|
  | `changes` | Detect changes | One paths-filter pass feeding every other job's `if:`. Add a new path filter here, not in the consuming job. |
  | `test` | Build & Test | `make test-ci` on `macos-26`, plus `scripts/check-generated-drift.sh` (widget, design tokens, SponsorConfig) and the widget's own tests (`bun run --filter widget test`). Sets `MallocNanoZone=0` as insurance against a since-fixed runner-image allocator crash. |
  | `xcode-compatibility` | Xcode Compatibility (informational) | `make build` on the newest Xcode the `macos-26` runner offers (`maxim-lobanov/setup-xcode`, `xcode-version: latest`), after the shared `setup-native-build` action. `continue-on-error: true` and left out of `required-checks`, so it is an early warning for compiler and SDK changes that never blocks a PR or a release. |
  | `ui-test` | UI Tests | `make test-ui` on `macos-26`. Separate job on purpose: it launches the real app, so it runs in minutes and fails for a different class of reason than `test`. Needs no account or network (see `UITestMode`). |
  | `docs` | Docs Build | `types:check`, `lint`, a full docs build, then `bun run --filter docs test` (unit tests plus the SEO guard over the built `out/`) |
  | `streamdeck` | Stream Deck Plugin | `typecheck`, `bun test`, `pack`, and an icon-generator drift check for `apps/streamdeck/`. Keeps the TS protocol mirror honest against `StreamDeckCommand.swift`, which is in the path filter so a Swift-only change still re-runs the TS tests; `assets/logo-mono.svg`, the icon generator's input, is in the filter too |
  | `lint` | SwiftLint | SwiftLint against `swiftlint-baseline.json` |
  | `lint-crash-safety` | SwiftLint (crash-safety) | **Blocking.** No new force unwrap, `try!`, or `as!` |
  | `lint-headers` | Swift file headers | **Blocking.** File-header convention |
  | `lint-sync` | Source and docs sync | **Blocking.** Token-derived lists, component catalog parity/template shape, widget docs values, design-system lint claims, every docs page's ports against the `AppConstants` defaults (`FOREIGN_DOC_PORTS` in `check-sync.mjs` lists non-WolfWave ports such as the docs dev server), and the issue-form field ids `BugReportURL` prefills against `bug_report.yml`. Also runs `release-notes.test.mjs` (renders the real `CHANGELOG.md`, so a malformed entry fails the PR, not the tag release) and `version.test.mjs`. Its path filter covers every input these read |
  | `ds-lint` | Design-system lint | `bun run ds:test` (pins the lint regexes against known-good and known-bad lines), `bun run ds:lint`, plus `bun run ds:schema`, which validates `tokens.json` against `tokens.schema.json` |
  | `required-checks` | Required Checks | The branch-protection gate. Runs with `if: always()` once `changes` and every job in this table except `xcode-compatibility` have finished. It fails unless each applicable job succeeded and each job whose path filter did not match was skipped, so a skipped job counts as passing only when its filter said it did not apply. It also fails if `changes` itself failed. Add a new gated job to its `needs` list and to the job-to-filter map in its script. |

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

The docs site lives in `apps/docs/`; its layout, styling, landing-page, and SEO rules are in [`apps/docs/AGENTS.md`](apps/docs/AGENTS.md). The rule below applies to every change in the repo.

### Keep docs in sync (do not let these drift)

Any change that is user-facing or changes structure updates the docs in the **same PR**. Match the change to what it touches:

- **New or changed feature / command** → `README.md` (Features + Usage) **and** the affected docs pages (`features.mdx`, `settings.mdx`, `bot-commands.mdx`), plus a `CHANGELOG.md` entry under the top unreleased `## [x.y.z]` heading and the matching top block in `changelog.mdx`. The `### Developer` subsection is contributor-only: it is stripped from Sparkle's in-app notes and is deliberately absent from `changelog.mdx`, so a developer-only entry needs no docs-site change.
- **New service, renamed file, moved directory** → `architecture.mdx` source map **and** the Source-layout list in this file.
- **Changed numbers** (widget sizes, ports, theme/layout counts, minimum macOS) → grep the docs for the old value and fix every copy (`make lint-sync` already fails on a docs page that names a WebSocket or widget port differing from the `AppConstants` defaults).

Never hardcode a value that drifts. Read it from the source of truth instead: test count from `ls apps/native/WolfWaveTests/*.swift | wc -l`, app version from `MARKETING_VERSION` in `project.pbxproj`, widget dimensions / themes / layouts from `design-system/tokens.json`. The PR template checklists gate all of this.

> The site is a **static export** (GitHub Pages), served at `https://wolfwave.mrdemonwolf.dev` with an empty base path in production and dev. A fresh git worktree under `.claude/worktrees/` has no `node_modules`, so run `bun install` once before `bun run dev`/`build` there. The preview launch config is named `docs` (port 3000); in dev the OG routes serve at `/opengraph-image` (no `.png`).

> **Docs card styling gotcha.** Fumadocs heading permalink anchors carry `data-card=""`, and current versions may omit `.peer`. Style real cards with `a[data-card]:not([href^="#"])` (as `app/docs/docs.css` does) so fragment links never become bordered cards.

## Marketing

Remotion-based video projects live in `apps/marketing/`. Each subfolder is a standalone Remotion project (React + TypeScript) for producing announcement/promo videos.

- **wolfwave-announcement** - v1.0 launch announcement video. Run `bun run --filter wolfwave-announcement studio` from root to open the Remotion editor.

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
