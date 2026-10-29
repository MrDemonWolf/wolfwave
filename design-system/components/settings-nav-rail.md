# SettingsNavRail

**File:** [`apps/native/WolfWave/Views/Shared/SettingsNavRail.swift`](../../apps/native/WolfWave/Views/Shared/SettingsNavRail.swift)

## Purpose
Reusable two-column jump-navigation layout: a fixed rail on
the left and one always-mounted, scrollable content column on the right. Tapping a
rail row scrolls its section to the top; scrolling manually moves the highlight to
whatever section you land on. Replaces in-pane segmented tabs (which swapped
content) so a pane reads as one scroll with focused groups. No current Settings pane uses this layout. Debug displays one selected tool using a native list or compact picker instead.

## API
```swift
SettingsNavRail(
    selection: $selected,                                   // Binding<Section>
    groups: [SettingsRailGroup(sections: MySection.allCases)],
    accessibilityIDPrefix: "myNav"                          // → "myNav.<rawValue>"
) {
    Header().railSection(MySection.first)                   // anchor rides the header
    FirstCard()
    SecondCard().railSection(MySection.second)
    // …
}
```

`Section` conforms to **`SettingsRailSection`** (`Hashable, RawRepresentable where
RawValue == String`) supplying `title` (row label) + `icon` (SF Symbol). Tag the
top view of each section with `.railSection(_:)`; **pass the explicit enum case**
(`MySection.second`, not `.second`); the modifier is generic and can't infer the
type from a leading-dot member. Grouped rails pass several `SettingsRailGroup`s with
titles; flat rails pass one
group with a `nil` title.

`SettingsRailGroup` is `Identifiable`. Its `id` is the title plus the first section's raw
value, so `ForEach` keys groups by content, not by array offset: reordering or inserting
a group never hands one group's identity to another. A section belongs to exactly one
group, which keeps two untitled groups apart.

| Param | Type | Notes |
|---|---|---|
| `selection` | `Binding<Section>` | Highlighted row + scroll target. |
| `groups` | `[SettingsRailGroup<Section>]` | Ordered rail clusters; `nil` title = no eyebrow. `Identifiable` by title + first section. |
| `accessibilityIDPrefix` | `String` | Seeds each row id: `"<prefix>.<section.rawValue>"`. |
| `content` | `() -> Content` | `@ViewBuilder`; stacked sections, each top view tagged `.railSection(_:)`. |

## Tokens used
- `DSColor.info` × `DSOpacity.washStrong` (0.14): selected row highlight fill
- `DSColor.glyph(for: DSColor.info, in:)`: selected row text and icon. Light appearance resolves to `DSColor.glyphInfoLight` (`#0066CC`, about 4:1 or better on the highlight, where raw `DSColor.info` lands under 3:1); dark keeps `DSColor.info`
- `DSRadius.sm` (6): highlight pill corner
- `DSFont.Size.body` (12): row label (`.semibold` when selected)
- `DSSpace.s1`/`s2`/`s3`/`s4`/`s6`: rail row + container padding, icon frame
- `DSMotion.Duration.base` (0.22): tap scroll animation, via `withMotionSafeAnimation` so it is instant under Reduce Motion
- `AppConstants.SettingsUI.{maxContentWidth, contentPaddingH, contentPaddingV, sectionSpacing}`: content column geometry
- `DSDimension.Settings.navRailWidth` (184): rail width

## Anatomy
```mermaid
graph LR
  Root[SettingsNavRail] --> Reader[ScrollViewReader]
  Reader --> H[HStack]
  H --> Rail[Rail ScrollView, navRailWidth 184]
  H --> Div[Divider]
  H --> Col[Content ScrollView]
  Rail --> Group[ForEach groups by id: eyebrow .sectionEyebrow when title != nil]
  Rail --> Row[navRow Button.plain: icon + title, info glyph on washStrong pill + .isSelected when selected]
  Col --> LV[VStack content sectionSpacing]
  LV --> Sec[.railSection: .id + offset anchor]
  Col -. SectionOffsetPreferenceKey .-> Sync[syncSelection → selection]
  Row -. scrollTo + set selection .-> LV
```

## Accessibility
- Each rail row is a `Button` with `.help("Jump to <title>")` and
  `.accessibilityIdentifier("<prefix>.<rawValue>")` for UI tests.
- The selected row carries the `.isSelected` trait, so VoiceOver says "selected".
  Selection is never shown by color and weight alone.
- Reduce Motion: tapping a row jumps without the scroll animation
  (`withMotionSafeAnimation`).
- `.pointerCursor()`: flips to the pointing-hand cursor on hover.
- Selection follows both taps and manual scrolling, so the highlighted row always
  reflects the visible section.
- The content column clamps to `AppConstants.SettingsUI.maxContentWidth` for
  readable line lengths regardless of window size.

## Do / Don't
- ✅ Use when a future view needs scroll-synchronized jump navigation and owns its detail width. Do not add a second rail to the current Settings panes.
- ✅ Tag exactly one view per section with `.railSection(_:)`, the one that should
  sit at the top when its row is tapped (usually the section's first card or the
  page header for the top section).
- ✅ Pass the explicit enum case to `.railSection(MySection.case)`.
- ❌ Don't wrap the whole component in another `ScrollView`; it owns its scroll, and
  double-wrapping breaks the rail's full-height layout.
- ❌ Don't tag a transparent `Group` with `.railSection`; `.id` on a Group doesn't
  give `ScrollViewReader` a single target. Tag a concrete view.

## Example
```swift
private enum MySection: String, SettingsRailSection {
    case overview, details, advanced
    var title: String { /* … */ }
    var icon: String { /* … */ }
}

SettingsNavRail(
    selection: $selected,
    groups: [SettingsRailGroup(title: "Settings",
                               sections: [.overview, .details, .advanced])],
    accessibilityIDPrefix: "exampleNav"
) {
    OverviewCard().railSection(MySection.overview)
    DetailsCard().railSection(MySection.details)
    AdvancedCard().railSection(MySection.advanced)
}
```
