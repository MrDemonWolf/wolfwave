# ErrorCallout

**File:** [`apps/native/WolfWave/Views/Shared/ErrorCallout.swift`](../../apps/native/WolfWave/Views/Shared/ErrorCallout.swift)

## Purpose
Renders a `UserFacingError` as a tinted banner plus the buttons that fix it. This is the one surface for a failure the user can act on: what broke, why, what to do, and a control that does it.

It generalizes the hand-rolled banner+CTA pairs that came before it, so a new error surface never rebuilds the pair again. [`MusicPermissionBanner`](music-permission-banner.md) and the actionable expired state of [`TwitchConnectionNotice`](twitch-connection-notice.md) are now thin wrappers over it. A note with nothing to press stays a plain [`CalloutBanner`](callout-banner.md). The banner itself is a plain `CalloutBanner`; the actions ride in its `actions` slot, so they sit **inside** the box on the message's text column (changed 2026-10-26: a button outside the box floated on its own edge and read as unrelated to the note).

Use `FieldValidationRow` instead when the failure is about what was typed into a field, and an `.alert` only when the user just asked for something that failed outright (an import, an export, a reset).

## API
```swift
ErrorCallout(error: viewModel.channelError) { action in
    viewModel.perform(action)
}
```

| Param | Type | Default | Notes |
|---|---|---|---|
| `error` | `UserFacingError` | (required) | Supplies title, message, severity, actions, and the accessibility identifier. |
| `onAction` | `(ErrorAction) -> Void` | `{ _ in }` | Called with the intent the user chose. The caller owns the behavior; the component never performs the fix itself. |

A `retryAfter` primary action counts down to an absolute deadline. The countdown restarts when the error id or its declared wait changes (so a new rate limit under the same id gets a fresh wait), and resumes rather than restarts when the view disappears and comes back.

Severity maps to the banner style in one place: `.error` → `.error`, `.warning` → `.warning`, `.info` → `.info`. `UserFacingError` stays free of SwiftUI so it remains `Sendable` and testable without a renderer.

## Tokens used
- Action-row placement, gap, and `.small` control size come from `CalloutBanner`'s `actions` slot (`DSSpace.s2` above the row and between buttons)
- Tint comes from `CalloutBanner.Style` → `DSColor.error` / `.warning` / `.info`
- Corner radius and padding are inherited from `CalloutBanner`

## Anatomy
```mermaid
graph TD
  Root[ErrorCallout] --> Banner[CalloutBanner: title + message, severity tint]
  Banner --> Actions[actions slot: HStack s2, small controls, inside the box]
  Actions --> Primary[Button .borderedProminent, tinted to severity]
  Actions --> Secondary[Button .bordered, repeated]
```

## Accessibility
- The root is `.accessibilityElement(children: .contain)` with the label from `UserFacingError.accessibilityLabel`, which combines title and message. The real reason is spoken, never left to a tooltip.
- Identifier is `errorCallout.<error.id>`; each button appends `.action.<action.id>`. A state that never renders therefore fails its test rather than passing invisibly.
- A waiting action (`retryAfter`) is `.disabled`, so the countdown is conveyed by state, not color alone.

## Do / Don't
- ✅ Put the recovery action on the error itself, so the fix travels with the message.
- ✅ Let the first action be the obvious next step; it renders filled.
- ✅ Omit `.reconnectTwitch` when the sign-in verified fine — offering it wastes the user's time.
- ❌ Don't render the buttons as a sibling under the banner. They go in its `actions` slot, which this view already does.
- ❌ Don't interpolate a status code, `OSStatus`, or `localizedDescription` into the title.
- ❌ Don't use this for a value the user typed. That's `FieldValidationRow`.
- ❌ Don't render one for a state the app recovers from on its own a second later.

## Example
```swift
if let error = viewModel.connectionError {
    ErrorCallout(error: error) { viewModel.perform($0) }
}
```
