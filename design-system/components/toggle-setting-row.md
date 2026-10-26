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

## Tokens used
- `DSFont.Size.base` (13) / `DSFont.Weight.medium`: title
- `DSFont.Size.sm` (11): subtitle (`.secondary` foreground)
- `DSSpace.s0` (2): title-to-subtitle spacing
- Standard macOS `.switch` toggle style (no custom color)

## Anatomy
```mermaid
graph LR
  Row[Native Toggle .switch] --> TextStack[Label: VStack spacing 2]
  TextStack --> Title[Text, base medium]
  TextStack --> Subtitle[Text, sm secondary, wrapping]
  Row --> Switch[Native switch]
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
