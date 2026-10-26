# Native settings spacing review

Reviewed 2026-10-25. Scope: the ten shipping settings panes, their shared shell,
and the request queue. This records source evidence separately from runtime
evidence; it is not a completed visual sign-off.

## Current outcome

The current implementation and remaining checklist are recorded in
[`TODO.md`](../../../TODO.md). Settings now opens directly from the App's SwiftUI
scene action; the hidden helper window and delayed lookup described in the
earlier investigation below have been removed. Targeted opening, keyboard
navigation, repeated close/reopen, and minimized-window restoration tests passed.
The latest 40-image matrix passed at 640-point minimum and 1240-point preferred
widths in both appearances. All ten compact layouts were visually reviewed.
The running signed build also demonstrated native left-half tiling and the
correct Light/Dark About artwork. All 2,098 unit tests passed.

The final full UI-suite attempts failed during macOS automation setup before any
test executed. Final compact snapshots after the last URL-row and artwork
refinements, menu-only reopening, live-account playback, and Nathanial's sign-off
remain pending. Earlier paragraphs below retain investigation history, including
superseded implementations and earlier test counts; they are not current gates.

## Second pass: card rhythm (2026-10-26)

Nathanial's report: in the Stream Deck "Allow Stream Deck commands" card the
toggle, its hint, the warning callout, and the "Open Stream Widgets" button
each had a different gap and a different left edge, and the button floated
outside the callout it belonged to. The CI screenshot matrix (`ideal-light` and
`minimum-dark`, Stream Deck and Stream Widgets) confirmed it: the hint sat flush
under a divider with no top gap, and the button hung below the callout on its
own edge.

The cause was structural, not one bad padding value. Cards built their rows by
hand (`Divider` + `.padding(.horizontal)` + `.padding(.bottom)`), and a callout's
fix was a sibling button the component catalog *required* to sit outside the box.
The fix moves the rhythm into shared components so call sites cannot drift:

| Piece | Rule now | Where it lives |
|---|---|---|
| A footnote about one switch | `ToggleSettingRow(hint:)`: a `HintRow` under the row, `DSSpace.s1h` below it, on the title's leading edge, outside the native `Toggle` | `ToggleSettingRow` |
| Siblings inside a card (row, callout, next control) | `AppConstants.SettingsUI.cardRowSpacing` (12) | `AppConstants.SettingsUI` |
| A callout's fix | `CalloutBanner { actions }`: buttons inside the box, on the message's text column, `.small`, `DSSpace.s2` gaps | `CalloutBanner`, and `ErrorCallout` through it |
| Callout icon | First-baseline aligned with the title or message; vertical inset `DSSpace.s3` | `CalloutBanner` |

Call sites moved onto those rules:

- Stream Deck control card: one padded card; footnote through the row; both
  "connection is off" and "Couldn't start" callouts carry their button inside.
- Stream Widgets server card: same shape (the reach summary is the switch's hint).
- Stream Widgets widget card: the disabled-switch note is the row's hint; the
  widget port now matches the overlay port (lock note above the field,
  validation under it, one row inset) instead of trailing hints with `s2` gaps.
- Song Requests: the playlist health banner's fix and the "Use Twitch Polls"
  re-auth note (now the toggle's hint rather than a line after the duration row).
- Song Requests setup sheet: Open Twitch Settings, Open System Settings, Try
  Again, and Check Again sit inside their callouts.
- Notifications (permission denied), App Visibility (Login Items error and
  approval), Advanced (crash recovery: Report a Bug and Dismiss).
- `ErrorCallout`, so `MusicPermissionBanner` and the Twitch expired notice
  follow suit without edits to their panes.

Seen but left alone in this pass:

- Software Update's content column sits a few points right of the other panes
  in the CI captures. It is the only pane short enough not to scroll, and CI
  shows legacy (always-visible) scrollers, so the scroller's gutter shifts the
  centered column on every other pane. Overlay scrollers (trackpad default)
  should not show it; not changed without a local comparison.
- Stream Deck's control-token card stacks an eyebrow, a 13-point paragraph, and
  a field title with its own caption: four text levels in one card.
- Song Requests' "Re-run setup" is a plain secondary text button under the
  enable switch, with no link affordance.
- The widget port field dims while the widget page is off, though it is only
  locked while it is on.

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
- [x] Capture all ten panes at the design minimum and preferred size, in Light and Dark. The latest native minimum frame is 640 x 672 (620-point content minimum plus chrome); preferred frames are 1240 x 780. Earlier captures used the former 880-point minimum.
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

A focused diagnostic rerun later exited with code 65 before any app test ran:
`Timed out while enabling automation mode`. The app did not launch in that run.
Read-only inspection of System Settings found no Xcode Helper entry in Device
Control and Data Access. That was treated as a suspected prerequisite, not
confirmed as the timeout's cause. No app test-mode changes were made based on
this environment failure.

On 2026-10-25, a fresh focused run of
`OnboardingUITests.testFirstLaunchOpensTheWizard` passed (one test, zero failures)
without any permission changes; Xcode Helper was still absent from the list.
The earlier missing-permission diagnosis was too strong. The prior runner
failure's underlying cause remains unconfirmed. A full UI-suite retry follows
the successful focused run.

The full retry exercised the History heading and queue-before-configuration
checks successfully. Its request-clear confirmation test failed because the
unscoped Cancel query matched multiple controls. The confirmation now has an
explicit accessibility identifier; the focused rerun passed. The final full
suite still needs to run after the matrix findings below are resolved.

The 40-image matrix passed its initial window-width and pane-containment
assertions. Visual inspection of the minimum Light and preferred Dark captures
then found truncated sidebar labels at the preferred size: the sidebar had
shrunk to roughly 144 points despite the 230-point column preference. The
sidebar content now also has the existing token as its fixed frame, and the
matrix asserts the accessible sidebar width on every pane. The final matrix
passed all 40 captures, and the repeated sidebar hide/show regression passed
again. The accessible list includes two points of native chrome, so the check
requires at least the 230-point content width rather than exact equality.
Fresh preferred-size Dark captures show complete navigation labels and aligned
720-point content columns. Initial geometry checks alone did not prove visual
quality.

The enabled Discord layout was also exercised using isolated UI-test defaults
with the IPC service suppressed. Its controls stack at the minimum window size,
and scrolling reveals the full preview without horizontal clipping. No live
Discord preference or connection was changed. A sidebar keyboard-navigation
check remains failing: Down Arrow after clicking General did not select Twitch,
including through computer-use automation against the signed build. A physical
keyboard check has not been performed. The main app menu also lacked
native Quit/Hide/Edit commands because the Settings scene removed its defaults.
Those commands have been restored. The signed development build showed native
Services, Hide, Hide Others, Show All, and Quit actions, and choosing Quit exited
the process; Command-Q also exited the process.

The keyboard-navigation cause remains unconfirmed. A separate minimal app using
the real sidebar, window configurator, toolbar, scrolling/accessibility wrapper,
and hidden Settings bridge handles arrow selection, including when sandboxed.
WolfWave still reproduced the failure with a minimal root view, with isolated
UI-test settings and credentials, and with startup setup skipped. Secure Event
Input was off. These checks do not support treating a Keychain permission change
as a prerequisite. Experimental navigation-link, binding, focus, root-view, and
test-mode changes were removed. The physical keyboard comparison remains open.
Two later focused UI runs failed before test execution while enabling automation
mode; those environment failures do not verify or contradict the app change.

A separate runtime probe found that the current SwiftUI Settings window carries
`.fullSizeContentView`. The Settings bridge had rejected that flag, skipping its
explicit window-fronting step. It now accepts that window while retaining its
normal-level, titled, key-capable checks and helper/onboarding exclusions. The
signed build passes; this correction alone did not resolve the arrow-key check.

The built Debug app also exposed a configuration mismatch: `LSUIElement` was
`true`, while Release already used `NO`. [Apple defines this key](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
as the agent-app setting. Debug now also uses `NO`, matching the existing runtime
Dock/menu policy. The rebuilt Debug plist was inspected and a hosted regression
was added against the packaged value. Launch Services registration was refreshed
for this one development bundle. The subsequent focused UI run again timed out
before the app launched, so it did not verify keyboard behavior after the change.

Final validation after the metadata correction: the signed Debug build passed,
all 2,095 unit tests passed (including the packaged-metadata regression), lint
reported zero violations, and sync checks passed. The docs build and all 45 docs
tests also passed. Both normal and test-host Debug plists contain `LSUIElement`
set to `false`. A direct computer-use check after the bundle registration refresh
still left General selected after Down Arrow. The normal signed app is open for
the pending physical-keyboard comparison; no further speculative focus changes
were retained. The latest UI runner failure occurred before any tests executed.

Process samples identified main-thread credential-lock waits during startup and
opening Twitch. These reads now suspend off the main actor. A rendered Twitch
loading screen and immediate navigation to Discord verified that the interface
remains responsive while the credential read is pending. The loading card uses
the existing skeleton and progress components. No Keychain password was entered
and no account or permission was changed for this review.
