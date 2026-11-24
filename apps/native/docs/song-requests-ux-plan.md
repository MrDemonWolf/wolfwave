# Song Requests: UX research + plan

Research date: 2026-11-21. Refund decision: **option B** (2026-11-21). Status (2026-11-23): PR 1 merged (#560), PR 2a merged (#563), PR 2b in review (#564), PR 3 + 4 (queue window with reorder) in progress.

## What stays the same (your design)

- Apple Music library + the **WolfWave Requests** playlist, played through AppleScript.
- Chat first (`!sr`), plus channel points and Bits. Spotify and YouTube links resolve to Apple Music.
- The setup gate (the sheet must finish before requests turn on) and the health check.
- Requests never interrupt a song that's playing. They start at the next track boundary.
- Native macOS app only. No web dashboard and no browser tab that must stay open.
- Stream Deck controls, Who Can Request presets, fair-share ordering.

Every idea below sits on top of that model. None of them changes how songs are found or played.

## The one big problem

**You can only manage the live queue inside Settings.** (`SongRequestSettingsView.swift:84`)

You have to open Settings, scroll past the banners, and find the queue just to approve or remove a song while you stream. The menu bar can't approve either, so approval mode needs either the Settings window or a Stream Deck. Apple's HIG says Settings is for preferences people rarely change, not for things they do often ([HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings)). Other bots get the same complaint: streamers hate switching to a dashboard mid-game.

## Findings (NN/g severity 0–4)

| # | Sev | Finding | Where |
|---|---|---|---|
| 1 | 3 | The live queue only exists in Settings. The menu bar has no pending count and no Approve | `SongRequestSettingsView.swift:84`, `AppDelegate+MenuSections.swift` |
| 2 | 3 | A fresh install shows the **Open** preset as selected, and its summary promises channel points and Bits, but both are off. Clicking Open quietly creates a Twitch reward and turns on Bits boost | `SongRequestAccess.swift:171,193-199,218-240` |
| 3 | 3 | Viewers can't fix a wrong match (no `!wrongsong`/`!undo`), and mods can only skip or clear everything from chat. Text search always queues the top hit | `Services/Twitch/Commands/`, `AppleMusicController+Search.swift:22` |
| 3b | 3 | No explicit-content filter and no maximum song length. Trolls can queue explicit or 10-minute tracks, and other bots treat both as basics. Apple Music already gives both values | `Services/SongRequest/` (no filter found) |
| 3c | 2 | Neither the app nor the docs mention music rights. Twitch says a music subscription doesn't let you play songs on stream, and DMCA strikes can end an account | No match for DMCA/rights in `apps/docs/` or the views |
| 4 | 2 | Paid requests aren't refunded when a mod declines one in approval mode or a track turns out to be unplayable. The Redemptions card copy doesn't mention these cases | `TwitchChatService+Redemptions.swift:445`, `+Redemptions.swift:121` |
| 5 | 2 | `!myqueue` hides pending requests, so a viewer waiting for approval is told they have no songs | `SongRequestQueue.swift:362` |
| 6 | 2 | A blocked *person* is told "that song/artist is on the blocklist" | `SongRequestCommand.swift:163` |
| 7 | 2 | The queue has no reorder, no right-click menu, and no keyboard support (Delete, Return) | `SongRequestQueueView.swift:284-325` |
| 8 | 2 | The reply shows the position (`#3 in queue`) but no time estimate | `SongRequestCommand.swift:149` |
| 9 | 2 | Some outcomes are silent: `!sr` on cooldown, non-mods using `!skip`/`!clearqueue`/`!hold`, and a request added while Music is closed (it's buffered, but nothing says so) | `BotCommandDispatcher.swift:451`, `SongRequestService.swift:457` |
| 10 | 2 | Hold appears twice in the same pane (a queue button and a Playback toggle) | `SongRequestQueueView.swift:388`, `+PlaybackCommands.swift:40` |
| 11 | 2 | About 55 controls on one long scroll. Vote-skip sits between the master toggle and its config. You can't set things up before turning the feature on | `SongRequestSettingsView.swift:88-133` |
| 12 | 2 | The overlay "Up next" ticker exists but can only be turned on by editing the URL (`?queueTicker=1`). The now-playing card never shows the requester | `apps/widget/src/widget.ts:116` |
| 13 | 1 | Naming collision: `!songlist` is an alias for `!queue`, but "Song list" also means the `!playlist` link | `QueueCommand.swift:22`, `SongListCommand.swift:62` |
| 14 | 1 | The fallback playlist is a free-text field that must match exactly. A failure only shows up in the debug log | `+PlaybackCommands.swift:64-89` |
| 15 | 1 | The queue is lost when the app quits (by design), and nothing in the UI says so | `SongRequestQueue.swift:15` |

Heuristics: [Nielsen's 10](https://www.nngroup.com/articles/ten-usability-heuristics/): #1 status visibility (5, 8, 9, 15), #2 match the real world (6, 13), #3 user control and undo (3), #4 consistency (2, 10), #5 error prevention (2, 14), #7 efficiency (1, 7), #8 minimalist design (11).

## Plan, ranked by impact

### 0. Quick fixes (fixes #2, #5, #6, #13)

- On a fresh install, select **Custom** (or nothing) so the selected chip matches the actual settings. Before applying Open, show what it will turn on ("Creates a channel-point reward and turns on Bits").
- `!myqueue` includes pending requests: `#2 "Title" · waiting for approval`.
- New reply for a blocked person: `Sorry, you can't request songs here.`
- Drop the `!songlist` alias from `!queue`, or rename it.

### 0b. Content safety (fixes #3b, #3c)

- **Block explicit songs** toggle, on by default for new setups. Use the Apple Music content rating. Reply: `That song is marked explicit. Try the clean version!`
- **Max song length** (default 6 min). Reply: `That song is 9:41. The max here is 6:00.`
- Every refusal says why and what to do next.
- Add one plain line in the setup wizard and the docs: "You're responsible for having the rights to play music on stream ([Twitch Music Guidelines](https://legal.twitch.com/legal/music/))." Link it; don't give legal advice.

### 1. Request Queue window (fixes #1, #7, #10)

A small window you can keep open while you play. Open it from the menu bar (**Show Request Queue…**), from the Dock menu, or from an **Open Queue** button in Settings.

```
┌ Request Queue ──────────────────────── ⏸ Hold ┐
│ ▶ NOW  Midnight City · M83       @wolfpup     │
│        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  2:41 left │
├ Needs approval (2) ───────────────────────────┤
│   Song A · Artist        @viewer1   [✓] [✕]   │
│   Song B · Artist        @viewer2   [✓] [✕]   │
├ Up next (4) · ~14 min ────────────────────────┤
│ 1 Song C · Artist        @viewer3   ≡         │
│ 2 Song D · Artist        @viewer4   ≡         │
│   …drag ≡ to reorder · right-click for more   │
├───────────────────────────────────────────────┤
│ [Skip ⌘→]                        [Clear…]     │
└───────────────────────────────────────────────┘
```

- SwiftUI `Window("Request Queue", id:)` scene. It's single-instance, so reopening it never makes a duplicate. Add an optional "Keep on top" setting using a floating window level ([HIG: Panels](https://developer.apple.com/design/human-interface-guidelines/panels)). Check that the API exists on macOS 26 before building.
- A native `List` with selection, `.onMove` reorder, and `.contextMenu`:
  - **Play Next**
  - **Remove**
  - **Block Song**
  - **Block Requester**
  - **Open in Apple Music**
- Keys: **Delete** removes, **Return** approves, **⌘→** skips. Don't use ⌘H (that's Hide).
- HIG rules for this window:
  - Give it a short noun title and no minimize button ([Panels](https://developer.apple.com/design/human-interface-guidelines/panels)).
  - Hide context menu items that don't apply, instead of dimming them. Every item must also exist somewhere else in the UI ([Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus)).
  - Offer **Move to Top** as a non-drag alternative, and support undo ([Drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop)).
  - Keep Liquid Glass on the toolbar only, never on the queue rows ([Materials](https://developer.apple.com/design/human-interface-guidelines/materials)).
- The menu bar item stays a normal menu, not a popover. The HIG says to use a menu unless the feature is too complex for one, which is why the full queue gets its own window.
- Settings keeps a one-line summary ("4 in queue · 2 need approval") with an **Open Queue** button. Remove the Hold toggle from the Playback card; Hold lives on the queue.
- Show the real album art in the rows (today they use a placeholder).
- New backend work: `SongRequestQueue` has no move/reorder API today.

### 2. `!wrongsong` / `!undo` + mod `!remove` (fixes #3, #4)

- `!wrongsong` removes the viewer's most recent request that hasn't started playing.
- Reply: `Removed "Title". Try again with artist + title, or paste an Apple Music link.`
- Mods get `!remove <#|@user>` to remove one item instead of clearing everything.
- **Decided 2026-11-21: option B.** Channel-point refunds. Right now points are kept as soon as a song is added or sent for approval, and Twitch can't refund a redemption after that. Two choices:
  - **A.** Keep it simple: no refund after a song is added. Say so clearly in the reply and on the Redemptions card.
  - **B.** Keep each paid request open until the song plays. Then undo, decline, removal, or an unplayable track can refund it. This is fairer but adds state to track, and the queue doesn't survive a quit (finding #15).

### 3. Time estimate + clearer feedback (fixes #8, #9)

- `Added "Title" by Artist, #3 · plays in about 9 min`
- `!myqueue`: `#3 "Title" · ~9 min`
- Estimate = time left in the current track + durations of the songs ahead. Say "about", and skip the estimate when Hold is on.
- If Music is closed: `Added "Title", #1 · plays when the stream's music starts`.
- Cooldown: reply at most once per user per cooldown window ("Slow down! Try again in 20s") so chat doesn't get spammed.

### 4. Approve from the menu bar and notifications (fixes #1)

- Menu bar: a **Needs Approval (N)** submenu listing each song with **Approve** and **Decline**. Add **Show Request Queue…** in the same section.
- An optional notification with **Approve** and **Decline** buttons (a `UNNotificationCategory` with actions), using the existing Notifications settings. Off by default.

### 5. Simpler Settings pane (fixes #11, #14)

New order:
1. Master toggle
2. Queue summary + **Open Queue**
3. Who can request
4. Commands
5. Channel points and Bits
6. Playback
7. Vote-skip
8. Blocklist

- Show the common controls up front and fold the rest into an **Advanced** disclosure.
- Let you configure the cards before the feature is on (show them dimmed instead of hiding them).
- Move the existing **Who can request** presets into the setup wizard as its last question, so the first run picks one on purpose.
- Fallback playlist: replace the text field with a picker of your playlists, or check the name when you type it.
- Merge "Resume AutoPlay" and "Fallback playlist" into one choice: **When the queue empties: AutoPlay / Play a playlist / Stop**.

### 6. Overlay (fixes #12)

- Add an "Show up next" toggle in Settings → OBS Overlay that writes `queueTicker=1` into the copied widget link.
- Show "Requested by @user" on the now-playing card when a request is playing.

## Suggested PR order

| PR | Scope | Size |
|---|---|---|
| 1 | Quick fixes (#0) + content safety (#0b) | S–M |
| 2 | `!wrongsong` + mod `!remove` + time estimate + feedback replies + option B refunds (keep paid requests UNFULFILLED until they play) | M |
| 3 | Request Queue window + context menu + keys (no reorder) | M |
| 4 | Queue reorder (`SongRequestQueue.move`) | S–M |
| 5 | Menu bar approval submenu + notification actions | S |
| 6 | Settings reorder + Advanced + wizard preset step + fallback picker | M |
| 7 | Overlay toggle + requester on the card | S |

Each PR needs docs in the same PR: `bot-commands.mdx`, `features.mdx`, `settings.mdx`, README, and CHANGELOG. Also fix `features.mdx:151`, which says Points and Bits follow your audience setting; only chat does.

## Sources

- HIG: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings), [The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar), [Panels](https://developer.apple.com/design/human-interface-guidelines/panels), [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Context menus](https://developer.apple.com/design/human-interface-guidelines/context-menus), [Notifications](https://developer.apple.com/design/human-interface-guidelines/notifications), [Onboarding](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- Twitch: [Music Guidelines](https://legal.twitch.com/legal/music/), [Update Redemption Status](https://dev.twitch.tv/docs/api/reference#update-redemption-status) (only UNFULFILLED redemptions can be canceled), [Send Chat Message](https://dev.twitch.tv/docs/api/reference#send-chat-message) (`reply_parent_message_id`)
- Other bots: Nightbot (`!songs`, `!wrongsong`, public queue page), StreamElements Media Request (`!wrongsong`, approval tab, drag reorder), Songify (refunds when a song isn't found, `!remove`).
