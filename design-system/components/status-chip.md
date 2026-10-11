# StatusChip

**File:** [`apps/native/WolfWave/Views/Shared/StatusChip.swift`](../../apps/native/WolfWave/Views/Shared/StatusChip.swift)

## Purpose
Capsule-shaped status indicator (leading glyph + label) used in settings sections to show connection or server state. The glyph is a state-varying SF Symbol when `systemImage` is supplied, or a plain colored dot otherwise.

Discord's enabled initial state uses **Connecting** with the warning tint.
**Discord not running** is reserved for the explicit `notRunning` failure.

## API
```swift
// Status chip: glyph + color carry the state together.
StatusChip(text: "Connected", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)

// Category tag with no shared icon vocabulary: dot fallback.
StatusChip(text: "Twitch", color: .purple)
```

| Param | Type | Notes |
|---|---|---|
| `text` | `String` | Short status label (≤ 16 chars). |
| `color` | `Color` | Tint for the glyph + `DSOpacity.wash` (10%) background fill. Use semantic tokens. In light appearance the glyph is drawn in the token's darker `glyph…Light` variant (see [Glyph contrast](#glyph-contrast)); the wash keeps the tint. |
| `systemImage` | `String?` | Optional leading SF Symbol. When set, replaces the colored dot so state reads through shape **and** color (WCAG 1.4.1). Use `StatusChip.StateGlyph.*` for the on / off / paused / error / starting vocabulary. `nil` (default) falls back to a colored dot. |

### StateGlyph vocabulary
Shared SF Symbol names so connection state is consistent across panes. The enum is
`nonisolated` (the module defaults to `MainActor`) so pure status resolvers such as
`StreamDeckPaneStatus` can reference it from a unit-testable, non-view context.

| Case | Symbol | Meaning |
|---|---|---|
| `.on` | `checkmark.circle.fill` | connected / live / on |
| `.off` | `circle` | off / disconnected |
| `.paused` | `pause.circle.fill` | paused by system (e.g. missing permission) |
| `.error` | `exclamationmark.triangle.fill` | error state |
| `.starting` | `ellipsis.circle` | transient starting / connecting |

### State tint vocabulary
Pair each glyph with its semantic token. Status chips take tokens, never raw system
colors, so an "Off" pill renders the same wash everywhere:

| State | Glyph | Tint |
|---|---|---|
| connected / live / on | `.on` | `DSColor.success` |
| off / disconnected / stopped | `.off` | `DSColor.neutral` |
| starting / connecting / degraded | `.starting` | `DSColor.warning` |
| paused by system | `.paused` | `DSColor.warning` |
| error | `.error` | `DSColor.error` |
| signed in but not joined | `.off` | `DSColor.info` |

`DSColor.neutral` (`#8E8E93`, Apple's `systemGray`) exists for the off state. It is the
one system gray whose light and dark variants are identical, so a single flat token
reads correctly in both. Do not fall back to `Color.secondary`: it is translucent, so
the chip's own `color.opacity(DSOpacity.wash)` background lands near-invisible next to
opaque sibling chips.

### Glyph contrast
The semantic tints are bright, tuned for dark appearance. In light appearance a tint drawn
on a 10% wash of itself reads at about 2:1 (success, warning) to 3:1 (error, info,
neutral), under the WCAG 1.4.11 floor of 3:1 for meaningful non-text marks. So the chip
draws its glyph (or dot) through `DSColor.glyph(for:in:)`, which maps each semantic token
to a darker variant in light appearance and leaves dark appearance alone:

| Tint | Light glyph | On its wash (light) |
|---|---|---|
| `DSColor.success` | `DSColor.glyphSuccessLight` `#1E7B34` | 4.5:1+ |
| `DSColor.warning` | `DSColor.glyphWarningLight` `#9A5B00` | 4.6:1+ |
| `DSColor.error` | `DSColor.glyphErrorLight` `#C9302C` | 4.3:1+ |
| `DSColor.info` | `DSColor.glyphInfoLight` `#0066CC` | 4.5:1+ |
| `DSColor.neutral` | `DSColor.glyphNeutralLight` `#6E6E73` | 4.2:1+ |

Ratios are measured on the wash over a white card and over `#F5F5F7`. A non-semantic
color (a category tag's `.purple`) passes through unchanged. Callers keep passing the
plain semantic token; never pass a `glyph…Light` token as `color`, since the wash would
then use the darker color too.

## Tokens used
- `DSFont.Size.sm` (11) / `DSFont.Weight.semibold`
- `DSSpace.s1h` (6) for the dot-to-label gap
- `DSSpace.s3` (10) horizontal padding, `DSSpace.s1` (4) vertical
- `DSDimension.StatusChip.minWidth` (88): minimum chip width
- `DSDimension.StatusChip.dot` (6): dot-fallback diameter
- `DSOpacity.wash` (0.10): background fill
- `DSRadius.pill` (clipped to `Capsule`)
- `DSMotion.Duration.base` (0.22): state-change animation via `.motionSafe(_:value:)`, so it drops out under Reduce Motion
- Color: caller passes `DSColor.success` / `.warning` / `.error` / `.info` / `.neutral`. See the state tint vocabulary above.
- `DSColor.glyph…Light` (`glyphSuccessLight`, `glyphWarningLight`, `glyphErrorLight`, `glyphInfoLight`, `glyphNeutralLight`): light-appearance glyph and dot color, resolved by `DSColor.glyph(for:in:)`

## Motion

- `.contentTransition(.symbolEffect(.replace))` on the leading SF Symbol (when `systemImage` is set): the glyph swaps with the symbol-replace effect on state change.
- `.contentTransition(.interpolate)` on the colored dot (dot fallback): `Circle().fill(color)` cross-fades on color swap.
- `.contentTransition(.opacity)` on the label: text fades through on string changes.
- Outer `.motionSafe(.easeInOut(duration: DSMotion.Duration.base), value: text)` and `value: color` so callers don't need to wrap mutations in `withAnimation`. `motionSafe` (in `ViewModifiers.swift`) reads `accessibilityReduceMotion` itself.
- When Reduce Motion is enabled the animation becomes `nil` and changes apply instantly; the `contentTransition` modifiers still ship to SwiftUI but degrade to step swaps under the system setting.

## Anatomy
```mermaid
graph LR
  Chip[Capsule background, color × DSOpacity.wash] --> Glyph{systemImage set?}
  Glyph -- yes --> Sym[SF Symbol, sm semibold, DSColor.glyph for color]
  Glyph -- no --> Dot[StatusChip.dot Circle, DSColor.glyph for color]
  Sym -. contentTransition .symbolEffect .replace .-> Sym2[on state change]
  Dot -. contentTransition .interpolate .-> Dot2[on color change]
  Chip --> Label[Text, sm semibold]
  Label -. contentTransition .opacity .-> Label2[on text change]
```

## Accessibility
- Combined element; VoiceOver reads the label once. There is no `accessibilityValue`: a value equal to the label made VoiceOver say the state twice. The leading glyph and the dot are `.accessibilityHidden(true)` for the same reason.
- The `statusChip.<text>` accessibility identifier is unchanged, so UI tests keep matching.
- Glyph contrast: in light appearance the glyph uses the darker `glyph…Light` token and stays above 3:1 on the wash (WCAG 1.4.11). The label is `.primary`.
- Fixed `DSDimension.StatusChip.minWidth` (88) keeps layout stable between state changes; animation of width doesn't fight with text update.
- Color is **never the sole signal**: the text always conveys status, and status chips pass `systemImage` so the state also reads through shape (WCAG 1.4.1). The dot fallback is reserved for non-status category tags where there is no shared icon vocabulary.
- Reduce Motion: the chip respects `accessibilityReduceMotion`; animation drops to instant.

## Do / Don't
- ✅ Use one chip per status concern (e.g. one for Twitch connection, one for WebSocket).
- ✅ Pass `systemImage` (a `StatusChip.StateGlyph.*` value) for any connection-state chip so color isn't the only cue.
- ❌ **No raw system colors for state.** `.green` / `.orange` / `.gray` / `Color.secondary` as a `color:` argument is a bug; use the token from the state tint vocabulary. Enforced by the `raw-status-color` rule in [`lint.ts`](../scripts/lint.ts) (`bun run ds:lint`). Raw colors are fine only for a non-status category tag (the dot-fallback form), e.g. `.purple` for a platform label.
- ❌ Don't use `DSColor.neutral` on a fixed-color surface. On the Discord preview card (`partnerDiscordSurface`) it drops to 1.9:1; that card uses `Color.white.opacity(0.35)` on purpose.
- ✅ Pair with `DSColor.success / warning / error / info`.
- ❌ Don't pass a `DSColor.glyph…Light` token as `color`. The chip picks the glyph variant itself; passing it would darken the wash too.
- ❌ Don't put it inline with body copy; it's a section-level indicator.
- ❌ Don't pass long strings; truncate or use a different component.
- ❌ Don't add a `systemImage` to a non-status category tag (e.g. a "Twitch" source label); the dot fallback is correct there.

## Example
```swift
StatusChip(text: "Connected", color: DSColor.success, systemImage: StatusChip.StateGlyph.on)
```
