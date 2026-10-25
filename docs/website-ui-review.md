# UI/UX Review: WolfWave website and overlays

**Reviewed:** 2026-10-20 · **Input:** local Chrome UI and source · **Method:** NN/g heuristic evaluation and WCAG checks

## Executive summary

**Latest revision after reboot:** The current page has five sections, three feature cards, six landing FAQ answers, and a deeper FAQ organized into five topics. The header is Features → Changelog → Docs, with Download separate. A faint blue wash sits behind the single hero preview.

The CSS scroll timeline has been replaced by observed entrances for explicitly marked heading groups, cards, and previews: 6px over 280ms after they enter the readable viewport, replaying after they leave and return. An isolated test checks entry, reduced-motion changes, cancellation, and cleanup. Text stays opaque and visible.

Typecheck, lint, all 45 docs tests, and the production build passed. Native Chrome screenshots after reboot confirm the simplified desktop hero, three-card feature section, overlay demo, and header layout. Browser debugging remains disconnected, and further native control was interrupted by user activity. Fresh mobile reflow and visual timing of scroll entrances remain unverified; viewport measurements below describe the earlier composition.

- Landing page, download, representative docs, public changelog, and public design system were inspected in Chrome at desktop and mobile sizes.
- All 27 MDX routes were navigated at 390px; each had one H1 and no document overflow.
- The most visible issue found was headings being styled as cards by a Fumadocs selector; it was fixed in shared CSS.
- No unresolved severity 3–4 findings were identified in the tested flows. This is a bounded review, not a full accessibility certification.

**Findings after fixes:** 0 catastrophic, 0 major, 0 open minor, 0 open cosmetic in reviewed flows. Device and assistive-technology checks remain below.

## Findings

### Severity 2 — Minor, fixed

#### 1. Docs headings looked like interactive cards

- **What:** Fumadocs heading permalink anchors carried `data-card` without the older `.peer` marker, so the card selector added borders to headings.
- **Where:** Installation and other docs section headings.
- **Guideline:** Consistency and standards; headings should communicate hierarchy and links should communicate actions.
- **Evidence:** [NN/g usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/) — familiar, consistent presentation helps readers recognize the interface.
- **Fix:**
  - [x] Exclude fragment links from card selectors.
  - [x] Reinspect desktop and mobile docs headings; give page titles a clearer shared size.

#### 2. Several overlay preset text colors were too weak

- **What:** Muted text and translucent surfaces could lose contrast against bright scenes or artwork.
- **Where:** Default, Dark, Light, Glass, Neon, and the retained legacy theme tokens.
- **Guideline:** WCAG 1.4.3 Contrast (Minimum).
- **Evidence:** [W3C contrast guidance](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html) — normal text needs at least 4.5:1 against its background.
- **Fix:**
  - [x] Strengthen text colors/scrims and regenerate every consumer.
  - [x] Add composited contrast regression guards including scene extremes and decorative noise.

#### 3. Mobile navigation controls had small touch targets

- **What:** Open Search and Toggle Menu measured 34px square.
- **Where:** Shared mobile navigation.
- **Guideline:** Generous targets reduce missed taps; 44px is the chosen enhanced target.
- **Evidence:** [W3C Target Size (Enhanced)](https://www.w3.org/WAI/WCAG22/Understanding/target-size-enhanced.html).
- **Fix:**
  - [x] Increase both controls to 44px square and measure them in Chrome.

## Tested states and measurements

The subsequent hero refinement removes the duplicate OBS panel and nested stage, connection chips, proof badges, and integration strip. One product preview remains. Navigation now uses Features, Docs, Changelog, and Resources, with Download separated from the main links. Desktop and mobile Resources navigation were exercised, including following Design system from the mobile menu. CSS view-timeline movement was observed changing from a 32px offset to zero as the section entered, with text opacity held at 1. Reduced-motion users and browsers without view timelines get static sections.

| Check | Evidence |
|---|---|
| Landing | Chrome 1280×720 and 390×844, light/dark; direct Mac CTA visible on desktop; Send to my Mac on mobile |
| Hero synchronization | App and OBS sample showed the same song from the shared clock |
| Public pages | `/changelog/` and `/design-system/` at desktop/mobile; no horizontal page overflow |
| Release visibility | First visible version v2.1.0; Unreleased absent from public main content |
| Docs | Home, installation, features, and download screenshots; 27/27 MDX mobile route sweep |
| Search | Search opens, input visibly focused, “overlay” returns documentation results; ArrowDown and Enter on “backup” navigate to the matching troubleshooting section |
| Preview pause | Explicit Pause previews button holds track and elapsed time; Resume previews restarts the shared clock |
| Type | Mobile hero 38px; body at least 16px; section headings scale from 30px to 48px |
| Solid text tokens | All primary/secondary/muted pairs on base/surface/elev pass 7:1 in both appearances |
| Brand links | Light surface 5.11:1; dark surface 6.01:1 |
| CTA text | Light white-on-blue 5.57:1; dark black-on-blue 5.76:1 |
| Overlay presets | Lowest tested text ratio 5.46:1, including legacy theme; user-facing presets at least 6.50:1 in the tested composites |
| Generated renderer | Actual bundled `widget.html?preview` in Chrome through a temporary local harness: all 25 user theme/layout combinations rendered the sample track with expected nonzero geometry; screenshots inspected for Neon/Classic, Glass/Vinyl, and Light/Vertical |

## Unverified (needs a different input to check)

- Actual 200% browser zoom: the available browser interface exposes viewport resizing but no zoom operation. Mobile reflow was tested.
- VoiceOver announcements and complete keyboard traversal: search focus and native button semantics were checked; no screen-reader certification is claimed.
- Live OBS CPU/GPU use and frame pacing: source/test improvements do not establish a measured runtime speedup.
- Live native WKWebView settings preview: traced to the same committed bundle; native computer-use service was unavailable.
- Production deployment, crawler indexing, and social-cache refresh.

## Integration checks

- Latest docs cleanup: shorter docs home, grouped sidebar, shared underline tabs with 44px targets and focus outlines, 16px tab-panel copy, and 14px table copy. Interactive browser automation timed out before this revision could be visually checked; no full interactive E2E claim is made.
- Production HTTP smoke: all 34 exported HTML routes and 69 unique local routes/assets returned 200; linked cross-page anchors resolved. This checks the exported site through a local server under `/wolfwave`, not interactive behavior or production deployment.
- After dependency upgrades, Fumadocs' authored-source stringifier required explicit removal of draft nodes as well as AST filtering. The built-export guard caught this regression and now passes, including `llms-full.txt`.

- Production static build: passed with the pinned Bun 1.3.11, including token and widget generation.
- Docs suite: 45 passed, including scroll-motion lifecycle, canonical/sitemap/structured-data checks and draft exclusion from HTML, search, and LLM exports.
- Widget suite: 35 passed, including replayed snapshot, native preview config, and preset contrast checks.
- Design-system suite: 109 passed, including all opaque text/surface contrast pairs. Schema and design lint passed.
- Docs TypeScript and ESLint: passed. `make lint-sync`: passed (23 script tests and source/docs synchronization).
- Generated token outputs and bundled widget: regenerated with Bun 1.3.11 and compared by SHA-256; all five artifacts reproduced without drift.
- Native Debug build: explicit `xcodebuild` finished with `BUILD SUCCEEDED`. Xcode reported an installed CoreSimulator version mismatch; the initial quiet build also printed unrelated Twitch/debug-log warnings, so this is not a warning-free toolchain claim.
- Prose metadata inspection: no AI metadata or container findings in the five inspected Markdown files; no marks were removed and no statistical rewrite was performed.

## What's working well

- Shared token sources keep preset colors and dimensions aligned across the app, widget, and website preview.
- Reduced-motion rules and visibility-gated demo timers preserve the content while limiting background work.
- Public release notes reuse the existing MDX source, with build guards against draft leakage.

## Quick wins

- [x] Preserve stable landing anchors and phone download behavior.
- [x] Use one typography source and stronger solid-surface text pairs.
- [ ] Complete the remaining live/device checks before a conformance or performance claim.
