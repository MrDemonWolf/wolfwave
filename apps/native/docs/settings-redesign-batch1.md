# Settings Redesign, Batch 1

Layout exploration for the four heaviest settings panes: **Twitch, Song Requests, Discord, History & Stats**. Each page gets 2 to 3 mockup options with the tradeoffs, grounded in a competitive scan of macOS menu-bar utilities, streaming tools, and Apple's own System Settings.

This is a proposal doc. Nothing here is built yet. Pick a direction per page and I will turn it into SwiftUI.

Batch 2 (the other 7 panes plus the sidebar shell) comes after you react to these.

---

## How to read the mockups

All wireframes use one ASCII vocabulary:

```
Legend
  ◉ connected / on        ○ off / disconnected      ◐ connecting / working     ⚠ action needed
  ●—  switch ON           —○  switch OFF             ........  dotted leader to a value/control
  [ Label ]   button (bordered)     [[ Label ]]  primary (filled)     [ Label ✕ ]  destructive
  ‹ Chip ›    status chip            ▸ / ▾  collapsed / expanded group
  〔 a · b · c 〕  segmented control, «active» tab marked
  ┌─ … └─    a card / section in the scrolling detail pane (left rail, no right border, for legibility)
```

Cards are drawn with a left rail and no right border on purpose. It keeps long mockups aligned and readable. In the real app these are normal grouped sections, not literal ASCII boxes.

---

## What other apps do (the short version)

Full brief with sources lives at the end. The 14 patterns that drive these mockups:

| # | Pattern | Seen in | WolfWave move |
|---|---|---|---|
| P2 | Group the sidebar once you pass ~7 rows | System Settings, OBS, CleanShot X | 11 flat rows become 3 to 4 labeled groups |
| P3 | Per-pane body is a grouped `Form`, not free-floating cards | Apple HIG, System Settings | Adopt `Form().formStyle(.grouped)` as the skeleton |
| P4 | Status header at the top of each integration pane | Streamer.bot, Restream, Raycast | One status line per pane, not five chips |
| P5 | Connect is a primary action, Disconnect is quiet and reversible | Raycast, Restream | Log Out / Disconnect leaves the everyday button row |
| P7 | Master toggle first, dependents disable in place (dim, do not vanish) | iStat Menus 7, AlDente | Stops the page from jumping as you toggle |
| P8 | "Feature is off" shows a short explainer, not a blank or a wall of dimmed rows | NN/g, Raycast | Off-state teaches and offers the one action |
| P9 | One-tap presets above the granular toggles | CleanShot, your own `SongRequestPreset` | Surface presets at the top |
| P11 | Destructive actions in a bottom danger zone, verb-labeled, confirmed | GitHub danger zone | Clear / Reset / Regenerate leave the common path |
| P12 | Flat inset-grouped lists are the base, color/glass cards only carry meaning | System Settings Tahoe | Matches your cards-no-glass decision (PR #227 reversal) |
| P13 | Dashboard landing: summary first, details on demand | AlDente, Restream | Glanceable status, deep config one level down |
| P14 | Quiet section headers + footer help text carry the explaining | Apple HIG | ADHD-friendly one-liners as `Section` footers |

Two cross-cutting takeaways:

1. **None of the four pages use `Form` today.** They are hand-rolled `VStack`s of `.cardStyle()`. Moving to grouped `Form` is the single biggest consistency win and it is the macOS-native default. Color cards (Discord status, Now-Playing hero, warning banners, share cards) stay as cards. Neutral config stops being a card.
2. **Header treatment is inconsistent across pages.** Twitch / Song Requests / Discord use `SectionHeaderWithStatus`; History & Stats uses an icon eyebrow with no chip; some Song Request cards use a bare bold `Text`. Pick one and apply everywhere.

---

# 1. Twitch

**Today:** one monolithic state-machine card. Disconnected shows almost nothing (a single Connect button). Connected shows three small buttons sharing one row (Join/Leave, Test Login, Log Out), with Log Out (destructive) sitting next to everyday actions. Channel name, verify state, and connection state are three separate micro-indicators stacked in one row. No status header beyond the chip.

Pain points: destructive action mixed into the action cluster (breaks P5/P11), no single connection summary, almost-empty disconnected state with no explainer (breaks P8).

### Option A. Status header + grouped Form (recommended)

The HIG-native shape. A status header owns the connection truth, then quiet grouped sections for Channel, Bot, and a foot for the reversible Disconnect.

```
┌─ TWITCH ─────────────────────────────────────  ‹ Connected ›
│ ◉  Signed in as @wolfpup_live
│    Posting commands in #wolfpup_live
└───────────────────────────────────────────────

┌─ CHANNEL ─────────────────────────────────────
│ Channel ......................... #wolfpup_live  ◉
│ Status .......................... Verified  ✓
│                                   [ Leave channel ]
└───────────────────────────────────────────────

┌─ BOT ─────────────────────────────────────────
│ Bot account ..................... WolfWaveBot
│ Sign-in health .................. Healthy
│                                   [ Test login ]
└───────────────────────────────────────────────
   Checks that your Twitch sign-in still works.

┌───────────────────────────────────────────────
│ [ Disconnect Twitch ✕ ]
└───────────────────────────────────────────────
   Reversible. Removes chat commands until you reconnect.
```

Disconnected state (P8 explainer, not a near-blank card):

```
┌─ TWITCH ─────────────────────────────────────  ‹ Not connected ›
│ Let viewers see what is playing with chat commands
│ like !song and !last, and run song requests.
│
│            [[ Connect with Twitch ]]
└───────────────────────────────────────────────
   Opens twitch.tv/activate with a one-time code.
```

- **Why:** P4 status header, P5 quiet disconnect at the foot, P3 grouped Form, P8 real empty state, P14 footer help.
- **Cost:** restructures the connected card into three sections. The auth state machine logic is unchanged, only its presentation.

### Option B. At-a-glance tile dashboard

Leans dashboard (P13). Connected state becomes a 2-up tile grid you can scan in a second, each tile drilling into detail.

```
┌─ TWITCH ─────────────────────────────────────  ‹ Connected ›
│ ◉  @wolfpup_live
└───────────────────────────────────────────────

┌─ CHANNEL ──────────────┐  ┌─ BOT ──────────────┐
│ #wolfpup_live          │  │ WolfWaveBot        │
│ ◉ Verified             │  │ ◉ Healthy          │
│ [ Leave ]              │  │ [ Test login ]     │
└────────────────────────┘  └────────────────────┘

┌─ CHAT COMMANDS ────────┐  ┌─ AUTH ─────────────┐
│ !song  !last  ◉ on     │  │ Token OK           │
│ 2 enabled              │  │ Renews silently    │
│ ▸ Configure            │  │ [ Disconnect ✕ ]   │
└────────────────────────┘  └────────────────────┘
```

- **Why:** P13 glanceable, P4 status, uses your existing `IntegrationDashboardView` primitive and `ResponsiveRow` (collapses to one column on narrow windows).
- **Cost:** more layout surface to build and maintain. Slight risk of feeling busy for a page with only a few real controls. Tiles must stay short or they look padded.

### Option C. Refined single card (lowest effort)

Keep the one-card state machine. Only fix the hierarchy: a header row, a divider, labeled value rows, then a clearly-separated action row, with Log Out pulled to a destructive footer.

```
┌─ TWITCH ─────────────────────────────────────  ‹ Connected ›
│ ◉  @wolfpup_live
│ ───────────────────────────────────────────
│ Channel ......... #wolfpup_live   Verified ✓
│ Bot ............. WolfWaveBot
│ ───────────────────────────────────────────
│ [ Leave channel ]   [ Test login ]
│
│                              [ Log out ✕ ]
└───────────────────────────────────────────────
```

- **Why:** smallest diff, still fixes the P5/P11 violation (Log Out leaves the cluster) and adds row labels.
- **Cost:** does not adopt Form or a real status header, so Twitch stays visually different from the rest of the app. Stopgap, not the destination.

**Recommendation: A.** It is the native shape, fixes every pain, and sets the template (status header + grouped sections + quiet danger foot) that Discord and Song Requests then reuse.

---

# 2. Song Requests

**Today:** the longest page by far. Master toggle, then up to ~8 stacked cards separated by thin dividers: Chat Vote-Skip, Music Auth, live Queue, Queue Settings, Who Can Request, Channel Points & Bits, Playback, Commands, Blocklist. Easily 40+ controls when fully enabled. Heavy progressive disclosure makes the page height swing wildly.

Pain points: one flat scroll with no sub-grouping or landing summary (breaks P13), cooldowns configured in two different places with two different control idioms, destructive actions (Clear blocklist, Recreate Reward, Clear Queue) interleaved among config (breaks P11), three different section-header styles on one page.

This page needs real structure. The three options are genuinely different information architectures, not restyles.

### Option A. In-pane sub-navigation (recommended)

Split the pane with a segmented control. The everyday surface (master toggle, preset, live queue) is always on top under **Overview**; the deep config is filed under focused tabs. Tames the 40-control scroll into five short forms.

```
┌─ SONG REQUESTS ──────────────────────────────  ‹ Live · 3 queued ›
│ Enable song requests ............................ ●—
│ Preset:  〔 «Chill» · Subs only · Points only · Custom 〕
└───────────────────────────────────────────────

  〔 «Overview» · Who can request · Queue · Commands · Channel points 〕

┌─ NOW PLAYING ─────────────────────────────────
│ ▶ Howl at Dawn · Timberwolf       requested by @ash
│ ───────────────────────────────────────────
│ 1. Moonlit Run · Greywolf         @kai      ✕
│ 2. Den Song · Arctic              @sam      ✕
│ 3. Pack Call · Redwolf            @lux      ✕
│ ───────────────────────────────────────────
│ [ Skip ]   [ Hold ]   [ Clear queue ✕ ]
└───────────────────────────────────────────────
```

Selecting **Who can request** swaps the lower region:

```
  〔 Overview · «Who can request» · Queue · Commands · Channel points 〕

┌─ AUDIENCE ────────────────────────────────────
│ !sr is open to ............ 〔 Everyone ▾ 〕
│                             Mods and you always can.
└───────────────────────────────────────────────

┌─ VOTE-SKIP ───────────────────────────────────
│ Chat vote-skip .................................. ●—
│ Votes to skip ............. 〔 3 ▾ 〕
│ Subscriber-only voting .......................... —○
│ Use Twitch Polls .............................. —○
│ Vote window ............... 〔 30 · «60» · 90 · 120 s 〕
│ Cooldown between votes .... [——●———] 30s
└───────────────────────────────────────────────
```

- **Why:** P13 summary-first (live queue is the thing you actually watch), P9 preset on top, P7 master toggle first, P11 isolates destructive (Clear queue stays with the queue, Recreate Reward and Clear blocklist file under their own tabs). Cooldowns consolidate because vote-skip and command cooldowns now sit in their owning tabs with one slider idiom.
- **Cost:** introduces in-pane tabs, which no other pane has. If it feels heavy, the same split works as a third sidebar column (3-column `NavigationSplitView`) but that is a bigger shell change. Tabs are the lighter call.

### Option B. One scroll, collapsible groups

Keep the single page but give every cluster a labeled, collapsible `DisclosureGroup`. Preset and master toggle pinned on top. The page starts mostly collapsed so its resting height is small and predictable.

```
┌─ SONG REQUESTS ──────────────────────────────  ‹ Live · 3 queued ›
│ Enable song requests ............................ ●—
│ Preset:  〔 «Chill» · Subs only · Points only · Custom 〕
└───────────────────────────────────────────────

┌─ LIVE QUEUE ──────────────────────────────────
│ ▶ Howl at Dawn · Timberwolf       @ash
│ 3 queued        [ Skip ] [ Hold ] [ Clear ✕ ]
└───────────────────────────────────────────────

▾ Who can request ........................ Everyone
▸ Queue limits ........................... 10 max · 2 per user
▸ Commands ............................... 5 enabled
▸ Channel points & bits .................. Off
▸ Vote-skip .............................. On · 3 votes
▸ Playback ............................... Auto-advance on
▸ Blocklist .............................. 2 blocked
─────────────────────────────────────────────────
[ Advanced: cooldowns, aliases, fallback playlist ]
─────────────────────────────────────────────────
```

- **Why:** P7 dependents collapse instead of dimming a wall, P13 the value (queue) is up top, every group is one consistent header style. Keeps a single scroll for people who like Cmd-F-style scanning. Each collapsed row shows a live summary value on the right (P14).
- **Cost:** disclosure state to persist, and a fully-expanded page is still long. Better than today, not as calm as A.

### Option C. Presets-first, "simple by default"

Optimize for the majority who just pick a preset and walk away. The resting page is tiny: preset picker, master toggle, live queue. Everything granular hides behind one **Customize** push.

```
┌─ SONG REQUESTS ──────────────────────────────  ‹ Live · 3 queued ›
│ Enable song requests ............................ ●—
│
│  Pick how requests work:
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────┐
│  │ «Chill»  │ │ Subs     │ │ Points   │ │ Custom │
│  │ everyone │ │ only     │ │ only     │ │        │
│  └──────────┘ └──────────┘ └──────────┘ └────────┘
│  Chill: anyone can !sr, 10 max, 2 per person.
└───────────────────────────────────────────────

┌─ LIVE QUEUE ──────────────────────────────────
│ ▶ Howl at Dawn · Timberwolf       @ash
│ 3 queued        [ Skip ] [ Hold ] [ Clear ✕ ]
└───────────────────────────────────────────────

                 [ Customize every detail ▸ ]
```

- **Why:** strongest P8/P9. First run is not intimidating. Matches how `SongRequestPreset` already wants to be used.
- **Cost:** hides power-user config one level deeper. The Customize subview still has to exist and will look like Option A or B inside, so this is really "A/B plus a friendlier front door," not a replacement.

**Recommendation: A**, with C's preset front door grafted onto the Overview tab. That gives a calm everyday surface and a tamed deep config without a second sidebar column. If you would rather not introduce in-pane tabs at all, B is the safe fallback.

---

# 3. Discord

**Today:** five peer sections (Connection, Profile Buttons, Playlist, When not playing, Preview), each with its own `SectionHeaderWithStatus` and its own status chip. A live `DiscordPreviewCard` sits at the very bottom. A missing or disabled `DISCORD_CLIENT_ID` collapses the whole feature to one disabled toggle with no explanation in release builds (the explainer banner is DEBUG-only).

Pain points: five status chips instead of one integration status (breaks P4), the live preview is at the bottom so you scroll away from it while toggling the things it previews, and the no-client-ID dead end has no user-facing explanation.

### Option B. Two-pane, controls left and live preview right (recommended)

Use the window width. Toggles on the left, the Discord preview pinned on the right so every change updates in view. Collapses to stacked on narrow windows via `ResponsiveRow`, which the codebase already has.

```
┌─ DISCORD STATUS ─────────────────────────────  ‹ Connected ›
│ ◉  Showing your music on your Discord profile
└───────────────────────────────────────────────

┌─ CONTENT ──────────────────┐  ┌─ PREVIEW ───────────────┐
│ Show on Discord ........ ●— │  │  ♪ Listening to WolfWave│
│                             │  │  ┌────┐ Howl at Dawn    │
│ Profile buttons ........ ●— │  │  │ art│ Timberwolf      │
│  • Apple Music link .... ●— │  │  └────┘ on Wolf Pack    │
│  • song.link ........... ●— │  │  [ Apple Music ][ More ]│
│                             │  │                         │
│ Show playlist .......... —○ │  │  ‹ Live ›               │
│ Show idle status ....... —○ │  └─────────────────────────┘
│ Hide track when paused . —○ │   Updates as you toggle.
└─────────────────────────────┘
```

No-client-ID state (always visible now, not DEBUG-only, P8):

```
┌─ DISCORD STATUS ─────────────────────────────  ‹ Not configured ›
│ ⚠  Discord Rich Presence is not set up in this build.
│    Add DISCORD_CLIENT_ID to Config.xcconfig, or grab a
│    build from the website where it is already wired.
│                                   [ How to fix ]
└───────────────────────────────────────────────
```

- **Why:** P4 one status header replaces five chips, P6/P13 see-your-change preview, P8 honest dead-end explainer. Privacy toggles (idle, hide-when-paused, playlist name privacy) group under Content instead of floating as peers.
- **Cost:** the two-column sticky layout is the most work here, and the preview must stay legible when it collapses under the controls on a narrow window.

### Option A. Single grouped Form, preview pinned on top

If you would rather not do a two-column layout, keep one column but move the preview to the **top**, right under the status header, so you still see it while you scroll the toggles below it.

```
┌─ DISCORD STATUS ─────────────────────────────  ‹ Connected ›
│ ◉  Showing your music on your Discord profile
│ ───────────────────────────────────────────
│  ♪ Listening to WolfWave
│  ┌────┐ Howl at Dawn · Timberwolf
│  │ art│ on Wolf Pack
│  └────┘ [ Apple Music ]  [ More ]
└───────────────────────────────────────────────

┌─ PROFILE BUTTONS ─────────────────────────────
│ Show buttons .................................... ●—
│  • Apple Music link ............................. ●—
│  • Cross-service link (song.link) ............... ●—
└───────────────────────────────────────────────

┌─ PLAYLIST ────────────────────────────────────
│ Show playlist ................................... —○
└───────────────────────────────────────────────

┌─ WHEN NOT PLAYING ────────────────────────────
│ Show idle status ................................ —○
│ Hide track while paused ......................... —○
└───────────────────────────────────────────────
```

- **Why:** same P4 consolidation and grouping, far less layout risk than two columns. Preview-on-top keeps it in view for the common case.
- **Cost:** on a tall pane you still scroll the preview off-screen eventually. Less slick than B, but it is the safe, fast version.

### Option C. Minimal consolidation

Lowest effort: collapse the five chips to one header, group the privacy toggles under "When not playing," and fix the no-client-ID explainer. Keep section order otherwise.

- **Why:** smallest diff that removes the five-chip noise and the silent dead end.
- **Cost:** leaves the preview at the bottom. Does not really change the feel.

**Recommendation: B** if you want Discord to be the showcase page (the live preview is genuinely delightful next to the controls). **A** if you want the same wins with less layout risk. Both reuse `DiscordPreviewCard` unchanged.

---

# 4. History & Stats

**Note:** this page already shipped a redesign in #259 (the two-column dashboard with `ResponsiveRow` summary, week and hour charts, and a top leaderboard). So this is refinement, not a teardown. The mockups below build on what landed.

**Today:** intro line, two interlocked gating toggles (Listening History, then Stats & Charts), a dashboard band that only appears when both are on and there is data, an always-present Recently Played card, a `!stats` Twitch command card, and a retention + actions band where "Clear History" is paired with "Monthly Wrap."

Pain points: default-off first run is nearly blank except one empty card (weak P8), the `!stats` command config lives here even though it is a Twitch chat feature (commands are now split across three pages), and the destructive Clear History sits next to the benign Monthly Wrap (breaks P11).

### Option A. Three zones via segmented control (recommended refinement)

Separate analyzing from doing from managing. A segmented control splits the populated page into **Overview** (the dashboard you already built), **History** (the full recent list, given room to breathe), and **Manage** (retention, the `!stats` command clearly badged as Twitch, and the danger zone).

```
┌─ HISTORY & STATS ─────────────────────────────
│ Listening history ............................... ●—
│ Stats & charts .................................. ●—
│   Kept on this Mac. Never uploaded.
└───────────────────────────────────────────────

  〔 «Overview» · History · Manage 〕

┌─ THIS WEEK ────────────┐  ┌─ TODAY'S TOP TRACK ─────┐
│ 142 plays · 7h 12m     │  │ ★ Howl at Dawn          │
│ Today 18 · All-time 4k │  │   Timberwolf · 6 plays  │
└────────────────────────┘  └─────────────────────────┘

┌─ LAST 7 DAYS ──────────┐  ┌─ WHEN YOU LISTEN ───────┐
│  ▁▃▅▇▆▄▂  bar chart     │  │  hourly bars 0–23       │
└────────────────────────┘  └─────────────────────────┘

┌─ TOP ─────────────────────────────────────────
│ 〔 «Artists» · Tracks · Albums 〕
│ 1. Timberwolf .................... 88 plays
│ 2. Greywolf ...................... 61 plays
│ 3. Arctic ........................ 44 plays
└───────────────────────────────────────────────
```

**Manage** tab gathers retention, the badged command, and danger:

```
  〔 Overview · History · «Manage» 〕

┌─ RETENTION ───────────────────────────────────
│ Keep history for .......... 〔 Forever ▾ 〕
│   Older entries are pruned at next launch.
└───────────────────────────────────────────────

┌─ TWITCH: !stats COMMAND ──────────────────────  ‹ Twitch ›
│ Let chat ask for today's top track ............. —○
│   Replies only while your stream is live.
└───────────────────────────────────────────────

┌─ DANGER ──────────────────────────────────────
│ [ Clear listening history ✕ ]
│   Deletes every recorded play. Cannot be undone.
└───────────────────────────────────────────────
   Monthly Wrap moved to the toolbar:  [ ✨ Monthly Wrap ]
```

- **Why:** P13 analyzing vs doing vs managing, P11 Clear History isolated in a danger zone away from Monthly Wrap, and the `!stats` card is explicitly badged as a Twitch feature so its out-of-place-ness is at least labeled. Recently Played gets a full tab so it is no longer a fixed-height window-cramping card.
- **Cost:** adds in-pane tabs (same new pattern as Song Requests A, which is an argument for doing both or neither). Monthly Wrap moves to a toolbar button or the Overview header.

### Option B. Keep the single scroll, fix grouping and first run

No tabs. Keep the dashboard you shipped, but strengthen the first-run explainer so default-off is not blank, move Clear History to a footer danger zone, and badge the `!stats` command.

```
┌─ HISTORY & STATS ─────────────────────────────
│ Listening history ............................... —○
│ Stats & charts .................................. —○
└───────────────────────────────────────────────

┌─ NOTHING RECORDED YET ────────────────────────
│  📈  Turn on Listening History and WolfWave will
│      remember what you play, privately, on this Mac.
│      Stats & Charts unlock a weekly view, top
│      artists, and a Monthly Wrap.
│                          [[ Turn on history ]]
└───────────────────────────────────────────────
```

When on, the dashboard renders as today, with two fixes at the foot:

```
┌─ TWITCH: !stats COMMAND ──────────────────────  ‹ Twitch ›
│ Today's-top-track command ....................... —○
└───────────────────────────────────────────────

┌─ DANGER ──────────────────────────────────────
│ [ Clear listening history ✕ ]
└───────────────────────────────────────────────
```

- **Why:** smallest change on top of #259, fixes the two real problems (blank first run, mixed danger) without a new navigation pattern.
- **Cost:** the populated page is still a long single scroll. Does not separate "analyzing" from "managing."

**Recommendation: B** in the short term (it is a small, safe delta on a page you just shipped), with **A** as the target if Song Requests also adopts in-pane tabs. Doing tabs on exactly one page would be inconsistent, so treat A here and A on Song Requests as a paired decision.

---

## Cross-page decisions this batch forces

These are choices that ripple across pages. Worth deciding now so Batch 2 stays consistent.

1. **Adopt grouped `Form` as the pane skeleton?** Recommended yes (P3). Biggest single consistency win. Color cards survive for status only.
2. **One header style everywhere.** Standardize on `SectionHeaderWithStatus` (title + subtitle + one status chip) and retire the bare-`Text` and icon-eyebrow variants.
3. **In-pane tabs: yes or no?** Song Requests A and History A both want them. Either adopt the segmented sub-nav as a sanctioned pattern (then both use it) or avoid it entirely (then Song Requests B and History B). Do not ship it on one page only.
4. **A real danger zone.** Clear History, Clear Queue, Recreate Reward, Regenerate Widget Token, Reset Settings all want the same bottom-of-pane, red-tinted, confirmed treatment (P11).
5. **Commands are split across three pages** (Twitch, Song Requests, History `!stats`). Out of scope for a layout pass, but flagging it: a future unified "Chat Commands" surface would end the split. Not proposing it here.

---

## Open questions for you

1. **Form adoption:** green-light moving these panes to grouped `Form`, or keep the hand-rolled cards and only restructure?
2. **Tabs vs no tabs** for Song Requests and History (decision 3 above).
3. **Discord:** showcase two-column (B) or safe single-column (A)?
4. **Sidebar grouping:** want me to include the 11-row sidebar regrouping (P2) in Batch 2, or treat the shell separately?

---

## Next: Batch 2 (after your review)

The remaining 7 panes, same format (2 to 3 mockups each, tied back to these patterns):

- **General** (proposed: dashboard landing / what's-connected grid, P13)
- **Music Monitor**
- **App Visibility**
- **Stream Widgets** (status header, per-endpoint token rows, regenerate in danger zone)
- **Notifications** (master toggle + per-type dependents, optional presets)
- **About**
- **Advanced** (last in sidebar, danger zone at foot)

Plus the **sidebar shell** regrouping if you want it bundled in.

---

## Appendix: full competitive brief

Research scan across four app categories. Patterns referenced above by number.

**Shell and navigation.** macOS has no tab bar convention; Apple's guidance is a sidebar of sections with a `Form` per pane (System Settings, iStat Menus 7, AlDente, Raycast). Group sidebar items once you pass ~7 rows (OBS Stream/Output/Audio/Video/Hotkeys/Advanced; CleanShot by capture type). Per-pane body is `Form().formStyle(.grouped)` with HIG spacing (20pt outer, 8pt within a group, 20pt between groups).

**Connection and auth.** Put a "what's connected" status header at the top of each integration pane (Streamer.bot's live connection panel, Restream's green per-channel dots, Raycast's per-extension auth). Connect is the prominent primary when signed out; once connected the row flips to identity plus a quiet, reversible Disconnect (not a red filled CTA). Per-destination rows carry identity + status dot + the one or two controls that matter (Restream channels, MeetingBar calendars, SoundSource per-app rows).

**Feature on/off.** Master toggle at the top of the section, dependents revealed below and disabled-in-place rather than vanishing, so the layout does not jump (iStat Menus 7, AlDente). When a feature is off or unconfigured, show a short explainer with the single enable action, never a blank or a wall of dimmed rows (NN/g empty-state guidance). Offer one-tap presets above the granular toggles where many switches interact (CleanShot presets, your `SongRequestPreset`).

**Advanced and danger.** Advanced lives last, behind a disclosure or its own pane (OBS Advanced mode). Destructive actions group in a visually distinct, bottom-placed danger zone, verb+object labeled and confirmed (GitHub-style danger zone). Use sparingly, only for genuinely irreversible actions.

**Cards and visual trend.** macOS 26 Tahoe applies Liquid Glass to chrome (menu bar, sidebar, toolbars, Control Center), not to every content surface; 26.1 even added a Tinted mode because full-clear was too busy. Settings bodies stay flat inset-grouped lists. Cards earn their weight by carrying status or a distinct entity. This matches your cards-no-glass decision from the PR #227 reversal. A dashboard-style landing (summary first, details on demand) is the SaaS-dashboard norm (AlDente opens on a battery dashboard, Restream on a status hub).

**Sources.** Apple HIG: Settings, Sidebars, Lists and tables, Toggles. SwiftUI macOS settings write-ups (215pt sidebar, ~710x470 window, Form/GroupBox, master-toggle disclosure). iStat Menus 7 help, Bartender 6, Ice, AlDente features, CleanShot X features, Hand Mirror, Rocket, Raycast Manual settings. OBS Studio overview, Streamer.bot Streamlabs integration, Restream home and channels docs, Elgato Stream Deck SDK settings, Touch Portal docs. SoundSource manual, NepTunes, MeetingBar. macOS 26 Tahoe / Liquid Glass roundups and the 26.1 Tinted Liquid Glass note. Cross-cutting UX: Smashing on dangerous actions, NN/g on empty states, Carbon status-indicator pattern, SaaS dashboard 2026 guidance.

(Apple HIG pages are JS-rendered, so the HIG specifics come from indexed search summaries of those exact pages plus corroborating SwiftUI practitioner write-ups, not a full-body scrape.)
