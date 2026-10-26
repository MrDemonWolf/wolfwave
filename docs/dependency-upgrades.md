# Dependency refresh

Checked October 20, 2026 with the pinned Bun 1.3.11. All five JavaScript workspace manifests were reviewed. The lockfile was regenerated from their declared version ranges to refresh stale transitive dependencies. A narrow override updates `serve`'s pinned `compression` dependency from 1.8.1 to the compatible patched 1.8.2.

## Direct upgrades

Versions below are installed versions, compared with the previous committed lockfile.

| Package | Before | After |
| --- | --- | --- |
| `turbo` | 2.11.7 | 2.11.9 |
| `fumadocs-core`, `fumadocs-ui` | 16.16.2 | 16.17.7 |
| `fumadocs-mdx` | 15.4.6 | 15.4.9 |
| `next`, `eslint-config-next` | 16.4.0 | 16.4.2 |
| `react`, `react-dom` | 19.3.0 | 19.3.1 |
| `lucide-react` | 1.55.0 | 1.60.0 |
| `zod` | 4.6.5 | 4.6.7 |
| `postcss` | 8.5.29 | 8.5.31 |
| `eslint` | 10.12.0 | 10.13.0 |
| Docs `@types/node` | 26.6.4 | 26.6.5 |
| `happy-dom`, `@happy-dom/global-registrator` | 20.14.6 | 21.0.3 |
| `@types/bun` | 1.4.2 | 1.4.3 |
| `@elgato/streamdeck` | 2.1.0 | 2.1.2 |
| `@elgato/cli` | 1.10.2 | 1.10.3 |
| `remotion`, `@remotion/cli`, `@remotion/google-fonts` | 4.0.534 | 4.0.537 |

The Stream Deck TypeScript and Node type ranges, and the widget Tailwind range, now start at their already installed versions. React versions remain aligned between docs and the announcement project. Happy DOM 21 disables external CSS and iframe loading by default; the inline widget tests pass with that security change.

## Versions intentionally retained

| Dependency | Retained | Reason |
| --- | --- | --- |
| TypeScript | 5.9.3 | The installed ESLint TypeScript parser declares support below 6.0.0. TypeScript 7 also changes the compiler API and requires configuration migration. |
| Widget Tailwind | 3.4.19 | Version 4 requires a separate CLI and CSS/build migration. The docs site already uses 4.3.3. |
| Stream Deck Node types | 20.19.43 | Match the plugin's declared Node 20 runtime rather than Node 26. |
| Bun | 1.3.11 | The committed widget bundle and CI depend on this version's minifier output. |

Stream Deck SDK 3 (3.0.3) was adopted later. Its default settings events need Stream Deck 7.1, so the plugin sets [`useLegacySettingsBehavior`](https://docs.elgato.com/streamdeck/sdk/releases/upgrading/v3/) before connecting and keeps supporting Stream Deck 6.5. `manifest.test.ts` fails if the manifest allows a pre-7.1 version without that flag.

The native app has one resolved Swift package: Sparkle 2.10.0, revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`. It matches the [latest official stable release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0), so neither `Package.resolved` nor the Xcode package requirement changed.

## Remaining audit findings

Refreshing transitive dependencies and overriding `compression` to 1.8.2 reduced `bun audit` from 46 findings to 2: one high and one moderate. The audit still exits with status 1. The [compression response-close memory leak](https://github.com/advisories/GHSA-vc2v-76pw-4v95) is resolved; a local `serve` smoke check returned HTTP 200 with gzip encoding after the override.

| Dependency | Finding and limit |
| --- | --- |
| `postcss-selector-parser` 6.x | [Moderate: selector parsing CPU exhaustion](https://github.com/advisories/GHSA-rj75-hqrm-r3gf). Older build-tool chains require 6.x; patched 7.1.6 crosses their declared major range. |
| `braces` 3.0.3 | [High: deeply nested patterns exhaust the stack](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm). The advisory lists no patched version. |

These packages are used by development, build, or local preview tools. They are not a server runtime shipped with the statically exported website. This does not establish that every tool input is safe. Install also reports ESLint peer-range warnings; lint and build results are recorded separately from dependency installation.

## Checks after the final lock refresh

| Check | Result |
| --- | --- |
| `bun run --filter widget test` | 35 passed, 151 assertions |
| `bun run --filter streamdeck test` | 162 passed, 365 assertions |
| `bun run --filter streamdeck typecheck` | Passed |
| `bun run --filter streamdeck build` | Passed |
| `bun run tsc --noEmit` in `apps/marketing/wolfwave-announcement` | Passed |
| `bun install --frozen-lockfile` after the compression override | Passed; 929 installs across 1101 packages, no changes |
| Local `serve` with `Accept-Encoding: gzip` | HTTP 200 and `Content-Encoding: gzip` |
| `git diff --check` for the manifests and lockfile | Passed |
| `bun audit` | Two findings remain, listed above |

Website production build, docs tests, browser end-to-end checks, and native runtime checks are tracked in the website review and final delivery report. An announcement video render and physical Stream Deck operation were not checked in this dependency pass.
