# Settings Redesign, Batch 2

The remaining panes plus the sidebar shell: **General (and its 4 hidden sub-panes), Stream Widgets, Software Update, About, Advanced**. Same format as [Batch 1](settings-redesign-batch1.md): 2 to 3 mockup options per surface, tied back to the 14-pattern competitive brief.

Batch 1 decisions are accepted and baked in here:

- Grouped `Form` is the pane skeleton (P3). Color cards survive for status, hero, banners, share cards only.
- One header style everywhere: `SectionHeaderWithStatus` (title + subtitle + one wired status chip).
- In-pane segmented tabs are a sanctioned pattern (used by Song Requests and History in Batch 1).
- Destructive actions live in a bottom danger zone (P11).

Mockup legend is the same as Batch 1 (`◉ ○ ◐ ⚠`, `●—` / `—○` switches, `[ ]` / `[[ ]]` / `[ ✕ ]` buttons, `‹ chip ›`, `▸/▾`, `〔 «active» 〕`, left-rail cards).

---

## What the inventory changed

Reading the real code moved three things from "assumed" to "known," and they reshape this batch:

1. **The sidebar is already grouped** (P2 is largely done). Real groups today: *(ungrouped)* General. **Integrations**: Twitch, Discord. **On Stream**: Stream Widgets, Song Requests. **Insights**: History & Stats. **App**: Software Update, Advanced, About, (Debug). So this batch refines the sidebar, it does not rebuild it.

2. **"General" is four panes wearing a trenchcoat.** Under one sidebar row it stacks **Music Sync + App Visibility + Appearance + Notifications**, separated by dividers. Appearance, App Visibility, and Notifications are *not reachable on their own*. This is the single biggest structural problem left, and it is the centerpiece below.

3. **General's status chip is fake.** It hardcodes a green "All systems live" string that is not wired to any real state. A status header that lies is worse than none (P4).

Smaller but real: Launch at Login and Software Update's "Check automatically" use `.checkbox` toggles while everything else uses `.switch`. Advanced already has a red Danger Zone card, but Clear Logs and Clear Artwork Cache still sit as destructive buttons in everyday cards above it.

---

# 0. Sidebar shell

**Today:** grouped `List(selection:)`, `.listStyle(.sidebar)`, width 200/230/280, the automatic sidebar toggle removed (your `>>` flash fix), a single toolbar sidebar-toggle button parked in the detail toolbar. Default pane `.general`.

The only real question here is what the General decision (Section 1) does to this list. Two shapes:

If General becomes a **tabbed pane** (Section 1, Option A, recommended), the sidebar barely changes:

```
  General                 gear
  ─ Integrations ─
  Twitch                  (brand)
  Discord                 (brand)
  ─ On Stream ─
  Stream Widgets          tv.badge.wifi
  Song Requests           music.note.list
  ─ Insights ─
  History & Stats         chart.bar.xaxis
  ─ App ─
  Software Update         arrow.down.circle
  Advanced                gearshape.2
  About                   info.circle
```

If General is **split into real panes** (Section 1, Option B), the list grows and regroups:

```
  Overview                square.grid.2x2
  ─ Now Playing ─
  Music                   music.note
  Look & Dock             paintbrush
  Notifications           bell
  ─ Integrations ─
  Twitch · Discord
  ─ On Stream ─
  Stream Widgets · Song Requests
  ─ Insights ─
  History & Stats
  ─ App ─
  Software Update · Advanced · About
```

- **Recommendation:** keep the sidebar essentially as-is and solve General with tabs (Option A). The current grouping is good. Growing to ~13 rows to fix one mega-pane trades one problem for sidebar sprawl. Reserve the split for later if any sub-pane grows its own depth.

---

# 1. General (the centerpiece)

**Today:** one sidebar row renders four stacked domains: **Music Sync**, **App Visibility**, **Appearance**, **Notifications**, divider-separated, behind a fake "All systems live" chip. It is effectively four settings screens in one scroll, with inconsistent header levels between the page (17pt) and its children (15pt).

The three options are real information-architecture choices.

### Option A. Tabbed General: Overview + Music + Look & Dock + Notifications (recommended)

One sidebar row, four focused tabs. The first tab is a true dashboard landing (P13) with a *wired* status header. The other three are the existing domains, each given room to be itself.

```
┌─ GENERAL ─────────────────────────────────────  ‹ 3 live · Music on ›
│ Where WolfWave tracks your music and shows up.
└───────────────────────────────────────────────

  〔 «Overview» · Music · Look & Dock · Notifications 〕

┌─ NOW PLAYING ─────────────────────────────────
│  ┌────┐  Howl at Dawn
│  │ art│  Timberwolf · Wolf Pack
│  └────┘  ▸ 1:24 ──────●─────── 3:58
└───────────────────────────────────────────────

┌─ WHERE IT IS SHOWING ─────────────────────────
│ Twitch chat ............... ‹ Live ›        ›
│ Discord profile ........... ‹ Showing now › ›
│ Stream Widgets ............ ‹ Ready ›       ›
│ Remote site (optional) .... ‹ Off ›         ›
└───────────────────────────────────────────────
   Each row jumps to that pane.
```

The status chip is now real: it reflects how many integrations are live and whether Music Sync is on, replacing the hardcoded string. "Music" tab content is Section 2, "Look & Dock" is Section 3, "Notifications" is Section 4.

- **Why:** P13 dashboard landing (you already have `IntegrationDashboardView` and `NowPlayingHeroCard` for exactly this), P4 a status header that tells the truth, sanctioned tabs keep the sidebar compact, and each domain stops fighting the others for one scroll.
- **Cost:** General gains tabs. Music Sync's own integration dashboard and the Overview "where it is showing" grid overlap, so pick one home for that grid (Overview), and Music tab drops it.

### Option B. Split into real sidebar panes

Promote the four domains to their own destinations: **Overview** (dashboard), **Music**, **Look & Dock**, **Notifications**. Most discoverable, every domain is one click from the sidebar.

```
  Overview  ▸  now-playing hero + what's-connected grid + quick links
  Music     ▸  Sync toggle + permission + hero
  Look&Dock ▸  theme tiles + launch-at-login + display mode
  Notify    ▸  song-change + skip-vote toggles
```

- **Why:** maximal clarity, no hidden panes, each surface trivially short. Matches how Raycast and System Settings give every domain its own row.
- **Cost:** sidebar grows to ~13 rows (Section 0, second mockup). Three of the new panes hold only 1 to 3 controls, which can feel thin as standalone destinations.

### Option C. Single scroll, fixed in place

Keep the stack. Wire the status chip to real state, unify the child headers to one level, and add an anchored mini-nav at the top that scroll-jumps to each domain.

```
┌─ GENERAL ─────────────────────────────────────  ‹ 3 live · Music on ›
│ Jump to:  Music · Look & Dock · Notifications
└───────────────────────────────────────────────
   (everything below stays one scroll, headers unified to 17pt)
```

- **Why:** smallest change, fixes the fake chip and header inconsistency without new navigation.
- **Cost:** still one long scroll bundling four domains. Does not solve the "hidden panes" discoverability problem.

**Recommendation: A.** It fixes the fake status, gives a real landing, keeps the sidebar compact, and reuses the dashboard primitives you already shipped. B is the alternative if you would rather have a flat, fully-discoverable sidebar and do not mind it growing.

---

# 2. Music (General ▸ Music tab, or its own pane)

**Today:** master "Sync Music" toggle (default on), then a permission status row whose trailing control has **three different layouts** depending on state (Recheck / Open System Settings / Allow+Open), a now-playing hero, and a 4-row integration dashboard. A denied state swaps in a red recovery banner.

### Option A. Master toggle + one adaptive permission row + hero (recommended)

Collapse the three permission layouts into one consistent row: a status icon, a one-line state, and exactly one primary action that changes label by state. Hero stays. The integration dashboard moves to General Overview (Section 1A) so it is not duplicated.

```
┌─ MUSIC ───────────────────────────────────────  ‹ Synced ›
│ Sync Music ...................................... ●—
│   Your Apple Music shows up in chat, on Discord,
│   and in your stream.
│ ───────────────────────────────────────────
│ ◉ Music access on ......................... [ Recheck ]
└───────────────────────────────────────────────

┌─ NOW PLAYING ─────────────────────────────────
│  ┌────┐  Howl at Dawn
│  │ art│  Timberwolf · Wolf Pack
│  └────┘  ▸ 1:24 ──────●─────── 3:58
└───────────────────────────────────────────────
```

Denied state, same row slot, one action (P8):

```
┌─ MUSIC ───────────────────────────────────────  ‹ Access needed ›
│ Sync Music ...................................... ●—
│ ───────────────────────────────────────────
│ ⚠ Music access off
│   Turn on Automation → Music in System Settings.
│                       [[ Open System Settings ]]
└───────────────────────────────────────────────
```

- **Why:** P7 master-first, P4 wired chip (Synced / Access needed / Off), P8 one clear recovery action, and the permission row stops shape-shifting between three layouts.
- **Cost:** the `.unknown` state currently shows two buttons (Allow + Open Settings). Collapsing to one primary (Allow) with Open Settings as a secondary text link is a small behavior decision to confirm.

### Option B. Music as a compact card on General Overview, no separate surface

If General stays tabbed (1A), Music is light enough to fold into the Overview tab as the top card, and skip a dedicated tab entirely. Overview then owns Sync + permission + hero + the connected grid.

- **Why:** fewer tabs, Music is the core so it belongs on the landing.
- **Cost:** Overview gets denser. Permission recovery UI shares space with the connected grid.

**Recommendation: A** as the Music tab content. The permission-row unification is the real win regardless of where it lives.

---

# 3. Look & Dock (merge Appearance + App Visibility)

**Today:** two separate child sections. Appearance = three preview tiles (System / Light / Dark). App Visibility = a `.checkbox` "Launch at Login" + a radio-group display mode (Dock and Menu Bar / Menu Bar Only / Dock Only), with Dock Only disabled while Launch at Login is on, explained by a banner.

These are both app-chrome preferences. Merge them into one short pane.

### Option A. One pane, three grouped sections (recommended)

```
┌─ LOOK & DOCK ─────────────────────────────────
│ Theme
│  ┌─────────┐ ┌─────────┐ ┌─────────┐
│  │ «System»│ │ Light   │ │ Dark    │
│  └─────────┘ └─────────┘ └─────────┘
│  System follows macOS, including the schedule.
│ ───────────────────────────────────────────
│ Show WolfWave in
│  ◉ Dock and Menu Bar     ○ Menu Bar Only
│  ○ Dock Only  (off while Launch at Login is on)
│ ───────────────────────────────────────────
│ Launch at Login ................................. —○
└───────────────────────────────────────────────
```

- **Why:** P3 grouped sections, one pane for one concern (how the app looks and where it lives). The Launch-at-Login / Dock-Only interdependency reads inline (the disabled radio explains itself) instead of via a separate banner. Switches over to `.switch` for consistency, dropping the lone `.checkbox`.
- **Cost:** the keep-it-a-checkbox crowd may prefer the macOS-classic checkbox for Launch at Login. Minor.

### Option B. Keep two sections, just merge the destination

Same content, but preserve the two distinct sub-headers ("Appearance", "App Visibility") under one pane rather than relabeling to "Look & Dock". Lower churn, same consolidation.

**Recommendation: A.** "Look & Dock" as one focused pane is cleaner than two thin sections, and the inline interdependency beats the banner.

---

# 4. Notifications (General ▸ Notifications tab, or its own pane)

**Today:** three `ToggleSettingRow`s (all default off): Song change, Skip vote started, Skip vote passed. The two skip-vote rows are disabled until vote-to-skip is enabled on the *Song Requests* pane, communicated only by a hint line. A permission-denied notice appears after enabling any toggle.

### Option A. Master toggle + grouped per-type, cross-pane dep made honest (recommended)

Add a master "Notifications" toggle, then group song alerts and stream alerts. Make the vote-skip dependency a real, actionable link instead of a passive hint.

```
┌─ NOTIFICATIONS ───────────────────────────────  ‹ On ›
│ Show notifications .............................. ●—
│   Heads-up in Notification Center as music plays.
│ ───────────────────────────────────────────
│ Song change ..................................... ●—
│   Album art + track each time the song changes.
│ ───────────────────────────────────────────
│ Stream alerts
│ Skip vote started .......................... —○ (locked)
│ Skip vote passed ........................... —○ (locked)
│   Needs vote-to-skip.  [ Turn on in Song Requests › ]
└───────────────────────────────────────────────
```

Permission-denied banner (when on but macOS auth denied, P8):

```
┌───────────────────────────────────────────────
│ ⚠ Notifications are off for WolfWave in macOS.
│                       [[ Open System Settings ]]
└───────────────────────────────────────────────
```

- **Why:** P7 master + dependents, and the cross-pane dependency becomes a button that takes you there, not a dead hint. Grouping separates "song" from "stream" alerts.
- **Cost:** the master toggle is a new control (today there is no master, each type is independent). Decide whether master-off hides or just disables the per-type rows (recommend disable-in-place, P7).

### Option B. Presets row: Quiet / Song only / All

A one-tap preset row on top (P9), granular toggles below, mirroring Song Requests' preset model.

```
│ Alerts:  〔 Off · «Song only» · All 〕
```

- **Why:** fastest path for the common choice.
- **Cost:** only three real toggles exist, so presets may be more machinery than the content warrants.

**Recommendation: A.** The actionable cross-pane link is the meaningful fix. Skip presets here (B) unless Notifications grows more types.

---

# 5. Stream Widgets

**Today:** the longest pane. Three cards: Server (enable, port, auth token + reveal/regenerate/copy, local + network URLs), Browser Source (enable widget webpage, advanced port, widget URL + open-in-browser, OBS sizing callout), Widget Appearance (theme, layout, colors, font). Status chip is already wired to live server state (good). Everyday actions (enable, copy URL) are mixed with advanced (custom port, custom token hex, regenerate) in one long flow.

### Option A. Everyday on top, Advanced folded, Regenerate to a danger foot (recommended)

Keep the single pane but stratify it. The 90% path (turn on, copy the URL into OBS) sits up top. Ports and token editing fold into an Advanced disclosure. Regenerate Token moves to a small danger group because it breaks live overlays.

```
┌─ STREAM WIDGETS ──────────────────────────────  ‹ 2 connected ›
│ Enable Stream Widgets ........................... ●—
│   Live song updates in your overlay.
│ ───────────────────────────────────────────
│ Overlay URL (paste into OBS Browser Source)
│   ws://localhost:8765/?token=••••••      [ Copy ]
│ Network (two-PC) .. ws://192.168.1.20:… [ Copy ]
└───────────────────────────────────────────────

┌─ WIDGET WEBPAGE ──────────────────────────────
│ Enable Widget Webpage ........................... —○
│   Hosts the page you add to OBS.
│   http://localhost:8766          [ Copy ] [ Open ]
│   In OBS set size to 400 x 120, "Shutdown source
│   when not visible".
└───────────────────────────────────────────────

┌─ APPEARANCE ──────────────────────────────────
│ Theme 〔 Default ▾ 〕      Layout 〔 Horizontal ▾ 〕
│ Text ⬛   Background ⬛        Font 〔 System ▾ 〕
└───────────────────────────────────────────────

▸ Advanced  (custom ports, auth token)

┌─ DANGER ──────────────────────────────────────
│ [ Regenerate auth token ✕ ]
│   Breaks every connected overlay until you re-copy
│   the new URL into OBS.
└───────────────────────────────────────────────
```

Expanded Advanced disclosure:

```
▾ Advanced
│ Server port ....... [ 8765 ]   (disable server to edit)
│ Widget port ....... [ 8766 ]
│ Auth token ........ ••••••••  [ 👁 ] [ Copy ]
└──────────────────────────────────────────────
```

- **Why:** P3 grouping, P8 the everyday surface is just enable + copy, P10 advanced lives behind a disclosure, P11 regenerate is correctly framed as destructive (it does break overlays). Status chip already follows P4.
- **Cost:** the Advanced fold has to keep its cascading disabled states (server off disables ports/URLs) legible while collapsed. Streamer Mode masking still applies throughout.

### Option B. Tabbed: Overlay · Webpage · Appearance

Use the sanctioned tab pattern to split the three cards into three tabs, each short.

```
  〔 «Overlay» · Webpage · Appearance 〕
```

- **Why:** consistent with Song Requests / History tabs, makes each surface tiny.
- **Cost:** the OBS setup story spans Overlay + Webpage, so a streamer setting up for the first time tabs back and forth. The disclosure (A) keeps the setup flow on one scroll.

**Recommendation: A.** Setup is a single linear flow, so a stratified single pane beats tabs here. Regenerate-to-danger and the Advanced fold are the wins.

---

# 6. Software Update

**Today:** header "Software Update" / "Check for new versions...", then a card that *also* says "Software Update" (duplicate). Branches by install method. DMG/Sparkle card: current version, an optional accent "vX available" capsule, a status callout (auto on / auto off / dev build), a `.checkbox` "Check automatically", and a "Check Now" button. Homebrew card: version + info banner + `$ brew upgrade wolfwave` mono row with copy. No status chip in the header.

### Option A. Status-chip header, drop the duplicate title, switch idiom (recommended)

Put the real state in the header chip (Up to date / Update available / Auto-updates off), kill the repeated card title, and make "Check automatically" a `.switch`.

```
┌─ SOFTWARE UPDATE ─────────────────────────────  ‹ Up to date ›
│ WolfWave 2.4.1
│ ───────────────────────────────────────────
│ Check automatically ............................. ●—
│   We will notify you when a new version is ready.
│                                      [ Check now ]
└───────────────────────────────────────────────
```

Update-available state:

```
┌─ SOFTWARE UPDATE ─────────────────────────────  ‹ v2.5.0 ready ›
│ WolfWave 2.4.1  →  2.5.0
│ ───────────────────────────────────────────
│ [[ Install update ]]      [ What is new ]
│ Check automatically ............................. ●—
└───────────────────────────────────────────────
```

Homebrew install:

```
┌─ SOFTWARE UPDATE ─────────────────────────────  ‹ Homebrew ›
│ WolfWave 2.4.1
│ Updates are managed by Homebrew.
│   $ brew upgrade wolfwave              [ Copy ]
└───────────────────────────────────────────────
```

- **Why:** P4 a header chip that reflects real update state, removes the duplicate "Software Update" title, and unifies the toggle idiom to `.switch`. The update-available state gets a real primary action (Install) instead of just a passive capsule.
- **Cost:** "Install update" wiring depends on Sparkle's flow (today the pane only checks; installing happens in Sparkle's own dialog). May stay "Check now" + let Sparkle drive, with the chip still doing the status work. Confirm how far to push the in-pane install affordance.

### Option B. Minimal: fix the chip and the duplicate title only

Keep the card as-is, just add the wired header chip and drop the repeated title. Leave the checkbox.

**Recommendation: A**, minus the in-pane "Install" button if that fights Sparkle's own flow. The chip + de-duplicated title + switch are safe wins.

---

# 7. About

**Today:** four `cardStyle()` cards: Identity (app name, version pill that copies), Quick actions (`ActionGrid`: Release Notes, Website, Send Feedback, Sponsor), Links & legal (Documentation / Privacy / Terms + notices), Acknowledgements (third-party + open source + full licenses link). Clean already. Only real issue: in-card group titles use ad-hoc base/semibold `Text` instead of the standard sub-header.

### Option A. Same content, standardized headers + tighter identity (recommended)

```
┌─ ABOUT ───────────────────────────────────────
│  WolfWave 2.4.1                       [ Copy ]
│  By MrDemonWolf, Inc.
└───────────────────────────────────────────────

┌─ QUICK ACTIONS ───────────────────────────────
│  [ Release Notes ]   [ Website ]
│  [ Send Feedback ]   [ Sponsor ]
└───────────────────────────────────────────────

┌─ LINKS & LEGAL ───────────────────────────────
│  Documentation · Privacy · Terms
│  Independent project. Not affiliated with Apple,
│  Twitch, or Discord. © 2026 MrDemonWolf, Inc.
└───────────────────────────────────────────────

┌─ ACKNOWLEDGEMENTS ────────────────────────────
│  Services: Twitch · Discord · Apple Music · Odesli
│  Open source: Sparkle      [ Full licenses › ]
└───────────────────────────────────────────────
```

- **Why:** P3/consistency. Just brings About's headers in line with the rest. Everything else stays.
- **Cost:** essentially none. The lowest-risk pane.

### Option B. Collapse to two cards

Merge Identity + Quick actions, and Links + Acknowledgements, for a shorter pane.

**Recommendation: A.** About is fine. Standardize the headers and move on.

---

# 8. Advanced

**Today:** Setup Wizard card, Diagnostics card (export / copy / reveal logs + Clear Logs destructive), Artwork Cache card (+ Clear Artwork Cache destructive), a diagnostics share card, Back Up Settings card (export / import), then a red Danger Zone card with Reset All Settings. So three destructive actions exist, but only one lives in the Danger Zone; the other two sit in everyday cards.

### Option A. Everyday maintenance up top, all destructive consolidated into the Danger Zone (recommended)

Pull Clear Logs and Clear Artwork Cache down into the existing red Danger Zone next to Reset. Everyday actions (export logs, copy, reveal, backup, rerun wizard) stay neutral up top.

```
┌─ ADVANCED ────────────────────────────────────
│ Maintenance
│  [ Rerun Setup Wizard ]
│ ───────────────────────────────────────────
│ Logs ........................ 142 KB · 1,204 lines
│  [ Export Logs ] [ Copy ] [ Reveal in Finder ]
│ ───────────────────────────────────────────
│ Artwork cache ............... 38 tracks · 6.1 MB
│ ───────────────────────────────────────────
│ Back up settings
│  [ Export Settings ]  [ Import Settings ]
│  Accounts and secrets are not included.
└───────────────────────────────────────────────

┌─ DANGER ZONE ─────────────────────────────────  (red)
│ ⚠ These cannot be undone.
│  [ Clear Logs ✕ ]
│  [ Clear Artwork Cache ✕ ]
│  [ Reset All Settings to Defaults ✕ ]
└───────────────────────────────────────────────
```

- **Why:** P11 done properly. Every irreversible action sits in one clearly-marked, red, confirmed zone. Everyday maintenance reads calmly above. The size/line stats stay on their neutral cards.
- **Cost:** moving Clear Logs away from the log export buttons separates two related actions by a screen. Acceptable: export is safe, clearing is not, and that is exactly the distinction the danger zone exists to make.

### Option B. Keep destructive in-card, but make all three look destructive

Leave Clear Logs and Clear Artwork Cache where they are, but give them the same red `DestructiveButton` + confirm treatment and a small "danger" tag, so at least the styling is consistent even if placement is not.

- **Why:** keeps related actions adjacent (clear sits next to export).
- **Cost:** danger is still scattered across the pane, which is the thing P11 warns against.

**Recommendation: A.** Consolidate. A single danger zone is the whole point, and Advanced already has one to grow into.

---

## Batch 2 decisions for you

1. **General:** tabbed pane (1A, recommended) or split into real sidebar panes (1B)?
2. **Software Update:** push an in-pane "Install update" button (6A) or keep "Check now" and let Sparkle drive, with just the chip + cleanup?
3. **Look & Dock:** keep Launch at Login as a `.switch` (consistency) or preserve the macOS-classic `.checkbox`?
4. **Advanced:** consolidate all three destructive actions into the Danger Zone (8A, recommended), or keep them in-card with consistent styling (8B)?

---

## Where this leaves all 11 panes

| Pane | Direction |
|---|---|
| Twitch | B1: status header + grouped Form + quiet disconnect |
| Discord | B1: two-column, controls left + live preview right |
| Song Requests | B1: in-pane tabs + preset front door |
| History & Stats | B1: fix first-run + danger zone now, tabs later |
| General | B2: tabbed Overview + Music + Look & Dock + Notifications, wired status |
| Music | B2: master toggle + one adaptive permission row + hero |
| Look & Dock | B2: merged theme + dock + launch, inline interdependency |
| Notifications | B2: master + grouped, actionable cross-pane link |
| Stream Widgets | B2: everyday up top, Advanced folded, Regenerate to danger |
| Software Update | B2: wired chip, de-duplicated title, switch idiom |
| About | B2: standardize headers, otherwise keep |
| Advanced | B2: consolidate all destructive into the Danger Zone |

Answer the four decisions above (and the Batch 1 open questions if you have not) and the next step is implementation. Suggested build order, smallest blast radius first: shared header/danger-zone primitives, then the easy wins (About, Software Update, Look & Dock), then the integration panes (Twitch, Discord, Stream Widgets), then the tabbed restructures (General, Song Requests, History). Each is its own PR.
