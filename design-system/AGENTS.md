# AGENTS.md: design system (`design-system/`)

> Paths in backticks are relative to the repo root unless they are links. Shared rules (CI, docs sync, versioning, release) are in the root [`AGENTS.md`](../AGENTS.md).

## Design System

Single source of truth: [`design-system/tokens.json`](tokens.json). The generator [`design-system/scripts/generate.ts`](scripts/generate.ts) emits four platform outputs; **do not edit generated files by hand**:

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

[`design-system/components/`](components) - one markdown entry per reusable view, indexed by [`design-system/components/README.md`](components/README.md). The catalog covers three source directories, not just one: `Views/Shared/`, `Views/Onboarding/Components/`, and `Views/HistoryStats/`. Every entry follows the same template (Purpose, API, Tokens used, Anatomy mermaid, Accessibility, Do/Don't, Example); see [`status-chip.md`](components/status-chip.md) as the quality bar.

**When you touch any of these views, update the matching catalog entry in the same change.** That keeps token usage docs and anatomy diagrams from drifting.

### Design-system discipline

These rules are enforced by [`design-system/scripts/lint.ts`](scripts/lint.ts) (`bun run ds:lint`, also run in CI):

- **Never** use literal numbers in `font(.system(size:))`; use `DSFont.Size.*` (`xs=10`, `sm=11`, `body=12`, `base=13`, `md=14`, `lg=17`, `xl=20`, `x2xl=22`, `x3xl=26`). Heading ramp: `.paneTitle()` (22 bold, for standalone titles such as sheets; Settings panes are named by the window toolbar) → `.sectionHeader()` (17 semibold, H2) → `.sectionEyebrow()` (11 semibold secondary, H3); body via `.fieldSubtitle()` (13) / `.captionText()` (10). The old `.sectionSubHeader()` (15) was retired 2026-06-05 because it collided with the 17pt pane title; `x3xl` (26) is for hero titles (the onboarding welcome and completion screens).
- **Never** use literal numbers in `spacing:` or `.padding(N)` (including `.padding(.edge, N)` and `.padding([.a, .b], N)`); use `DSSpace.*` (`s0=2`, `s1=4`, `s1h=6`, `s2=8`, `s3=10`, `s4=12`, `s5=14`, `s6=16`, `s7=20`, `s8=24`, `s9=28`, `s10=32`, `s11=44`). `DSSpace` is a *spacing* scale: for a `.frame(width:)` reach for `DSDimension.*` instead.
- **Never** use literal numbers in `cornerRadius:` or `.cornerRadius(N)`; use `DSRadius.*` (`xs=4`, `sm=6`, `md=8`, `lg=10`, `lg2=12`, `xl=14`, `x2xl=16`). Enforced by the `raw-radius` lint rule.
- The `raw-spacing`, `raw-padding`, and `raw-radius` rules only flag values that have a token (a whole-number float such as `12.0` counts; `12.5` does not), because an off-scale literal has nothing to point at: add the token first. `Views/Onboarding/` is carved out of `raw-font-size`, `raw-spacing`, `raw-padding`, and `raw-radius` (its own visual language); the motion and `raw-status-color` rules still apply there. The lint is line-based, so a call split across lines is not seen, and `.frame(width:/height:)` literals are a staged follow-up, not yet linted.
- **Never** pass a raw system color as a `StatusChip` / `SectionHeaderWithStatus` state tint. Use `DSColor.success` / `.warning` / `.error` / `.info` / `.neutral`; the state-to-token table is in [`status-chip.md`](components/status-chip.md). `DSColor.neutral` is the off / disconnected state, and exists because `Color.secondary` is translucent, so the chip's own 10% background wash landed near-invisible beside opaque siblings. Enforced by the `raw-status-color` lint rule, which is scoped to the `color:` / `statusColor:` argument labels (so `.foregroundStyle(.secondary)` on body text is untouched) and reaches across a ternary. Its one blind spot, pinned by a test: a bare `return .gray` carries no argument label, so a line-based rule cannot see it. Two deliberate exceptions are outside the banned set and carry a comment: `.accentColor` for Software Update's "update available" (follows the system accent) and `Color.white.opacity(0.35)` for the Discord preview off dot (fixed brand surface, where neutral reads 1.9:1).
- Draw a glyph or dot that sits on a wash of its own status tint (`StatusChip`, `CalloutBanner`, the selected settings rail row) with `DSColor.glyph(for: tint, in: colorScheme)`. In Light appearance the bright semantic tints fall under 3:1 on their own 10% wash (success and warning near 2:1), so each maps to a darker `glyph…Light` token generated from `color.glyph.light`; dark appearance and non-semantic colors such as a category tag pass through. Keep the wash itself on the semantic tint, and take its opacity from `DSOpacity.wash` / `washStrong` rather than a literal. State-change motion goes through `.motionSafe(_:value:)` or `withMotionSafeAnimation(_:reduceMotion:_:)`, so Reduce Motion is honored in one place instead of a per-view ternary. These two are conventions, not lint rules.
- For single-glyph bordered buttons, use [`DSIconButton`](../apps/native/WolfWave/Views/Shared/DSIconButton.swift); do **not** hand-roll `Button { Image(...) } .buttonStyle(.bordered) .controlSize(.small)`. Hand-rolled icon-only buttons collapse to a narrower frame than text-label neighbors like `CopyButton`, causing visible drift.
- When you touch a component under `Views/Shared/`, `Views/Onboarding/Components/`, or `Views/HistoryStats/`, update its catalog entry in [`design-system/components/`](components) in the same change.

[`design-system/lint-allowlist.txt`](lint-allowlist.txt) is empty and the tree passes every rule. Do **not** add entries to it; fix the source. The `DSIconButton` rule above is a convention, not a lint rule (a multi-line pattern does not fit the line-based linter).
