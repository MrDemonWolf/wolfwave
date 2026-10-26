# ToggleSettingRow

**File:** [`apps/native/WolfWave/Views/Shared/ToggleSettingRow.swift`](../../apps/native/WolfWave/Views/Shared/ToggleSettingRow.swift)

## Purpose
Title + subtitle + native macOS switch in a single horizontal row, used everywhere a setting is "off/on" with explanatory text.

## API
```swift
ToggleSettingRow(
    title: "Enable Feature",
    subtitle: "A short description of what this does",
    isOn: $isOn,
    accessibilityLabel: "Enable Feature",
    accessibilityIdentifier: "featureToggle"
)
```

| Param | Type | Notes |
|---|---|---|
| `title` | `String` | Bold, 13pt medium. Action verb preferred ("Enable …", "Show …"). |
| `subtitle` | `String` | 11pt secondary. Wraps vertically without truncation. |
| `isOn` | `Binding<Bool>` | Two-way state binding. |
| `controlSize` | `ControlSize` | Default `.regular`. Compact surfaces can explicitly use `.small`. |
| `isDisabled` | `Bool` | Uses native disabled appearance and prevents interaction. |
| `accessibilityLabel` | `String` | Required. VoiceOver reads this in lieu of the visual label. |
| `accessibilityIdentifier` | `String` | Required. For UI tests. |
| `accessibilityHint` | `String?` | Optional. Explains the consequence ("Reconnects Twitch chat."). |
| `onChange` | `((Bool) -> Void)?` | Side-effect on toggle (e.g. start/stop a service). Binding still updates. |
| `hint` | `String?` | Optional footnote that belongs to this switch, drawn as a `HintRow` under the row, `DSSpace.s1h` below it, on the title's leading edge. `nil` draws nothing. |
| `hintSystemImage` | `String` | The hint's SF Symbol. Default `info.circle.fill`. |

## Tokens used
- `DSFont.Size.base` (13) / `DSFont.Weight.medium`: title
- `DSFont.Size.sm` (11): subtitle (`.secondary` foreground)
- `DSSpace.s0` (2): title-to-subtitle spacing
- `DSSpace.s1h` (6): row-to-hint spacing (only with `hint`)
- Standard macOS `.switch` toggle style (no custom color)

## Anatomy
```mermaid
graph LR
  Row[Native Toggle .switch] --> TextStack[Label: VStack spacing 2]
  TextStack --> Title[Text, base medium]
  TextStack --> Subtitle[Text, sm secondary, wrapping]
  Row --> Switch[Native switch]
  Row -. optional hint .-> Hint[HintRow, s1h below, outside the Toggle]
```

## Accessibility
- VoiceOver reads `accessibilityLabel` + `accessibilityValue` ("Enabled" / "Disabled").
- `accessibilityHint` describes the consequence of flipping; set it when the effect is non-obvious. It is only applied when non-nil, so omitting it emits no empty-string hint.
- The visible label belongs to the native toggle. Keyboard focus and VoiceOver use one control.
- Native disabled styling honors both `isDisabled` and an ancestor's `.disabled(...)`.

## Do / Don't
- ✅ Wrap in `.cardStyle()` so multiple rows stack inside a card with proper padding.
- ✅ Use `onChange` for service start/stop side-effects; keep the binding pure UI state.
- ❌ Don't put two toggles in one row. Split into two `ToggleSettingRow`s.
- ✅ Use `hint` for a footnote about this switch instead of a divider plus a hand-padded `HintRow`. The hint sits outside the native `Toggle`, so it never joins the control's VoiceOver label or click target.
- ✅ Inside a card, separate the row from the next piece (a callout, another control) with `AppConstants.SettingsUI.cardRowSpacing`.
- ✅ Keep descriptions concise; longer text wraps without clipping or separating it from its switch.

## Example
```swift
ToggleSettingRow(
    title: "Discord Rich Presence",
    subtitle: "Show \"Listening to Apple Music\" on your Discord profile.",
    isOn: $discordEnabled,
    accessibilityLabel: "Discord Rich Presence",
    accessibilityIdentifier: "discord.toggle",
    onChange: { enabled in discordService.setEnabled(enabled) }
)
.cardStyle()
```
