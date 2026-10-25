# Native settings spacing review

Reviewed 2026-10-24. Scope: the ten shipping settings panes, their shared shell,
and the request queue. This records source evidence separately from runtime
evidence; it is not a completed visual sign-off.

## References and approach

- [Apple layout guidance](https://developer.apple.com/design/human-interface-guidelines/layout)
  recommends consistent layouts and deliberate alignment to communicate hierarchy.
- [NN/g visual hierarchy](https://www.nngroup.com/articles/visual-hierarchy-ux-definition/)
  explains using larger gaps between groups and smaller gaps within related content.
- [Apple Music account settings on Mobbin](https://mobbin.com/screens/a04a3459-6fc8-4855-a89a-3ede86081fb2)
  provides an inspected native reference for grouping rows and placing helper copy
  next to its setting. This is an iOS reference for hierarchy, not a macOS sizing
  specification. Mobbin's search interface offers iOS and web, not macOS.

WolfWave's own tokens determine dimensions: a 720-point maximum content column,
28-point horizontal inset, 22-point vertical inset, 24-point section gap, and
16-point card padding. See `design-system/tokens.json`; generated Swift is not
edited directly.

## Findings

### Severity 2: inconsistent gaps between peer sections

**Trigger:** switching between General or Stream Widgets and Twitch, Software
Update, Advanced, or About changes the gap between peer sections from 24 to 16
points. Discord's gap between its connection card and configuration area also
uses 16 points.

**Evidence:** the five affected pane roots used `DSSpace.s6`, while General,
Stream Widgets, Stream Deck, History & Stats, and the settings shell used
`AppConstants.SettingsUI.sectionSpacing` (24). The shell wraps each pane as one
child, so its outer stack cannot override the pane's internal gaps.

**Impact:** peer sections use different visual grouping across panes. This is a
source-confirmed consistency defect; the perceived improvement still needs a
rendered comparison. It maps to consistency and visual hierarchy, using the
Apple and NN/g references above.

**Change:** the five pane roots now use the existing section-spacing token.
Song Requests references that same token instead of its equivalent `DSSpace.s8`.
Nested Discord controls retain their 16-point grouping gap. Card padding, row
spacing, and responsive columns retain their existing roles.

## Pane coverage

| Pane | Root section gap | Content geometry | Runtime evidence |
|---|---|---|---|
| General | 24 | Own scroll; shared width and insets | Dark screenshot inspected at 900 x 672; no revised root gap |
| Twitch | 16 -> 24 | Shared shell | Revised screen pending |
| Discord | 16 -> 24 | Shared shell; responsive configuration and preview | Enabled and disabled states pending |
| Stream Widgets | 24 | Shared shell | Pending |
| Stream Deck | 24 | Shared shell | Token-loading and loaded states pending |
| Song Requests | 24 | Own scroll; shared width and insets | Configured, disabled, loading, and error states pending |
| History & Stats | 24 | Own scroll; shared width and insets | Empty, loading, and populated states pending |
| Software Update | 16 -> 24 | Shared shell | Direct-download and Homebrew states pending |
| Advanced | 16 -> 24 | Shared shell | Pending |
| About | 16 -> 24 | Shared shell | Pending |

## Remaining visual checks

- [ ] Capture all ten panes at 880 x 620 and 1240 x 780, in Light and Dark.
- [ ] Check long helper text, keyboard focus, and horizontal overflow.
- [ ] Check configured and empty states listed above without changing live accounts.
- [ ] Compare section boundaries, title alignment, and card edges across panes.
- [ ] Review the rendered changes with Nathanial before calling the spacing work complete.

The signed build compiles. Runtime inspection is currently blocked during macOS
sandbox-container initialization after the app's signing identity changed. The
system confirmation needs a manual response. Do not infer visual success from
a passing build or from a screenshot of a different pane.
