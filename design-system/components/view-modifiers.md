# ViewModifiers

**File:** [`apps/native/WolfWave/Views/Shared/ViewModifiers.swift`](../../apps/native/WolfWave/Views/Shared/ViewModifiers.swift)

Bundle of cross-cutting SwiftUI view modifiers. Each is exposed as a chainable extension on `View`.

---

## `.cardStyle()` / `.cardStyleUnpadded()`

Wraps content in a standard settings card — a rounded `controlBackgroundColor` surface on the **content layer**.

```swift
content
  .padding(DSDimension.Settings.cardPadding)   // unless cardStyleUnpadded
  .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: DSDimension.Settings.cardCornerRadius, style: .continuous))
  .overlay(/* hairline border: Color.primary.opacity(0.06) */)
```

- **Tokens:** `DSDimension.Settings.cardPadding` (16), `DSDimension.Settings.cardCornerRadius` (14).
- **When to use:** any grouped settings region. Default container.
- **When _not_:** inside another card (no nesting), or for full-bleed hero sections.
- **Why not glass:** Apple's Liquid Glass guidance ("Meet Liquid Glass", WWDC25) reserves glass for the *navigation* layer (sidebar/toolbar — macOS applies it automatically) and keeps the scrolling *content* layer on solid system backgrounds. Glass on content reads heavy/dark, and the system collapses stacked glass into a vibrant fill. Settings cards are content, so they use the native grouped-Form surface. Do **not** reintroduce `.glassEffect` here.
- **Legitimate hand-rolls:**
  - Tinted sub-cards (Advanced danger red, Song Request orange / quaternary, App Visibility indigo notice, WebSocket blue info) still hand-roll because the modifier has no `tint:` option. Tracked as a future extension — add `CardModifier(padded:tint:)` so those sites adopt one chrome. Until then, reach for `.cardStyle()` / `.cardStyleUnpadded()` only for **untinted** cards.
  - Onboarding step tiles (`OnboardingDiscordStepView`, `OnboardingOBSWidgetStepView`, etc.) hand-roll `controlBackgroundColor` for their selected/unselected tile states — separate visual context from settings cards, intentionally not `cardStyle()`.

  All untinted settings cards (including `AboutSettingsView`) route through `.cardStyle()` / `.cardStyleUnpadded()`.

## `.interactiveRow(isEnabled:)`

Adds hover background + pointer cursor for list rows that act as buttons.

- **Tokens:** `DSRadius.sm` (6), `Color.primary.opacity(0.04)`, `DSMotion.Duration.fast` (0.15) for the hover-fade.
- **When to use:** rows in custom selection lists that aren't `Button` / `List` rows.
- **When _not_:** for `Toggle`/`Picker` controls — they have native affordance.
- **Cursor:** uses SwiftUI `.pointerStyle(isEnabled ? .link : nil)` — the system handles push/pop. No manual `NSCursor` calls.

## `.pointerCursor()`

Pointing-hand cursor on hover for clickable non-Button views (`Image`, `Text` with `.onTapGesture`, etc.).

- Wraps SwiftUI `.pointerStyle(.link)` (macOS 15+) — never leaks like a manual `NSCursor.push/pop` pair would.
- (`.disabledCursor(_:)` was removed — was unused. If you need a not-allowed cursor, gate the parent `Button` with `.disabled(true)` and let the system pick.)

## `Animation.reducedMotion(_:reduceMotion:)`

Returns the supplied animation, or `nil` when the user has Reduce Motion enabled.

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
// …
.animation(
    .reducedMotion(.easeInOut(duration: DSMotion.Duration.base), reduceMotion: reduceMotion),
    value: state
)
```

## `.reduceMotionAware(_:reduceMotion:value:)`

Sugar for the above — applies an animation that respects Reduce Motion. Pulls the value via `@Environment(\.accessibilityReduceMotion)` at the call site.

## `.skeleton(_:)`

Renders content as a redacted placeholder while loading. Suppresses hit-testing and VoiceOver so users can't tap or hear stale data.

```swift
QueueRow(item: placeholder).skeleton(isLoading)
```

- Wraps `.redacted(reason: isLoading ? .placeholder : [])` with `.accessibilityHidden(isLoading)` + `.allowsHitTesting(!isLoading)`.
- **When to use:** first-paint loading states with content shape (lists, grids, stat cards).
- **When _not_:** for short, indeterminate spinners — `ProgressView()` is the right tool there.

## `.sectionHeader()` / sub-header

Standardized section-header typography.

- **Tokens:** `DSFont.Size.lg` (17) / `.semibold` for primary; `.md` (14) / `.semibold` reserved for sub-headers (currently `.system(size: 15, weight: .semibold)` — pending alignment to 14 in next migration pass).

---

## Do / Don't

- ✅ Reach for `cardStyle()` before drawing your own rounded rectangle.
- ✅ Combine `pointerCursor()` with any custom `.onTapGesture` to make affordance obvious.
- ❌ Don't hand-roll `controlBackgroundColor` cards — `cardStyle()` already provides the standard content surface.
- ❌ Don't apply `interactiveRow` to disabled controls — pass `isEnabled: false` instead so the hover state is suppressed.
