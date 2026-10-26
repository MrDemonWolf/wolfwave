# CopyableURLRow

**File:** [`apps/native/WolfWave/Views/Shared/CopyableURLRow.swift`](../../apps/native/WolfWave/Views/Shared/CopyableURLRow.swift)

## Purpose
A settings row that shows a copyable URL - optional label + `StreamerModeBadge`, the URL in a masked monospaced font, an optional helper subtitle, and a trailing `CopyButton` (plus an optional accessory like `OpenInBrowserButton`). Folds the four hand-rolled masked-URL rows in Stream Widgets settings into one component so Streamer Mode masking, the badge guard, and the copy-disabled rule live in a single place.

At compact widths, the actions move beneath the URL so Copy Link and Open retain their complete labels.

## API
```swift
CopyableURLRow(
    label: "Local Address",
    url: connectionURL,
    isStreamerMode: streamerMode,
    actionsDisabled: !websocketEnabled,
    copyAccessibilityLabel: "Copy local connection URL",
    copyAccessibilityIdentifier: "copyConnectionURLButton"
)

// With a trailing "Open in browser" accessory + "Copy Link" labelled button:
CopyableURLRow(
    url: widgetURL,
    isStreamerMode: streamerMode,
    actionsDisabled: !websocketEnabled || !widgetHTTPEnabled,
    urlLineLimit: 2,
    copyLabel: "Copy Link",
    copiedLabel: "Copied",
    copyAccessibilityLabel: "Copy widget URL",
    copyAccessibilityIdentifier: "copyWidgetURLButton"
) {
    OpenInBrowserButton(
        urlString: widgetURL,
        isDisabled: !websocketEnabled || !widgetHTTPEnabled || streamerMode,
        accessibilityLabel: "Open widget in browser"
    )
}
```

| Param | Type | Notes |
|---|---|---|
| `label` | `String?` | Leading label (e.g. "Local Address"). `nil` leads straight into the URL. |
| `url` | `String` | Real URL - copied + handed to `trailing` verbatim; the displayed text is masked first. |
| `subtitle` | `String?` | Helper line under the URL (e.g. "Use this for two-PC setups."). |
| `isStreamerMode` | `Bool` | Drives the mask, the badge, and the disabled state. Pass `@AppStorage` streamer-mode flag. |
| `actionsDisabled` | `Bool` | Extra disable gate beyond Streamer Mode (e.g. server stopped). Default `false`. |
| `actionsDisabledReason` | `String?` | Why `actionsDisabled` is on (e.g. "Turn on Stream Widgets to copy."). Becomes the tooltip and VoiceOver hint. Streamer Mode always shows its own fixed "Turn off Streamer Mode to copy." instead. |
| `urlLineLimit` | `Int?` | `nil` wraps freely; pass `2` for wide rows with no trailing label column. |
| `copyLabel` / `copiedLabel` | `String?` | When `nil`, the copy button renders icon-only. |
| `copyAccessibilityLabel` | `String` | VoiceOver label for the copy button. |
| `copyAccessibilityIdentifier` | `String?` | UI-test identifier for the copy button. |
| `trailing` | `@ViewBuilder () -> Trailing` | Optional accessory after the copy button (e.g. `OpenInBrowserButton`). Defaults to `EmptyView`. |

## Tokens used
- `DSFont.Size.sm` (11) - label / `DSFont.Size.body` (12) monospaced URL / `DSFont.Size.xs` (10) subtitle
- `DSSpace.s2` (8) - row + label + trailing-button gaps
- `DSSpace.s0` (2) - vertical rhythm inside the text column
- `DSDimension.Settings.inlineActionsMinWidth` (480) - minimum width for inline actions; narrower rows stack through `ViewThatFits`
- Delegates the copy affordance to `CopyButton` and masking to `StreamerMode.mask(_:style:.url:)`

## Anatomy
```mermaid
graph LR
  Row[HStack] --> Col[VStack - leading]
  Col --> LabelRow[Label + StreamerModeBadge - when masked]
  Col --> URL[Text - masked monospaced, textSelection]
  Col --> Sub[Subtitle - xs tertiary, optional]
  Row --> Spacer
  Row --> Trail[HStack: CopyButton + trailing accessory]
```

## Accessibility
- The copy button carries its own VoiceOver label + value (via `CopyButton`); the URL `Text` is selectable.
- `StreamerModeBadge` announces "Streamer Mode is on" so a masked value reads as intentional, not empty.
- Copy + trailing actions are disabled together when `actionsDisabled || isStreamerMode`, so a masked URL can never be copied.
- The disabled copy / trailing group carries `.help` with the reason ("Turn off Streamer Mode to copy." or `actionsDisabledReason`), and the same text goes to `CopyButton(disabledHint:)` so VoiceOver reads it on the button itself. A greyed-out button explains itself.
- Color is not the sole signal - the badge text and mask placeholder ("hidden (streamer mode)") both spell out the state.

## Do / Don't
- ✅ Use for any URL/endpoint a streamer might copy (WebSocket, widget webpage, network address).
- ✅ Pass the live `streamerMode` `@AppStorage` flag so the mask + disabled state track the toggle.
- ✅ Put extra trailing controls (open-in-browser) in the `trailing` slot, passing them the same `actionsDisabled || isStreamerMode` disabled state.
- ❌ Don't use it for secret tokens that should stay in a `SecureField` - this row always renders the value (masked) as selectable text.
- ❌ Don't wrap the URL in your own `StreamerMode.mask` before passing it - the row masks internally.

## Example
```swift
CopyableURLRow(
    label: "Network Address",
    url: networkConnectionURL,
    subtitle: "Use this for two-PC setups.",
    isStreamerMode: streamerMode,
    actionsDisabled: !websocketEnabled,
    actionsDisabledReason: "Turn on Stream Widgets to copy.",
    copyAccessibilityLabel: "Copy network connection URL",
    copyAccessibilityIdentifier: "copyNetworkConnectionURLButton"
)
```
