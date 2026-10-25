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

### Severity 3: credential reads freeze navigation

Process samples showed the main thread waiting on a credential lock both during
startup validation and after opening Twitch. A background Keychain read held the
lock while macOS waited for credential access. Moving the read into a main-actor
`Task` had not moved the blocking work off that actor.

Startup validation, reconnect reads, General's channel snapshot, and Twitch's
initial account read now use the concurrent executor. The Twitch account card
keeps its footprint with the existing skeleton and progress components. In the
rendered build, the loading indicator remained visible while navigation to
Discord completed immediately. This follows Apple's guidance to
[keep the main thread available for interaction](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

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
| Twitch | 16 -> 24 | Shared shell | Dark 900 x 672: loading; switching to Discord remained responsive |
| Discord | 16 -> 24 | Shared shell; responsive configuration and preview | Dark 900 x 672: disabled; enabled state pending |
| Stream Widgets | 24 | Shared shell | Dark 900 x 672: configured; credential initialization pending |
| Stream Deck | 24 | Shared shell | Dark 900 x 672: token-loading state |
| Song Requests | 24 | Own scroll; shared width and insets | Light and Dark 900 x 672: revised queue-first layout with permission warning; Dark 1920 x 970 also checked |
| History & Stats | 24 | Own scroll; shared width and insets | Light and Dark 900 x 672: disabled/empty, with the restored heading |
| Software Update | 16 -> 24 | Shared shell | Dark 900 x 672: development build; Homebrew state pending |
| Advanced | 16 -> 24 | Shared shell | Dark 900 x 672: default state |
| About | 16 -> 24 | Shared shell | Dark 900 x 672: default state |

### Severity 2: missing title and displaced task hierarchy

The rendered History & Stats pane began with a small privacy sentence rather
than a pane title. It now uses `SectionHeaderWithStatus`, preserving the privacy
message as its subtitle. The component catalog records the heading semantics.

In Song Requests, a permission warning appeared above the title, and the expanded
explainer and Vote-Skip controls preceded the queue. The title now comes first,
the explainer uses native disclosure, and an enabled queue appears before the
configuration controls. The warning remains immediately below the header. These
changes apply the alignment and grouping guidance cited above. Both revised
panes were rechecked in Light and Dark at 900 x 672.

## Remaining visual checks

- [x] Inspect all ten shipping panes at 900 x 672 in Light and Dark.
- [x] Recheck the revised History heading and request queue placement.
- [x] Check the centered, width-clamped General and Song Requests layouts at 1920 x 970.
- [ ] Capture all ten panes at 880 x 620 and 1240 x 780, in Light and Dark.
- [ ] Check long helper text, keyboard focus, and horizontal overflow.
- [ ] Check configured and empty states listed above without changing live accounts.
- [x] Compare section boundaries, title alignment, and card edges across the inspected states.
- [ ] Review the rendered changes with Nathanial before calling the spacing work complete.

The signed pane build, design-system lint, and docs-sync checks pass. All 2,094
native unit tests passed. After moving credential loading into its own extension,
the focused asynchronous credential-loading regression passed again. SwiftLint
reports zero violations against the baseline; regeneration reduced the baseline
from 453 to 452 entries, with no new rule/file/text locations. The UI suite
reached automation setup but timed out at app activation and was stopped.

Process samples identified main-thread credential-lock waits during startup and
opening Twitch. These reads now suspend off the main actor. A rendered Twitch
loading screen and immediate navigation to Discord verified that the interface
remains responsive while the credential read is pending. The loading card uses
the existing skeleton and progress components. No Keychain password was entered
and no account or permission was changed for this review.
