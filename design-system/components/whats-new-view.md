# WhatsNewView

**File:** [`apps/native/WolfWave/Views/Shared/WhatsNewView.swift`](../../apps/native/WolfWave/Views/Shared/WhatsNewView.swift)

## Purpose
"What's New" sheet shown once per version after onboarding completes. Header + scrollable feature list + a single "Got it" CTA.

## API
```swift
WhatsNewView(onClose: (() -> Void)? = nil)
```

| Param | Type | Notes |
|---|---|---|
| `onClose` | `(() -> Void)?` | Closes the hosting window. `AppDelegate.showWhatsNew()` hosts the view in an `NSWindow`, where `@Environment(\.dismiss)` does nothing, so it passes `{ whatsNewWindow?.close() }`. When `nil` (a sheet or a preview) the CTA calls `dismiss()`. |

Otherwise self-contained. The version string is read from `Bundle.main.infoDictionary?["CFBundleShortVersionString"]`. The feature list is hardcoded inside the view and updated each release.

## Feature row shape
```swift
(icon: String, iconColor: Color, title: String, description: String)
```

Example entries (current release):
- `"music.mic"` · `.pink` · *Song Requests*: viewers request songs with `!sr`
- `"sparkles"` · `.indigo` · *Liquid Glass Redesign*: refreshed for macOS 26 Tahoe

## Tokens used
- `.sectionHeader()` view modifier: title typography
- `DSFont.Size.base` (13) `.secondary`: header tagline + feature title
- `DSFont.Size.body` (12) `.secondary`: feature description
- `DSFont.Size.xl` (20) icons in 36×36 colour-tinted tiles (`opacity 0.12` background, `DSRadius.md` 8)
- `.borderedProminent` + `.controlSize(.large)`: "Got it" CTA, bound to Return (`.keyboardShortcut(.defaultAction)`)
- `.cardStyle()` per row
- `DSSpace.s5`-ish (14): row internal spacing
- `DSSpace.s7` (20): outer VStack spacing
- Frame: `idealWidth 420 × idealHeight 540`

## Anatomy
```mermaid
graph TB
  Sheet[VStack spacing 20 padding 24] --> Header[VStack spacing s1h=6]
  Header --> Title[Text, version sectionHeader]
  Header --> Tagline[Text, Highlights from this release base secondary]
  Sheet --> List[ScrollView]
  List --> Rows[ForEach features → featureRow]
  Sheet --> CTA[Button Got it, borderedProminent large]
  Rows --> Row[HStack spacing 14 cardStyle]
  Row --> IconTile[36×36 tinted RoundedRectangle, SF Symbol 20pt]
  Row --> RowText[VStack, title 13 semibold / description 12 secondary]
```

## Accessibility
- Each feature row uses `accessibilityElement(children: .combine)` and labels as `"<title>. <description>"`.
- CTA has `accessibilityIdentifier("whatsNew.gotIt")` and a hint. Its visible title is the label, so no custom `accessibilityLabel` repeats it. Return activates it.
- Rows have stable identifiers (`whatsNew.feature.<title>`) for UI tests.

## Do / Don't
- ✅ Update the `features` array per release; keep it ≤ 10 entries.
- ✅ Use past-tense, viewer-facing copy in `description`.
- ❌ Don't add a Skip button; `dismiss` is sufficient and matches the Apple sheet idiom.
- ❌ Don't show this sheet without first checking the per-version "shown" flag in `UserDefaults`.

## Example
```swift
// In an NSWindow (what the app does): pass a close closure.
WhatsNewView(onClose: { window.close() })

// As a sheet: `dismiss` handles it.
.sheet(isPresented: $showWhatsNew) {
    WhatsNewView()
}
```
