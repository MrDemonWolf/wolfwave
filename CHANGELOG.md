# Changelog

All notable changes to this project will be documented in this file.

## [2.2.0] - Unreleased

> The next release. These changes ship on the [Nightly channel](https://wolfwave.mrdemonwolf.dev/docs/nightly) off `main` until 2.2.0 is tagged for stable, when this heading gets its date.

### Added

- **Public release notes and design system.** The website now has dedicated Changelog and Design System pages. Unreleased notes stay in the repository until release.
- **Sync settings with iCloud.** Turn on "Sync with iCloud" in Settings → Advanced (or during setup) and your preferences follow you to every Mac with the switch on. Sign-ins, tokens, and permissions never sync, so you still connect Twitch once per Mac. Off by default, and the newest change wins. Server switches, ports, the update channel, and diagnostics stay per Mac.
- **Custom commands choose how they answer.** Each custom command has a "How it's sent" setting: reply to the chatter (the default), a plain chat message, or a Twitch announcement. Announcements need a mod account and a one-time Twitch reconnect. If Twitch refuses, WolfWave sends a reply instead and tells you why.
- **Links that open Settings in the right place.** `wolfwave://settings/<pane>` and `wolfwave://settings/<pane>/<section>` open a pane, scroll to the section, and highlight it, even if Settings is already open. An unknown link opens General. The full list is on the [Settings](https://wolfwave.mrdemonwolf.dev/docs/settings#deep-links) page.
- **Five new Stream Deck keys.** Announce Song posts what's playing to chat (same wording as `!song`). Reject Request drops the current request and tells chat. Block Requester bars whoever requested the current song (hold it to use it). Request Access cycles who can request and shows the current choice. Now Playing shows the track over its album art.
- **Stream Deck has its own settings page.** Find it under On Stream. It holds the control token, the setup steps, and a new "Allow Stream Deck commands" switch. Turn it off to refuse every key press while your overlay keeps running. It's on by default, so nothing changes unless you change it.
- **Block people, not just songs.** Settings → Song Requests → Blocklist now takes Twitch usernames too. A blocked person's requests are turned away before WolfWave looks the song up.
- **An optional Sponsor link.** Sponsor now appears in the menu bar's Help submenu, the Help menu, and the About pane. Turn off "Show sponsor links" in Settings → About to hide it. WolfWave is free and complete either way.

### Changed

- **A shorter, clearer setup wizard.** Seven steps instead of eight, with Apple Music access right after Welcome because everything builds on it. The top says where you are ("Step 3 of 7 · Discord"), every step keeps its title in the same spot, and there is one button to move on: it reads Skip until you finish a sign-in, Next otherwise. Escape goes back. Shorter, plainer copy throughout.
- **Setup shows what's on and lets you change it in one tap.** The Discord step tells you whether Discord is open and has a Listen-buttons switch. The Twitch step shows `!song` and `!last` with a switch each. Notifications are a button, not a switch you can't turn off. The last screen points at the wolf in your menu bar, even if you skip setup.
- **`!song` and `!last` are on for new installs.** Connect Twitch and chat can ask what's playing right away. If you already use WolfWave, nothing changes: your commands stay exactly as you had them.
- **Clearer Discord choices for when the music stops.** The "When not playing" switches are now two plain choices. When you pause: Keep the song, or Hide the song. When music stops: Listening to WolfWave, or Nothing. Your current choices carry over. Other Discord and Twitch labels got plainer too ("Any-app link", "Add a song.link").
- **Cleaner native Settings.** Pane titles appear once in the window toolbar, with a short introduction above each pane’s controls. Status chips sit beside the connection or controls they describe. History uses the shared content width, permission actions stack in narrow windows, and About notices are easier to read. Queue counts stay visible while requests are on hold, approval actions adapt to narrow panes, and custom command details use secondary text instead of status pills.
- **A dedicated home for WolfWave.** The website and documentation now live at [wolfwave.mrdemonwolf.dev](https://wolfwave.mrdemonwolf.dev/). Existing GitHub Pages links continue to redirect.

- **Settings fits smaller workspaces.** The minimum width is 640 points for MacBook half-screen layouts. Integration rows stack their status and Configure action when space is tight, toolbar titles follow the selected pane, and sidebar group labels share one heading style.
- **Queue controls stay above the songs.** Skip, Hold/Resume, and Clear Requests use larger native buttons at the top of the queue. Hold is available before the first request arrives.
- **Native switches throughout Settings.** Labels and descriptions belong to their macOS controls, switches use the standard size, and helper text is easier to read and wraps without clipping.
- **Calmer website motion.** Shorter, smaller entrances replace the pronounced section movement. Scroll replay resets only once content leaves the screen, and hero elements appear with less stagger.
- **Settings opens at its preferred size.** Fresh settings windows use the design system's preferred dimensions, with the existing minimum size still supported.
- **Clearer pane headings and queue access.** History & Stats keeps its privacy introduction below the toolbar title. Song Requests folds the explainer behind “How it works” and puts the active queue before configuration controls.
- **Consistent spacing across Settings.** Twitch, Discord, Software Update, Advanced, and About use the same section spacing as the other panes, while related controls keep their tighter grouping.
- **Cleaner token, setup, and port settings.** The Stream Deck token card is just the token: a title, one line, the field, and Regenerate. Song Requests has a real **Run Setup Again** button, and the cooldown note sits under the `!sr` cooldown sliders. The widget port only looks locked while it is locked. Software Update lines up with the other panes.
- **Clear Requests also clears the shared playlist.** Settings and the menu bar ask first, then empty WolfWave Requests; Music stops when requests are queued, pending, or playing, but keeps playing when only the old playlist is cleared. Songs stay in your library. The menu bar reports cleanup failures, and `!clearqueue` tells chat when cleanup fails.
- **Song Requests are easier to scan.** The live queue stays near the top, settings are grouped into Request Setup, Queue Behavior, and Moderation, and slow playlist checks and clears show progress. The AutoPlay setting explains that Music's AutoPlay must be enabled in Playing Next and that a fallback playlist takes priority.
- **Stream Deck credentials show their loading state.** The control-token editor keeps its layout and shows progress while Keychain values load.
- **Updated web and tooling dependencies.** Refreshed Next.js, Fumadocs, React, the overlay test environment, Stream Deck SDK, and marketing tooling. Compatible updates and remaining migration limits are recorded in `docs/dependency-upgrades.md`.

- **Redesigned documentation.** The docs now read like a Mac manual: the homepage's top bar, a sidebar split into Guides, Developers, and Design with an icon for every page, and a breadcrumb, Copy Markdown button, and last-updated date on each page. Settings paths, troubleshooting fixes, and diagrams are easier to scan, search filters by section, and every page was checked against the current app. The docs home is a help page: search, setup steps, common fixes, and developer links. Landing feature cards link directly to their guides.

- **A clearer website and smoother overlays.** The landing page uses five focused sections, six common questions, and a trimmed navigation, with detailed answers grouped in the full FAQ. Cards and previews move into place on scroll, with reduced-motion support. Updated search descriptions, Montserrat and Roboto typography, and stronger text contrast improve readability. Overlay updates preserve artwork and Vinyl rotation; preset text colors are checked against light and dark scenes.
- **Breaking: Stream Deck protocol v3. Update the plugin and the app together.** If they don't match, every key switches to `Update` the first time you press one. The Discord Presence, Music Sync, Cycle Theme, and Status keys are gone: change those in Settings, and use Now Playing instead of Status. Clear Queue now fires only if you hold it for about a second, because it can't be undone.
- **Stream Deck keys are easier to read.** An active key is solid blue, keys that remove something (Clear Queue, Block Song, Reject Request, Block Requester) are red, and Approve Next turns amber when requests are waiting. Queue keys show their count as a big number, Now Playing scrolls long titles across the album art, and titles you set on a key are no longer overwritten.
- **The Stream Deck panel checks your token.** It saves a valid control token as soon as you paste it, then shows "Connected", "WolfWave rejected this token", or "Update the plugin". The old green message now reads "Token format is valid", because it only checks the shape.
- **Stream Widgets follows the order you set it up.** Turn on the connection, add the ready-made browser source, then style it. The port, overlay token, and raw WebSocket addresses moved down to "Build your own overlay". The page also says where the server can be reached: this Mac only, or your local network too.
- **Stacked request limits only add what you set.** In Settings → Song Requests, Stacked mode used to count every role limit you never touched as 2, so a subscriber could queue more than you allowed. An unset role now adds nothing and shows None, and the pickers read "+2", "+3". Highest tier mode is unchanged.
- **Paid request switches live in one place.** The channel-point and Bits toggles now sit only in Channel Points & Bits. Who Can Request shows a "Paid requests" summary with a button that jumps there.
- **Custom commands work before you connect Twitch.** Create and edit them any time, and they start replying once you connect. The editor names the exact problem under the field to fix (a space in a trigger, an empty reply, a name already taken, a reply over 500 characters) and shows a live character count.
- **Twitch sign-in is easier to follow.** The sign-in code shows how long it has left and offers "Get a new code" when it expires. Log Out asks first, and the signed-in row is now called "Bot account".
- **Errors say what broke and how to fix it.** Messages name the cause and offer a button that does the fix, instead of hiding the reason in a tooltip. Learn More buttons open the new [Troubleshooting](https://wolfwave.mrdemonwolf.dev/docs/troubleshooting) page, including from the Apple Music permission warning.
- **Expired Twitch sign-ins have a Reconnect button everywhere.** The notices in Bot Commands, Custom Commands, Song Requests, and the `!stats` card offer "Reconnect with Twitch", which opens the Twitch pane and starts signing in.
- **Slow buttons show they're working.** Approve, Skip, Hold, Fetch link, Check Again, Add to blocklist, and other slow actions show a spinner while they run, ignore a second click, and flash a checkmark when done.
- **Export Logs sends everything.** Settings → Advanced → Export Logs writes one file, named with the date and time, holding your app and macOS versions, install method, the last crash (if any), and every log file instead of only the newest. Copy to Clipboard includes the same header.
- **Clearer crash notices and logs.** After a crash, Settings → Advanced names the fault and when it happened, and "Report a Bug" fills in the details for you. Every log line has a full date and timezone, each launch stamps the app and macOS versions, and numbers like file sizes and ports are no longer scrubbed (tokens and account IDs still are).
- **Diagnostics clean up after themselves.** Turning off Share Diagnostics deletes the saved reports. While it's on, WolfWave keeps only the newest 50 from the last 30 days.
- **Advanced and About are tidier.** Clear Logs sits with the other log actions, Clear Artwork Cache sits in Artwork Cache, and the Danger Zone holds only Erase All Data & Reset. The MetricKit card is now "Share Diagnostics", About has one Docs button, and the Rerun Setup Wizard alert's button reads "Open Wizard".
- **The menu bar asks before it deletes.** Clear Queue and Restart Integrations confirm first, and Clear Queue sits apart from Skip. Help gains Check for Updates, and long titles are shortened with the full text in the tooltip.
- **The setup wizard is easier to drive.** Return moves to the next step (on the Twitch step it submits the channel name). Optional steps say "Optional", Skip All ends on a short "Skipped" screen, and the finish screen has a Done button and stays open while VoiceOver is on.
- **Easier to read, and better with VoiceOver.** In Light mode, status chips, callout icons, and the selected settings rail row use darker icons so they stay readable. VoiceOver reads each status chip once, names every Song Requests picker, says which blocklist entry a Remove button removes, and announces the selected rail row. Return adds a blocklist entry.
- **Reduce Motion is honored everywhere.** Jumping to a settings section and every setup wizard step, progress dot, and toggle card stop animating when Reduce Motion is on.
- **The last `!stats` fact can't be switched off.** Its chip locks with "Keep at least one." instead of ignoring your click.

### Fixed

- **`$song` and `$lastsong` read naturally.** In custom commands they fill in just the song and artist, like `Howl at the Moon by Gray Wolf`, instead of the whole `!song` reply with its emoji and link. A song title that starts with `!` can't set off other bots.
- **Request commands follow the Song Requests switch.** While Song Requests is off, `!queue`, `!myqueue`, `!skip`, `!clearqueue`, `!hold`, and `!resume` stay quiet, so a mod's `!skip` can't start your fallback playlist.
- **No raw errors in chat.** When a song search or link lookup fails, `!sr`, channel points, and Bits say "song search isn't working right now" instead of the technical error. The details go to the log.
- **Copied widget links keep your WebSocket port.** Changed the port? Copy Link, the menu bar, General, and setup now add `?port=` for you, so the OBS widget connects on the first try.
- **No more dead "Send to a remote site" row.** General's Integrations card listed a setting WolfWave doesn't have.
- **The reset alert reads cleanly.** When Erase All Data & Reset stops early, the message no longer shows stray asterisks around "nothing was erased".
- **Try Again rereads your Twitch sign-in.** When macOS blocks the Keychain read, Try Again reads it again instead of trying to join a channel and blaming the channel name.
- **Shorter history asks before it drops your totals.** Moving Keep for off Forever now warns when it would clear the All time and Top totals, even when no play is old enough to remove.
- **Bug reports arrive filled in.** Report a Bug and Send Feedback fill the GitHub form's App version, macOS version, and a new Environment field. GitHub had been ignoring the details WolfWave sent.
- **Accurate Music access wording.** The permission screen no longer says WolfWave never plays or pauses. That access also runs your play controls and song requests.
- **Up-to-date channel-points banner.** When Twitch refuses the Request a Song reward, the banner says to turn on Channel Points in your Creator Dashboard instead of saying you need Affiliate or Partner.
- **The import sheet lists every sharing setting.** "Import local sharing and server settings" now mentions automatic update checks too.

- **Now Playing keeps the right artwork.** The previous cover stays visible while the next one loads, then crossfades without flashing the default artwork. Reduce Motion disables the fade, and delayed responses cannot replace a newer cover.

- **Settings opens without a hidden helper window.** Menu, Dock, and keyboard entry points use the SwiftUI scene directly; existing Settings windows are restored and brought forward by their exact identity.
- **About follows the app appearance.** The app icon uses its existing Light and Dark artwork, including the DEV badge in development builds.
- **Standard Mac menu commands are back.** Quit, Hide, and the Edit menu are available while Settings is open.

- **Credential prompts leave the interface responsive.** Startup Twitch validation, reconnect checks, the General dashboard, and the Twitch account pane read credentials away from the main actor. The Twitch pane shows loading feedback while Keychain waits.
- **Local builds reuse an available Apple signing identity.** Debug builds and tests prefer Apple Development, then Developer ID Application, so rebuilds do not keep changing the app's identity. Moving from an unsigned build may still require a one-time macOS data-access confirmation.
- **CI checks cover every changed area.** An aggregate check verifies the applicable native, UI, docs, Stream Deck, and lint jobs. Sponsor refreshes report a missing token instead of failing every day.
- **App Visibility follows the selected mode.** Menu Bar Only hides the Dock icon after the last window closes, and Dock Only hides the menu bar item as soon as WolfWave starts.
- **Song Requests setup no longer cries wolf about Sync Library.** Right after making the WolfWave Requests playlist, setup used to warn that Music couldn't see it, before iCloud had a chance to sync. It now waits up to about 40 seconds ("Adding it to Music…") and only warns if the playlist still hasn't shown up. The warning names the exact switch, Music › Settings › General › Sync Library, and Check Again waits again. The Song Requests settings banner works the same way, and its Check Again button shows a spinner while it checks. Setup steps also sit right under their headings now, with shorter wording.
- **`!song`, `!last`, and `!stats` honor their cooldown.** When several viewers sent one at the same moment, they all got a reply.
- **A refused `!sr` no longer blocks everyone else.** A viewer who isn't allowed to request, or `!sr` while requests are off, no longer puts it on cooldown for the rest of chat. Those refusal replies are throttled so they can't flood chat.
- **`!skip` tells the truth.** It no longer says "Queue is now empty" when nothing was skipped. If Music is closed or busy, it says "Couldn't skip right now, try again."
- **More Apple Music links work.** Song links without a name in the URL (`music.apple.com/us/song/<id>`) and album links that point at one track now play the right song, and link requests ask for Music access when needed.
- **Spotify and YouTube requests match better.** A featured credit or different punctuation in the artist name still finds the song, while an unclear match or a different artist with the same title is turned away.
- **An `!sr` alias that starts with a built-in trigger works.** An alias like `!srq` now searches for the whole song name.
- **Blocklists catch more.** Artist blocks match collaborations, "feat.", "ft.", and "featuring" credits, accents, extra spaces, bracketed title endings, and artist names that contain a comma.
- **Requests follow viewers through name changes.** Request limits, queue ownership, and Bits boosts use the Twitch login, so a new display name doesn't reset them.
- **Custom command triggers with spaces.** A trigger or alias with a space (like `!hug me`) could be saved but never fired. The editor now blocks spaces. Saved commands with a spaced trigger get the spaces removed and are turned off so you can check them, and spaced aliases are dropped.
- **Emoji-heavy replies fit Twitch's limit.** Replies full of emoji or flags could go over 500 characters and be rejected. WolfWave now counts the way Twitch does and never cuts an emoji in half.
- **Vote-skip and queue fixes.** A failed vote-skip no longer uses up the cooldown, opening Music respects your request and auto-advance settings, and priority jumps work with fair-share off.
- **Resume shows on an empty held queue.** The Resume button appears when the queue is on hold with nothing in it, with a note explaining the hold.
- **Queue buttons are easier to use.** Decline and Remove are easier to click and have tooltips, and the queue's status pills use the same colors as the rest of the app.
- **The song list link status tells the truth.** It shows "Invalid link" until the `!playlist` link is a real HTTPS address, and a half-typed link in setup is no longer saved.
- **Channel-point refunds wait for Twitch.** A refund no longer reports success before Twitch confirms it. Rejected refunds are checked and retried a few times, and stuck ones show in Settings without blocking sign-out.
- **Paid requests are safer.** Duplicate protection for channel points and Bits survives your Mac's clock moving backwards, every change is saved to disk right away, and a Bits boost or request that already ran is never applied twice.
- **Twitch reconnects more reliably.** It reconnects after a quick Wi-Fi or VPN switch, keeps retrying more slowly after longer outages, retries promptly after sleep, and keeps a renewed sign-in through a brief Keychain error.
- **A permanent Twitch cut-off stays off.** When Twitch ends the chat connection for good (account removed, permission lost, or an update needed), waking your Mac no longer quietly reconnects. Connect again from Settings → Twitch once you've fixed the cause.
- **Twitch errors show up.** About forty failure messages, including failed channel joins and Keychain problems, went to a status line no screen showed. They now appear in the Twitch pane.
- **The right Twitch message for the right problem.** A missing optional permission now names that permission instead of claiming your sign-in expired. Twitch being down, rate limiting, or you being offline no longer sends you to reconnect.
- **Twitch sign-in errors behave.** A failed sign-in shows its error once, an old error clears when you retry, and Try Again retries the sign-in (or sign-out) instead of joining a channel. The sign-in code copies through its Copy button only.
- **Join Channel keeps its width.** The Join / Leave Channel button no longer changes size as its label switches.
- **Discord connects in more setups.** If Discord was launched with an empty or non-UTF-8 argument, WolfWave could miss its connection and Rich Presence never appeared.
- **Discord says what went wrong.** Instead of "Discord not running" for every problem, WolfWave tells apart Discord being closed, Discord refusing the connection, and macOS blocking it.
- **Rich Presence is steadier.** Long text is trimmed, rapid updates are combined, a rejected update is retried once, preview buttons match the live ones, and the preview's placeholder track is invented.
- **Hiding the overlay no longer blanks your Stream Deck.** With the overlay cards hidden, the Play / Pause key stopped updating. Hiding the cards now only hides the cards.
- **Approve Next doesn't fake success when the queue is full.** The request stays pending and the key shows `full` instead of a checkmark.
- **Stream Deck Clear Queue clears Music too.** It now also clears Music.app's queue, like the menu bar item.
- **The Stream Deck page is accurate.** It shows Starting or Server error instead of Ready when the server failed, its cards line up, the setup steps say to build the plugin from the repo (it isn't on the Elgato Marketplace yet), and the `health` frame reports whether Discord is really connected.
- **Stream Deck keys stay in step.** Now Playing stops scrolling when it shows Offline, Token?, or Update, and a late answer to a timed-out press no longer shows up on your next press.
- **Stream Widgets port fields behave.** They save when you Tab or click away, undo an invalid entry, confirm a saved one, and show "Couldn't start" when the port is in use. Greyed-out copy buttons and the Enable Widget Webpage switch say why.
- **Pasted uppercase tokens work.** An overlay or control token pasted in uppercase is saved in lowercase, and Regenerate no longer stalls the window.
- **The overlay server is sturdier.** The widget server retries a failed start and caps slow responses, WebSocket connections stay alive through quiet periods, and loading or saving tokens no longer blocks the window.
- **Music tracking is steadier.** Slow Music replies time out, reads never overlap, and WolfWave checks the latest state after a burst of changes.
- **Album art matches the song.** Artwork lookups check the title and artist and back off after network or rate-limit errors.
- **Homebrew installs leave updates to Homebrew.** A cask installed to Applications was mistaken for a DMG install, so WolfWave offered its own updates next to `brew upgrade`.
- **History counts each play once.** Turning History off and on mid-song, then quitting on that track, recorded it twice. A play cut off by a crash no longer damages the next one, and cleanup keeps your history if an entry can't be saved.
- **History retention cleans up on time.** Expired plays are removed while recording, once a day, and when you change retention. Shortening retention tells you how many plays it removed.
- **Lifetime stats survive damage.** A damaged lifetime stats file is backed up and logged instead of silently reset.
- **Safer backup imports.** Imports check sizes, ranges, and HTTPS links, name the settings they overwrite, and only count server, port, update-channel, and diagnostics settings when you choose to bring those across.
- **Erase & Reset tells you what happened.** If macOS refuses to remove your sign-ins, it says nothing was erased. If history or logs can't be erased, it says so and offers Relaunch.
- **Settings explain more failures.** Login-item failures and log or Monthly Wrap export errors are explained, clearing logs removes the older log files too, and finished or cancelled wrap shares delete their temporary files.
- **Music permission checks report the real result.** Try Again shows the actual Automation result and closes the instructions after you allow access. Setup refreshes when you come back from System Settings, and Song Request setup links to Twitch settings.
- **The setup wizard is quicker and more accurate.** The Music permission check no longer stalls the window, and the OBS URL shows the port the server really uses.
- **Smoother settings.** Sidebar toggles no longer animate the whole pane or reset the sidebar width, a busy button no longer comes back stuck, "Try Again in Ns" countdowns don't restart, Share always responds, copy checkmarks stay up the full time, the pause icon fades, and Monthly Wrap arrows are easier to click.
- **What's New behaves.** It no longer opens a second window, and its button now reads "Got it" and closes the window.
- **VoiceOver reaches every button.** That includes Open Music on the Now Playing card and the Open System Settings, Show me how, and Try again buttons on the Music Access screen.
- **Crash reports keep the details.** A crash from an uncaught error keeps its name, reason, and backtrace instead of a bare abort record.
- **Log lines stay whole.** A carriage return in a message can no longer break a log line.
- **Diagnostics numbers stay current.** The Share Diagnostics card no longer shows a launch count frozen from when the window opened.
- **Accurate privacy text.** The app's privacy wording now matches what it does with integrations, local overlays, listening history, logs, the artwork cache, and reset.
- **Custom commands can't hide built-ins.** A custom command can no longer use a built-in trigger or alias like `!song` or `!sr`; the editor names the built-in. One saved by an older version is turned off so the built-in answers again.
- **Clearer port lock.** The locked Widget Port now says to turn off Enable Widget Webpage, the switch that actually locks it.
- **`!sr` help mentions Apple Music links.** The usage reply now lists Apple Music, Spotify, and YouTube links.

### Developer

- **Request results say who reads the text.** `SongRequestService.RequestResult` splits `.denied` (the chat-ready audience refusal) from `.error` (a lookup failure, logged and never sent to chat). `SongRequestGatedCommand` gives the queue commands a silent preflight refusal while Song Requests is off, and `WidgetLink` is the one builder for widget Browser Source links.
- **Bug-report fields are checked against the form.** `BugReportURL` fills issue-form fields by id (`BugReportURL.FormField`) and percent-encodes `+`; `make lint-sync` fails when an id names no text field in `bug_report.yml`. `RetentionImpact` drives the retention confirmation. `TwitchViewModel.RetryTarget` gains `.reloadCredentials` and moves with `retryTarget(for:)` into `TwitchFailure.swift`.
- **One home for Twitch and Discord defaults.** Every `@AppStorage` seed and `Preferences.bool(_:default:)` read for those keys now references `AppConstants.UserDefaults.Defaults`. New `FreshInstallDefaults` writes day-one values once per install at launch (fresh installs get them, existing installs get their old values pinned), so a new default never flips an upgrade. The onboarding UI tests gained Escape and progress-header coverage plus a light/dark screenshot capture (`testCapturesEveryStep`), backed by new `WOLFWAVE_UI_TEST_APPEARANCE` and `WOLFWAVE_UI_TEST_HOLD_COMPLETION` switches. The `stepContentMinHeight` token is replaced by `contentMaxWidth`.
- **Debug shows one tool at a time.** A native list becomes a menu picker in narrow windows, inactive tools stop polling, and Copy Diagnostics shows progress and completion.

- **Debug and Release share the activation policy.** Both packaged apps set `LSUIElement = NO`; Dock and menu-only behavior remains controlled at runtime. A hosted regression checks the app's actual metadata.
- **Settings window lookup uses scene identity.** Existing and minimized windows are matched by their exact identifier; the hidden scene bridge and timing-based lookup are removed.
- `PlaylistVisibilityWait` (Services/SongRequest) re-probes Music.app's local library every 2 s for about 40 s after the requests playlist is made, so iCloud sync latency no longer reads as Sync Library being off. The setup step runs it in a `.task` keyed on the step and a Check Again counter, so it is cancelled with the step or sheet. `runSetupHealthCheck(forceWait:)` uses the same wait unless the gap is already on the banner. Covered by `PlaylistVisibilityWaitTests` with a scripted probe and sleep.
- **Stream Deck protocol v3.** `StreamDeckAction` adds `announce_song`, `reject_current`, `block_requester`, and `cycle_audience`, drops the Discord / Music Sync / theme / status actions, and `StreamDeckControl.protocolVersion` is 3. Change the TypeScript mirror in `apps/streamdeck/src/wolfwave/` in the same PR.
- **Stream Deck plugin.** `WolfWaveClient` swallows a late ack from a timed-out press and reports handshake rejections; `src/connection-status.ts` maps client state to the Property Inspector message; key repaints use a paint generation so a suspended render can't install a timer late; the Property Inspector saves a 64-hex control token on paste.
- **`streamDeckControlEnabled` and `StreamDeckPaneStatus`.** The command switch defaults to on (read it through `FeatureFlags`). The header-chip precedence (server off, server error, starting, commands off, then Ready only for `.listening`) is a pure `nonisolated` resolver with tests, and `WebSocketServerCard` takes the parent's `serverState`.
- **`health` frame.** `discord` is true only when Rich Presence is connected, the additive `discordState` tells "off" from "disconnected", and the frame is re-sent when Discord connects or drops.
- **Settings deep links.** `wolfwave://` is registered in `Info.plist`; `SettingsDeepLink` parses it, `SettingsNavigation` hands it to `SettingsView`, and `.deepLinkSection("slug")` tags a card. Add new slugs to the Deep links table in `settings.mdx`.
- **iCloud settings sync.** `SettingsSyncService` mirrors the backup payload under `settings.v1` (last write wins by `exportedAt`) behind the `SettingsSyncStore` test seam; `flush()` runs at termination. The iCloud entitlement is added only at release signing when `PROVISIONING_PROFILE_B64` is set.
- **`UserFacingError`, `ErrorCallout`, `FieldValidationRow`.** User-visible failures carry a title, cause, fix, severity, docs anchor, and `ErrorAction` intents instead of bare strings. `MusicPermissionBanner` and the expired `TwitchConnectionNotice` are built on them, and the troubleshooting page gives every Learn More anchor a target.
- **`AsyncActionButton`.** One owner for async button state (spinner, re-entrancy guard, stable width, success checkmark, cancel on disappear) replaces three drifting copies across seventeen call sites.
- **Atomic cooldowns.** `CooldownManager` gains `tryClaim` / `release` and an injectable clock, and the dispatcher claims before any `await`. `PreflightCheckedCommand` / `PreflightDenial` let `!sr` refuse before the cooldown is claimed, with refusals throttled on a `<trigger>#denied` key (10 s per viewer, 5 s channel-wide).
- **Custom command validation.** `CustomCommandStore.validationIssue(for:)` returns a `CustomCommandIssue?` and runs inside `add` / `update`, which return `Bool`. Legacy spaced triggers are repaired on load. `ReplyDelivery` routes announce through `sendAnnouncement` with a reply fallback.
- **Chat length counts Unicode scalars.** `String.chatLength` and `truncatedForChat()` measure the way Twitch does and cut on a `Character` boundary.
- **Song request internals.** `SongRequestService.skip()` returns a `SkipOutcome`, `RequestAudience.current(in:)` is the one audience reader, `TrackTextNormalizer.artistCandidates(_:)` builds the artist match set, and `SongRequestCommand.extractQuery` drops the first token instead of prefix-matching.
- **Twitch internals.** `TwitchViewModel` gains `deviceCodeExpiresAt` and `retryTarget(for:)`; `NWPathMonitor` updates drain through one `AsyncStream` so a stale "unreachable" can't land last; `RetryAfter` is the one `Retry-After` parser (capped at 300 s); the boot validation runner, rate limiter, sending, redemption subscriptions and handlers, and `TwitchViewModel.Failure` each moved to their own file with no behaviour change.
- **Menus never touch the Keychain.** Tray and Dock menus read an in-memory `TwitchMenuState` refreshed off the main thread, and `MenuTitleFormatting` clamps titles to 40 characters.
- **Crash reporter.** An uncaught exception sets a flag so the SIGABRT that follows can't overwrite its richer marker, `CrashMarker` parses the marker, and `DiagnosticsBundle` composes the export with every rotated log.
- **Logging format.** Lines are `<ISO8601>  <LEVEL>  <Category>  <File.swift:line>  <message>[ key=value…]` with whitespace-led continuation lines, documented in `apps/native/docs/logging-format.md`. `LogRecord` is the one reader, `LogCategory` is the only category type, `Log.Fields` adds structured fields, and redaction keys off context instead of scrubbing every 6-digit number.
- **Logger reliability.** `clearLogFile()` is an atomic replace (it could leave a file of NUL bytes), the writer reopens when the file's inode changes, `Log.error` no longer blocks on `fsync`, rotation keeps 3 backups, and `WOLFWAVE_LOG_LEVEL` gates the file sink too.
- **Durable writes.** `TwitchRedemptionResolutionOutbox` writes through `durableAtomicWrite` (temp file, `F_FULLFSYNC`, rename, directory fsync) and clamps future-dated tombstones, `PlayLogStore` closes a torn last line before appending, and `DiagnosticsService` prunes after each write.
- **XCUITest suite.** New `WolfWaveUITests` target, `make test-ui`, and a `ui-test` CI job drive onboarding and render (and screenshot) every settings pane. `UITestMode` routes defaults and Keychain to throwaway storage and keeps services down; it is compiled out of Release. The suite is not part of `make test-ci`.
- **Test isolation.** `SharedTestStateIsolation` is one re-entrant lock over the Keychain backend, the reauth flag, and `DefaultsStore`, taken by subclassing `WolfWaveTestCase` or the `.isolatedSharedTestState` trait. Fixed sleeps became readiness waits and month-boundary tests no longer fail at midnight.
- **New test suites.** `StreamDeckControlIntegrationTests` (commands over a real loopback WebSocket), `DiscordIPCFramingTests` (the IPC handshake over `socketpair(2)`), OBS widget tests in `apps/widget/tests`, and Stream Deck connection-status tests.
- **`make test` can't report a false green.** `check-test-results.sh` reads totals from the largest `Executed` line and counts XCTest failures per case.
- **OBS widget hardening.** Artwork must be a credential-free `https:` URL, `port` / `wsPort` must be 1-65535, frames over 64 KB or the wrong shape are dropped, and reconnect uses jittered backoff capped at 10 s.
- **Design tokens 1.2.0.** Adds `DSColor.neutral`, the Light-mode glyph tokens and `DSColor.glyph(for:in:)`, `DSOpacity.wash` / `washStrong`, `DSDimension.StatusChip`, and `DSDimension.Settings.navRailWidth`; `text.muted` darkens to pass 4.5:1. `.motionSafe(_:value:)` and `withMotionSafeAnimation` honor Reduce Motion in one place.
- **Design-system lint.** New `raw-status-color` and `raw-radius` rules, edge-specific padding and whole-number float coverage, and `bun run ds:test` pins every rule against known-good and known-bad lines.
- **Design-system gallery.** The Debug tab renders every `Views/Shared/` component in its preview states and every token family from generated lists, so it can't drift from `tokens.json`. A live log viewer (`DebugLogViewerCard` over `LogTailCursor`) tails the log file.
- **Generated Debug app icon.** `AppIcon-Dev.icon` is derived from `AppIcon.icon` by `scripts/generate-app-icons.ts` (`make icons`) with a `DEV` badge drawn from squares, and the drift check fails the PR if it changes.
- **Source and docs drift gate.** `scripts/check-sync.mjs` (`make lint-sync`, blocking in CI) checks token-derived Swift lists, the component catalog, widget docs values, docs ports against `AppConstants`, and lint rule claims. It also runs `release-notes.test.mjs` (renders the real `CHANGELOG.md`) and `version.test.mjs`.
- **Release notes stay flat.** `release-notes.mjs` fails on nested or indented bullets, wrapped lines, and `*` bullets, so keep every CHANGELOG bullet on one line.
- **Shared CI plumbing.** The `setup-native-build` composite action, the signing and notarization scripts, and `make test-ci` replace copies across CI, Release, and Nightly. Jobs gate on one `changes` paths-filter job and all have timeouts, and `make check-drift` runs CI's drift check locally.
- **Release and nightly safety.** Notarization runs `stapler validate` and `spctl` (also `make verify-notarize`), the appcast tool comes only from the pinned SPM artifact, release workflows are serialized, nightly builds only from `main` at 05:00 UTC and skips days with no app changes, Homebrew release versions are validated, and scheduled workflows skip forks.
- **Fixed broken CI pieces.** The appcast script exited silently under `set -euo pipefail` (nightly was red for a week), and CI wrote `DOCS_URL` / `COMMUNITY_DISCORD_URL` without the `$()` escape, truncating them to `https:`.
- **Dependencies.** Dependabot watches SwiftPM and bun, the docs site is on Next.js 16.4.0, and sponsor generation dependencies are pinned and published with a step-scoped token.
- **`make clean-dev`.** Resets WolfWave Dev to a fresh first run (quits it, wipes its defaults and Keychain entry, cleans, removes the `/Applications` copy) and never touches the production app.
- **Dead code removed.** A Periphery pass removed unused APIs across Twitch, Keychain, song requests, Sparkle, logging, and formatting, plus the unused `InfoRow`, `UpdateBannerView`, and `TwitchGlitchShape` views, the `apps/marketing/shared` token package, and `scripts/generate-og-image.mjs`.
- **Docs site.** Search works under the GitHub Pages base path, canonical URLs go through `pageUrl()`, brand colours come from the generated tokens, the homepage FAQ emits `FAQPage` JSON-LD, phones get a "Send to my Mac" button instead of a `.dmg`, every demo widget is labelled as a demo, an `llms.txt` index sits next to `llms-full.txt`, and the docs were rewritten for streamers, viewers, and developers.
- **`BuiltInCommandCatalog`.** Lists every built-in trigger and alias key; `CustomCommandStore.validationIssue(for:)` returns `CustomCommandIssue.reservedTrigger` for a clash, and `BuiltInCommandCatalogTests` keeps the catalog in step with the dispatcher.
- **Comment and template fixes.** `!stats` comments no longer call it live-only (it follows Only reply while live), the progress-timer comment notes a lone Stream Deck gets no `progress` frames on purpose, and the PR template says every `MARKETING_VERSION` occurrence.

## [2.1.0] - 2026-08-14

### Security

- **Safer local widget credentials.** Token-bearing HTML is served only to a true loopback peer using a literal local Host and is marked `no-store`; token changes are saved to Keychain before connected clients rotate.

### Added

- **Custom bot commands.** Make your own chat commands with a fixed reply, right in Settings → Twitch → Custom Commands. Drop in variables like `$user`, `$touser`, `$args`, `$1`–`$9`, `$song`, and `$lastsong` and they fill in live. Each command gets its own aliases and Everyone / Per-person cooldowns, same as the built-ins.
- **Pick who can run a command.** Set any custom command to Everyone, Subscribers, VIPs, Moderators, or Broadcaster only. Custom commands ride along with your settings backup.
- **Approve songs before they play.** New opt-in "Require My Approval" toggle in Settings → Song Requests → Access. When it's on, every request (chat, channel points, bits) waits in the Queue tab until you approve or decline it. Off by default, so requests still auto-queue unless you turn it on.
- **Fair-share song ordering.** The queue now interleaves requests round-robin, so everyone's first request plays before anyone's second. A regular who re-types fast no longer plays back-to-back while newcomers wait. On by default; flip "Fair-Share Ordering" off in Settings → Song Requests → Queue for classic first-in, first-out.
- **Sub / VIP request priority.** Reward your subs, VIPs, and mods: pick a perk in Settings → Song Requests → Queue. "Skip cooldown" lets them request without the wait; "Jump the queue" also moves their song ahead of regular requests within the same fair-share round (so it's a nudge up, not a queue takeover). Off by default.
- **Two new overlay layouts: Vinyl and Classic.** Vinyl is a spinning record with your album art as the label and a circular progress ring. Classic sets the album tile beside a card with the title, artist, and a progress bar. Pick either in Settings → Stream Widgets, same as Horizontal, Vertical, and Compact.
- **Queue ticker overlay.** Add `?queueTicker=1` to your widget URL for a panel showing the next 3 song requests, title and requester, so viewers see their spot in line. Off by default, matches your current widget theme.

### Changed

- **A custom WolfWave mark.** The familiar wolf now carries a padded side equalizer, used consistently across the app icon, menu bar, onboarding, OBS fallback, Discord art, DMG installer, docs, and repository branding.
- **Settings toggles all look the same now.** Launch at Login, "Check automatically" (Software Update), and "Collect on-device diagnostics" (Advanced) now use the standard row: name and short description on the left, switch on the right. Same layout as every other toggle in Settings.
- **Lighter on your Mac.** WolfWave does a lot less work between songs now. Chat lines that aren't commands bail out immediately, the request poller sleeps when nothing is playing and the queue is empty, and Discord and your overlay only get an update when something actually changed instead of every few seconds. The History pane stopped re-sorting your whole play log twice on every redraw. Same features, less CPU and battery.
- **Lighter OBS overlay.** Progress painting is batched at 10 Hz, and animation work stops while the page is hidden or unloaded and when reduced motion is enabled.
- **Less background work.** WolfWave now pauses unused overlay, Twitch, song-request, and Discord tasks instead of polling or retrying while those features are idle, disconnected, held, hidden, or disabled.
- **What's New only shows up for feature releases.** The window used to reappear after every version bump, including bug-fix ones, showing a stale feature list. It now opens once per release that actually ships features.
- **Dev builds have their own app icon.** If you build WolfWave from source, the Debug app now carries an orange icon instead of the blue one, so **WolfWave Dev** and the release app are easy to tell apart in the Dock and the app switcher. Nothing changes for anyone installing from a DMG or Homebrew.

### Fixed

- **Settings no longer crashes on an out-of-range saved value.** If a setting on disk held a value the control couldn't show, opening that pane could take the whole Settings window down instead of just looking wrong. The Song Requests pane did exactly that with a bad vote-skip window. Saved values are now checked as they're read, and anything out of range or corrupted shows as that setting's default until you change it.
- **Song request setup now checks the playlist Music can actually see.** WolfWave makes the WolfWave Requests playlist in your Apple Music library, but songs play out of the Music app on this Mac. Setup only ever checked the first half, so it could tell you everything was ready while requests had nothing to play from. It now asks Music directly, and says so plainly if Music can't see the playlist, pointing you at Sync Library in Music, Settings, General. It's a heads-up, not a lockout: song requests stay on, and there's a Check Again button for once you've flipped it.
- **Settings backups now restore live behavior, not just switches.** Appearance, update settings, and Launch at Login take effect during import; pending login-item approval points to System Settings, invalid or unrepresentable values are ignored, Song Requests stay off until setup is complete, and the preview count matches what will actually restore. Backups created by WolfWave 2.1.0 require 2.1.0 or newer to import; backups from earlier versions still import into 2.1.0.
- **Notifications no longer stack or arrive out of order.** A new song or skip-vote banner clears both the queued and the already-shown banner it replaces, banners of the same kind are posted one at a time so a slow older one can't appear after a newer one, and a slow old artwork lookup can no longer overwrite the latest notification.
- **Cleared artwork stays cleared.** An artwork lookup already in flight can no longer refill the cache after you clear it, and artist/title combinations containing punctuation no longer share cache entries.
- **Pasted music links resolve reliably.** Song requests now find the first supported link in a message, ignore surrounding punctuation, and reject insecure or lookalike Apple Music URLs.
- **Twitch sign-in survives service hiccups.** Device-code login now uses the original expiry deadline, follows the required polling slowdown and timeout backoff, and keeps trying through rate limits plus temporary network or server failures instead of failing early.
- **Twitch no longer mistakes an outage for an expired sign-in.** Only Twitch's explicit token rejection or confirmed missing permissions prompts a reconnect. Network errors, rate limits, and malformed refresh responses retry within a bounded window and leave saved credentials intact when Twitch remains unavailable.
- **Disconnecting Twitch no longer gets stuck after a refund write fails.** If WolfWave couldn't save a channel-point refund to disk and the account was then switched or removed, it kept retrying against credentials that no longer existed and held Disconnect open. It now stops once nothing can act on that redemption. The points are still refunded: the next sign-in for that reward reads your unfulfilled redemptions straight from Twitch and settles them before the reward goes live again.
- **Twitch account changes stay internally consistent.** Access tokens, refresh tokens, account identity, and the configured channel now change together in one Keychain write. Existing saved fields migrate without deleting the originals until the new record is safe. Imported and edited channel names are checked with Twitch before becoming canonical; invalid, missing, stale, or temporarily unverifiable names stay pending.
- **Settings backups preserve authored rules.** Custom bot commands and the Song Request blocklist now round-trip with other portable preferences, and Reset Settings clears the centralized blocklist data.
- **A backup that can't be applied safely is refused outright.** Custom commands with a blank, duplicated, or clashing trigger, or with cooldowns the sliders can't represent, stop the import instead of half-landing. A file saved in an older, unsupported format now says so plainly rather than failing with a generic error. Blocked titles and artists get trimmed and checked on the way in, and keep the date you added them.
- **Channel names are tidied on the way in and out.** An imported or exported Twitch channel name is cleaned up the same way the connect screen does it, so a stray space or a pasted URL fragment can't leave you with a channel that never connects.
- **Slow Twitch commands no longer hold up chat.** Song requests and custom commands run as tracked connection work, so keepalives and later messages continue; disconnecting or switching channels cancels old replies before they can land in the wrong chat.
- **Paid Twitch actions recover after quits and outages.** Channel-point intake and fulfill/refund outcomes are durable until Twitch acknowledges them. Qualifying Bits cheers persist the complete boost/request action before queue work and replay after relaunch. If local recovery storage fails, WolfWave pauses the managed reward, shows a warning, and still gives an already-paid Bits cheer one process-owned attempt.
- **Discord presence replies no longer cross wires or hang indefinitely.** Each local IPC command consumes the response with its own nonce, the handshake accepts only Discord's READY dispatch, and stalled local connects or replies now stop at one bounded deadline.
- **Duplicate Twitch commands stay single-shot.** Command message IDs keep their complete replay window even in busy chat, including while commands are disabled, so delayed EventSub redelivery cannot rerun queue or playback actions.
- **Local WebSocket peers can no longer hold unlimited resources.** WolfWave caps pre-handshake peers, expires stalled handshakes, limits inbound messages to 16 KiB, and cleans every old listener generation before retrying.
- **Stream Deck reconnects no longer crash while a socket is still opening.** Retiring a connecting socket now keeps the required error sink until close.
- **Stream Deck control is local-only and no longer shares your overlay secret.** WolfWave now keeps separate read-only overlay and control tokens. Stream Deck protocol v2 always connects to this Mac, so LAN widgets can still receive track data but can never run playback or queue commands. After updating, copy the new **Stream Deck Control Token** into the plugin once.
- **Twitch custom commands stay locked while disconnected.** The settings card now explains that Twitch must be connected and closes an open editor if the connection becomes unavailable.
- **The custom-command editor catches clashing aliases.** It used to flag only a duplicated trigger, so an alias that shadowed another command slipped through and one of the two commands never fired. Commands saved before this check are cleaned up the next time WolfWave loads them.
- **Twitch stays connected when its server moves you.** Twitch periodically hands your connection to a different server. WolfWave could flash "disconnected" and tear down the new, healthy connection while doing that. It rides through cleanly now.
- **Low Power Mode no longer stalls launch.** Startup reads the posted power-state snapshot without recursively initializing the monitor.
- **Discord presence settings apply immediately.** Idle presence and "hide while paused" changes refresh at once, preserve the paused track for restoration, and stay hidden when Discord is enabled mid-pause.
- **Apple Music stays closed when you close it.** WolfWave no longer reopens Music.app after you quit it, and no longer opens it on its own while running.
- **WolfWave tells you when Music isn't open.** The now-playing card used to say "Nothing playing right now" whether Music was closed or just idle. It now says "Apple Music isn't open" with an Open Music button when the app is shut.
- **Settings sidebar no longer opens too narrow.** The sidebar could come back squeezed from a previous session and cut off section names like "Stream Widgets". It now uses a fixed width, matching System Settings, and a stale saved width can no longer be restored over it.
- **Version history opens instead of downloading.** Clicking "version history" in the update window saved an HTML file to your Downloads instead of showing the changelog. The notes are embedded in the update feed now, so they render in place.
- **Overlays keep working after you change the token or port.** Regenerating your access token or changing the port could leave every new OBS source getting rejected until you restarted WolfWave.
- **No more crashes from bad saved data.** A corrupted settings backup could crash the app the next time chat ran `!voteskip`, and one bad line in your listening history could crash the History pane and `!stats` every time they drew. Both are handled now, and a full disk no longer takes the app down while it's writing a log.
- **No more long freezes from song requests.** Every command WolfWave sends Apple Music now gives up after a couple of seconds, so a slow or busy Music.app can't lock the app up while the request queue auto-advances or when you hit play, pause, or skip.
- **Stream Deck overlay key stays connected.** The action now hides or shows overlay cards without dropping the authenticated control socket, so the next key press and its acknowledgement still work.
- **Advanced settings opens instantly.** Log size and line count load in the background now, so a large log file no longer stalls the pane when it appears.
- **Album art stays current.** A slow old lookup can no longer replace the current track's art, temporary download failures remain retryable, and the tray's decoded-art cache is bounded.
- **Accurate lifetime stats after a hard quit.** Listening History no longer double-counts old plays if WolfWave is force-quit or crashes while it's trimming its history.
- **Song requests survive playback races.** A failed or cancelled Apple Music start no longer loses the next request, and overlapping clears or queue edits while Music is responding can no longer revive an old item or overwrite the new order. Playlist setup coalesces simultaneous creation and stale-playlist recovery, follows every discovery page safely, and never adopts a same-name playlist that the user made.
- **Vote-skip stays with the poll and song that started it.** Delayed or unrelated Twitch poll results can no longer skip a replacement track or clear the real active poll. If Twitch may have created a poll but did not return a trustworthy answer, WolfWave waits for timeout instead of opening a simultaneous chat tally or second poll.
- **History clears and rankings stay exact.** Clearing history during its launch-time disk read can no longer restore old plays, finite retention no longer resurrects undated lifetime data, and tied stats and Monthly Wrap results are deterministic.
- **Clean Twitch sign-in cancel.** Cancelling the Twitch connect flow no longer flashes a false "OAuth setup failed" error.
- **Steadier under the hood.** Hardened Discord Rich Presence against a rare bad-playback-position crash, stopped a Twitch rate-limit wait from spinning the CPU when a connection drops, and made LAN IP detection skip a bad network interface instead of showing a blank overlay address.
- **"Open in Music" works in Song Requests setup.** The button in step 4 (Share your playlist) did nothing. It now brings Music forward and selects your WolfWave Requests playlist.
- **Nightly testers can get back to Stable.** Switching the Update Channel back to Stable now works on its own: the next stable release offers itself like any other update, instead of leaving you stuck until you manually reinstalled the DMG. One exception, one time: if you installed the August 5, 2026 nightly, grab any newer DMG once — that specific build can't update itself. See [Nightly Builds](https://wolfwave.mrdemonwolf.dev/docs/nightly).
- **Song requests and playback controls reach Apple Music again.** Nightly builds from August 4, 2026 onward couldn't send Music.app a single command. The request queue never advanced to the next song, and `!skip`, `!voteskip`, the tray play/pause, and "Open in Music" all did nothing. Stable 2.0.1 was never affected. Music still stays closed when you close it.
- **The now-playing card stopped going blank while music played.** If you played an album or a song straight from your library rather than from a playlist, WolfWave threw away a perfectly good track reading and showed nothing. The card, Discord Rich Presence, and your overlay all went empty until you happened to play from a playlist. Also affected nightly builds only; stable 2.0.1 was fine.

### Developer

- Test target builds clean: `xcodebuild build-for-testing` went from 206 warnings to 0. Every one was in `WolfWaveTests`; the app target was already warning-free. Five `#expect(auth != nil)` assertions in `TwitchDeviceAuthTests` compared a non-optional against `nil`, so they were always true and tested nothing; they and their construction-only test cases are gone, since `TwitchDeviceAuth` stores everything privately and `TwitchDeviceAuthNetworkTests` already asserts the encoded `scopes` form field for real. Sync `setUp`/`tearDown` overrides in 22 `@MainActor` test classes are now `async throws` overrides, which do inherit the class's main-actor isolation and clear all 84 actor-isolation warnings; `MainActor.assumeIsolated` was tried first and does not compile here ("sending 'self' risks causing data races"). The 104 discarded `SongRequestQueue.add(_:perUserLimit:)` results became explicit `_ =` rather than marking the method `@discardableResult`, because its `AddResult` rejection reason is load-bearing for the real caller in `SongRequestService`.
- `KeychainServiceTests` no longer flakes in a full-suite run. `KeychainService.backend` was one process-wide variable, and Swift Testing runs suites in parallel, so a suite that installed an inspectable backend was reachable by every suite running beside it. `TwitchViewModelTests.clearCredentials()` deleted the exact legacy accounts the Keychain suite had just seeded, and the shared `twitchReauthNeeded` default was rewritten mid-assertion. A backend read could even complete its legacy-field probes against a backend swapped in underneath it. Reads and writes now resolve through a `@TaskLocal` `KeychainService.backendBox` when one is bound, and the new `.isolatedKeychainBackend` Swift Testing trait binds one per test, so a suite's backend is unreachable outside its own task tree. Suites that touch the shared Twitch credential state use `KeychainBackendTestIsolation.withIsolatedCredentialState`; `@MainActor` XCTest suites acquire that lock with `acquireAsync()` from `setUp() async throws`, since blocking the main thread deadlocks against a `@MainActor` holder suspended mid-`await`. A test that drives the Keychain from a `DispatchQueue` block leaves the task tree and must rebind the box inside it.
- Unit tests can no longer edit the dev app's real settings. The test bundle is hosted by `WolfWave Dev.app`, so `UserDefaults.standard` inside a test process was literally that app's live preference domain: tests wrote settings into it, and `WolfWaveTestCase.resetAllSettings()` deleted every known key out of it. One such write (`voteSkipWindowSeconds = 1`, not a valid picker tag) crashed the Song Requests pane inside SwiftUI on the next launch. Every non-`@AppStorage` read and write now goes through a new `DefaultsStore.store`, which resolves to a dedicated suite under test and to `.standard` in a normal launch, mirroring `KeychainService.backend`. Pinned by `DefaultsStoreTests` and a blocking `user_defaults_standard` SwiftLint rule.
- Docs restructure: merged the Features/Usage and Getting Started/Development pages, added Settings and Stream Deck Control API pages, trimmed the comparison page, and refreshed the legal pages.
- Debug builds can treat every chatter, or selected Twitch logins, as normal viewers for permission and cooldown testing. Release builds omit the simulator.

- New `BotCommand.isAllowed(context:)` permission hook and `allTriggers` protocol requirement (both default-preserving, so built-ins are unchanged). `CustomBotCommand` is an `AsyncBotCommand` built per message from `CustomCommandStore`, so edits apply on the next chat line without re-registration. Pure `CustomCommandRenderer` covers variable substitution; 21 new tests.
- Stream Deck control API (groundwork for the upcoming plugin, WW-36). The overlay WebSocket is now bidirectional: it parses a protocol-versioned inbound `command` envelope, runs it through a router mapping 11 actions to existing services, and replies with an `ack`; new `queue_state` / `health` broadcasts drive counter/health keys. The connection is still gated by the per-install `wolfwave.token.<hex>` handshake. Pure `StreamDeckControl.parse` with new tests. See `apps/native/docs/streamdeck-control-api.md`.
- Adversarially-verified crash/lockup/data-race review pass. `AppleMusicController` runs `NSAppleScript` on `@MainActor` with bounded Apple Event timeouts, and `playbackSnapshot()` plus the playback commands are `async` for structured-concurrency callers (the dead `isPlaying`/`isPaused`/`currentTrackID` reads were dropped). `RateLimiter.awaitCapacity` unwinds on cancellation instead of busy-spinning. `LifetimeTally` gained an optional `lastFoldedTimestamp` high-water mark so a crash-recovery reload can't re-fold overflow records, and `ListeningHistoryService` coalesces concurrent loads. Plus the Stream Deck overlay toggle now changes card visibility without stopping the authenticated WebSocket control channel or companion HTTP server, alongside a finiteness guard on Discord presence timestamps, an off-main log-stats read in the Advanced pane, a Twitch sign-in cancel guard, and a `getnameinfo` return-code check.
- `queue_state` gained a `held` field carrying real request-queue hold state (`SongRequestService.isHoldEnabled`), and `SongRequestHoldChanged` now triggers a Stream Deck rebroadcast alongside `SongRequestQueueChanged`. Without it a hold key had to track its own optimistic toggle, which inverted the moment hold was changed from the tray, chat (`!hold`), or Settings. Additive on an outbound broadcast, so no `protocolVersion` bump — the version gates the inbound command envelope only.
- Stream Deck plugin, Phase B (WW-45), in the new `apps/streamdeck/` bun workspace. Consumes the Phase A control API: `src/wolfwave/protocol.ts` is the TypeScript mirror of `StreamDeckCommand.swift` (action tokens are the Swift enum's raw values; a test pins the full v1 set so the two can't drift), `state.ts` is a pure reducer that returns the same reference on an unchanged fold so per-second `progress` frames don't repaint keys, and `client.ts` holds one shared socket for all keys with capped reconnect backoff and FIFO ack correlation. Eleven key classes over a base that paints the disconnected / unauthorized / outdated states centrally, plus a Property Inspector that talks Elgato's protocol directly rather than loading `sdpi-components` from a CDN. Bundled for Node (Stream Deck runs `CodePath` under its own Node), output gitignored — it ships through Elgato, not inside the app. Icons are generated from the brand mark by `scripts/generate-icons.ts` (SVG everywhere Elgato allows it, so there is no @1x/@2x pair to drift; PNG only for the plugin icon, which Elgato requires), and `bun run --filter streamdeck pack` produces the `.streamDeckPlugin`. A new CI job typechecks, tests, packages, and fails on icon drift. **Still outstanding**: verification on real hardware, and the Marketplace submission itself.
- Steady-state performance pass: ten hot-path fixes, all behaviour-preserving, each removing work that repeated every ~5s tick or per chat line. `BotCommandDispatcher` early-outs on a missing `!` prefix before the command-table snapshot copy and per-command alias `UserDefaults` reads; `SongRequestService.pollTick` early-outs when nothing is playing and the queue is empty, skipping a 2s AppleScript round trip; `AppleMusicController` uses targeted `runningApplications(withBundleIdentifier:)` and caches compiled `NSAppleScript` by source; `DiscordRPCService.updatePresence` skips unchanged `SET_ACTIVITY` frames and `WebSocketServerService.updateNowPlaying` skips unchanged rebroadcasts; widget artwork only refetches on a genuine track change; `MusicMonitorSettingsView` stops restarting `AsyncImage` every tick; `HistoryStatsSettingsView` dropped a twice-per-body-pass O(n log n) sort over up to ~10k records; `SongBlocklist.isBlocked` lowercases once instead of per entry.
- Concurrency correctness pass: ten adversarially-verified race and leak fixes. `TwitchChatService` now posts `NotificationCenter` from `@MainActor` (panes observe via `.onReceive` with no main hop) and bails out of `handleReceiveError` on `Task.isCancelled` so an orphaned receive loop can't undo a session migration; `DiscordRPCService.connectIfNeeded` re-validates generation/enabled/fd after its two-await handshake; `WebSocketServerService` detaches `stateUpdateHandler` before cancel and cancels failed connections; `MonthlyWrapView.loadTint` guards cancellation. Leaks closed in `TwitchViewModel.deinit` (connection-observer task), `TwitchChatService.deinit` (URLSession), and `NotificationService` (stranded artwork temp files when authorization is denied). `MusicPermissionCache` traded `nonisolated(unsafe)` statics for `@MainActor` isolation.
- Crash-guard pass: four process-abort vectors reachable from external or user-writable data, none caught by the force-op lint gate. `Int(Double)` traps clamped in `MetricsService.recordTwitchRateLimit` (a `Ratelimit-Reset` header of `inf`/`nan`/`1e999`), `SkipVoteManager.sessionCooldown` (unclamped and exportable, so a corrupt backup crashed the next `!voteskip`), and `HistoryFormat.listeningTime`/`clock` (plus sanitizing `duration`/`playedSeconds` at the `PlayRecord` decode boundary). `Logger` swapped six legacy raising `synchronizeFile()`/`closeFile()` sites for `try? synchronize()`/`close()`, which were aborting mid-error-handling on fsync `ENOSPC`/`EIO`. Regression tests feed `inf`/`nan`/`1e300` to each converter.
- DRY pass across the codebase: 20 mechanical extractions, no behaviour change. Shared HTTP-response / widget-config / now-playing / JSON-guard helpers, an EventSub body + form-POST + custom-rewards URL builder, shared day-bucketing and history-store filesystem helpers, a shared song-request dedup predicate and capacity insert, `BotCommand.commandToken(in:)` shared across the command match loops, `SectionHeaderWithStatus` reused at 10 hand-rolled header sites, and centralized setting + widget-appearance defaults.
- Source layout split for readability, no behaviour change: `AppConstants` into per-namespace `extension` files, `DiscordRPCService` into a pure `DiscordPresenceBuilder` plus an IPC seam, and the `TwitchChatService` actor across same-actor seam files (`+Auth`, `+Connection`, `+EventSub`, `+Redemptions`).
- Dead code removed and stale doc comments corrected: ~89 unused lines from `ViewModifiers` (`interactiveRow`, `cardClipShape`, the reduce-motion helpers, the `NotificationCenter.post(_:)` shorthand), plus doc fixes across the playback monitor, `SettingsView`/`SettingsNavRail`, `TwitchViewModel`, `AppConstants`, `SparkleUpdaterService`, `WidgetHTTPService`, and the Discord / Twitch / WebSocket settings views, each verified against the actual code.
- Swift file headers normalized to the header Xcode generates from `IDETemplateMacros.plist`, with each `Created by` date reset to the file's real git creation date. New `scripts/check-headers.mjs` (`make lint-headers`, plus a blocking CI job) keeps them from drifting again.
- CI hardening: new SwiftLint baseline gate blocks new violations without requiring the existing backlog to be cleared, and the full test suite now runs unskipped on `macos-26` (the weekly canary is retired). Sparkle appcast generation passes `--embed-release-notes` and fails the build if the notes aren't inline. Nightly releases are titled by their build commit's short SHA while keeping the fixed rolling `nightly` tag the appcast depends on.
- `AGENTS.md` added (Codex guidance mirroring `CLAUDE.md`), and `FEATURE_IDEAS.md` retired in favour of Jira project `WW`.
- Docs site and landing page pass: WCAG AA/AAA contrast in both themes (new `--brand-fill` token for white-on-blue fills), mobile hardening (40px+ tap targets, single-column stat grid under 420px, opaque mobile TOC backing, the sticky first table column the CSS comment had only promised), de-AI'd copy, the redundant "Open & trusted" proof band dropped with the section spine renumbered to a contiguous 01–08, per-page eyebrows moved from in-body spans to the route, corrected download / on-disk size claims measured against the shipped v2.0.1 artifacts, and Instrument Sans replacing Unbounded.
- OBS resource pass: the browser batches progress paint at 10 Hz and fully suspends when hidden/unloaded/reduced-motion; native progress work exists only while enabled, visible, playing, and serving clients, and JSON fan-out encodes once.
- Idle-service pass: Twitch owns one keepalive/session with bounded classified retries and tears network work down on leave; Song Requests stops auto-advance polling while idle/held/disabled; Discord polls availability only while enabled and disconnected; decoded tray art is single-flight and bounded to 64 items / 32 MiB; duplicate startup warming was removed and reduced-power policy applies immediately.
- ScriptingBridge now addresses Music.app by **pid**, never by bundle identifier. A bundle-id-addressed Apple event is auto-launched by LaunchServices, so `SBApplication(bundleIdentifier:)` and a bare `tell application "Music"` both start Music when it isn't running; `LSLaunchFlags` has no opt-out. Guarding with an is-running check before the send only narrows the race, which is why this shipped twice before (#203, #273) and came back both times. `AppleMusicSource` resolves `MusicProcess.pid` and uses `SBApplication(processIdentifier:)`. AppleScript cannot do the same (see the addressing entry below), so `AppleMusicController.musicTargetedScript` gates every script on `application id "com.apple.Music" is running` (evaluated without launching), raising `-600` when closed so callers take their existing no-information path. Note that `SBApplication(processIdentifier:)` does **not** return nil for an unresolvable pid as its header claims — it returns a non-KVC-compliant object whose `value(forKey:)` raises `NSUnknownKeyException`, so the read is gated on `isRunning` + `responds(to:)`. New shared `Core/MusicProcess.swift` replaces three duplicated is-running checks; a SwiftLint custom rule now bans `SBApplication(bundleIdentifier:`.
- Local Debug builds sign with a stable Apple Development identity instead of ad-hoc. Ad-hoc signatures derive from the binary hash, so every rebuild looked like a different app and invalidated both the Keychain ACL and the TCC Automation grant, producing a password prompt on each launch. CI keeps ad-hoc signing (`test-ci` unchanged) and the Makefile falls back to it when no identity is present.
- `scripts/check-test-results.sh` fixes: it summed the per-suite *and* enclosing-suite `Executed N tests` lines (an 18-test suite reported as 54), its failure-detail grep matched none of the formats xcodebuild actually emits, and it ignored Swift Testing entirely — so a failing `@Test` reported zero failures and exited 0.
- Fixed a flaky listening-history test. "clear during load discards stale disk data and pre-clear buffer" asserted the play log through a second `PlayLogStore` instance over the same file. `PlayLogStore.append` is async on the instance's own serial `ioQueue`, so `loadAll()` is ordered behind an append only on that same instance; every other test reading a separate instance first calls `shutdown()`, whose `flush()` drains the queue. The test now shares the store it asserts through. The production clear-vs-load generation seam was not implicated.
- `WidgetHTTPServiceTests` no longer pins ports 59995/59993; both tests use the existing `startBoundService` port walker, so a lingering socket or a running WolfWave can't fail the suite.
- Loopback test servers now bind port `0` and read the kernel-assigned port back from a new `boundPort` accessor on `WidgetHTTPService` and `WebSocketServerService`. Walking a fixed window wasn't enough: 59900-59919 (and the WebSocket suite's 59003-59012) sit inside the macOS ephemeral range, so an unrelated process holding those source ports failed the bind — Chrome owning four of the twenty made `testPublicWidgetResponseContainsShippedAssetAndPrivacyPolicy` fail on clean `main`. The port-conflict test now aims its second server at the port the first was just given, so the collision it asserts is the only one that can happen.
- Build/version standard, applied to both release feeds. New `scripts/version.sh` is the single source of truth for marketing version + build number; `build_release.yml` and `nightly.yml` both call it and inject `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` at build time, so the pbxproj build number is now a dev-only placeholder and is no longer hand-bumped. Build number is `git rev-list --count HEAD` (floored), shared by both channels — the retired nightly scheme used a UTC minute stamp (~2×10¹¹), which is ~100× over Android's `versionCode` cap and sat so far above stable that no release could ever overtake it. Both workflows now need `fetch-depth: 0`; the resolver hard-fails on a shallow clone. Rationale and the portable cross-platform rules are in `docs/build-versioning-standard.md`. `version.sh` also warns when the committed `MARKETING_VERSION` still equals the newest `v*` tag, since nightlies advertise the *next* release version and that means the post-release bump-ahead was skipped.
- Documentation sync across the repo. `README.md` and `CLAUDE.md` corrected to Swift 6.0 / Xcode 26 (both still claimed 5.9 / 16), five bot commands had undocumented aliases added (`!request`, `!songrequest`, `!songlist`, `!requests`, `!mysongs`, `!musicstats`, `!cq`), `!hold`/`!resume` collapsed into the single command it actually is, and the seven undocumented `make` targets added, including all four lint entry points. `apps/streamdeck/` is now named in the README feature list and project tree instead of being referred to hypothetically. `CLAUDE.md` gained the three missing source files (`MusicProcess.swift`, `DebugDiagnostics.swift`, `OnboardingView.swift`), the four missing test files, the `//#ds:lint` root task, and an accurate CI table (the `test.yml` bullet described one job; there are seven, plus three drift gates). The dead `usage.mdx` reference was replaced with `settings.mdx` in both `CLAUDE.md` and the PR template. `apps/widget/README.md` asserted a closed set of six URL params and was missing `queueTicker`. The design-system catalog documented three modifiers deleted in the 2.1.0 dead-code sweep (`interactiveRow`, `Animation.reducedMotion`, `reduceMotionAware`), `design-system/README.md` listed a `tokens.schema.json` that never existed and claimed the docs site renders the catalog, and `OnboardingStepScaffold` had no catalog entry despite the README promising full coverage. The shipped nightly-channel plan and the Stream Deck control API doc are now marked as historical and living-reference respectively.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), and `.github/ISSUE_TEMPLATE/config.yml` added. The config disables blank issues and routes feature ideas to Discord, which is where they have gone since `FEATURE_IDEAS.md` was retired.
- `AUDIT.md` removed. Its 100 findings were all resolved back in 2.0.0 per its own Resolution block, and it cited two files that no longer exist plus a test count roughly 3x low.
- `tokens.schema.json` is now enforced, not just advisory. New `bun run ds:schema` (`design-system/scripts/validate-tokens.ts`) validates `tokens.json` against it and runs as a step on the existing `ds-lint` CI job. The schema shipped without anything executing it, so it only helped editors that honour `$schema` and could drift from `tokens.json` unnoticed. It was verified correct before wiring: `tokens.json` validates clean, and nine injected mistakes (dropped namespace, typo'd namespace, unknown namespace, malformed hex, wrong scalar type, empty theme/layout maps) are all rejected. The `ds-lint` path filter previously covered only Views and the lint script, so it now also watches `tokens.json`, the schema, `package.json`, and `bun.lock`; the job gained a `bun install` step because `ds:lint` is dependency-free but `ds:schema` needs `ajv`. Adding a new top-level token namespace now requires updating the schema in the same change, which is the intended coupling: `generate.ts` reads namespaces by name and emits five platform outputs without checking shape first.
- Settings-import hardening follow-up. Four keys had gone missing from the `AppConstants.UserDefaults` classification (`twitchPendingImportedChannelName`, `songRequestBlocklist`, `songRequestChannelPointsRewardIdentity`, `songRequestPlaylistID`), so `SettingsBackupKeyCoverageTests` wasn't asserting them and the blocklist didn't actually round-trip. `SettingsBackupCoder.isValueAllowed` became `normalizedValue`, turning the single validator into a canonicalizer shared by export, preview, and apply; channel names route through `TwitchChatService.normalizedChannelName` at all three, and a below-minimum `schemaVersion` now raises `BackupError.unsupportedOlderSchema`. New `CustomCommand.normalizedForImport` / `normalizedForExistingStorage` reject or repair persisted commands (empty or overlapping triggers, duplicate UUIDs, cooldowns outside `globalCooldownRange` / `userCooldownRange`), and `BlocklistItem` validates decoded entries while retaining persisted `id` and `addedAt`. `NotificationService` chains submission per `PostGenerationDomain`, closing the main-actor reentrancy window at `center.add` that let an older request finish after a newer one.
- AppleScript addressing corrected, and the test gap that hid it closed. PR #410 replaced the working `timeoutWrapped` guard from #392 with `pidTargetedScript`, which passed an `NSAppleEventDescriptor(processIdentifier:)` as a handler *argument* and did `tell musicTarget`. A raw kernel-pid descriptor is an Apple Event **address**, not an application specifier, and `NSAppleScript` has no coercion from one to the other: it arrives as opaque `«data kpid…»` with no terminology bound, so AppleScript evaluated every body against a meaningless object. Every property read failed `-1728` and every verb `-1708`, which killed `playbackSnapshot` and all nine playback commands. Note the blast radius stops there: the now-playing card is fed by `AppleMusicSource` (ScriptingBridge, untouched here) and `runSetupHealthCheck` resolves through MusicKit and `AppleMusicLibraryService`, so neither could have failed this way. A blank card is a separate cause, almost always a missing Automation grant. Pid addressing is a ScriptingBridge capability only; `MusicProcess`'s doc comment now says so explicitly, since its earlier wording is what invited the mistake. `musicTargetedScript` restores #392's in-script `is running` guard (verified empirically to raise `-600` without launching the target) and addresses Music by bundle id. #425's rule that only application-level *verbs* were affected was wrong: `player state` is an application-level property and failed identically. The tests are the real fix: the deleted `#expect(target?.descriptorType == typeKernelProcessID)` asserted an event descriptor's *shape* and stayed green through a total runtime failure, replaced by guards on addressing form, guard-before-`tell` ordering, and the `-600` contract, plus a DEBUG-only Music access self-test in the Debug tab for the class of failure no unit test can reach.
- Vacuity sweep of the song-request suite, prompted by the descriptor-shape test above. `MockAppleMusicController.searchProvider` was never assigned anywhere in `SongRequestServiceTests`, so `search` always returned `.notFound` and `processRequest` short-circuited before reaching any gate. Four tests asserted `playNowCalled == false` after a request that could not have called `playNow` under any conditions: the hold gate, the Music-closed buffering gate, the requeue-on-throw path, and the redemption audience bypass could each be deleted outright with the suite green. The audience test was doubly empty, since its assertions sat inside an `if case .error` that never matched and looked for `"Mods"`, which does not appear in `"Only mods can request songs right now."`. Compounding it, `performPlayback` has an `#if DEBUG return` escape hatch for an item with a nil `song`, so items built with the test-only `SongRequestItem` initializer fake a successful start and never reach the controller at all. New `TestSongFactory.makeTestSong` decodes a real MusicKit `Song` from the Apple Music resource shape (`Song` has no public initializer, which is why no test had one), a `stubSearchSuccess` helper resolves each distinct query to a distinct song, and the repaired tests assert their precondition actually held before asserting the behaviour. Added a hold-off control test so the hold assertion is falsifiable.
- The second half of the #410 regression: a benign `-1728` was treated as fatal and blanked the now-playing card. #410 added `bridgeFailure` checks to `AppleMusicSource.checkCurrentTrack`; v2.0.1 had none and was unaffected. The last of them fired *after* a complete, correct track string had already been assembled, so any ScriptingBridge error during the optional metadata reads discarded the whole result and returned "Script error". `currentPlaylist` raises `-1728` whenever the track is not playing from a playlist, which is the normal case for an album or a direct library play, so the card, Discord presence, and the overlay all went empty for a large fraction of ordinary listening. Verified live: with a track playing outside a playlist, `artist`, `album`, `duration`, and `player position` all read fine while `name of current playlist` returns `-1728`. That check is gone; every field there already has a safe default and `trackName` is validated above it, so the error is consumed rather than promoted. The `currentTrack`-stage `-1728` now maps to `NOT_PLAYING`, which is what Music means by it, instead of a script error the UI cannot act on. Failures carry a `Constants.BridgeStage` so a logged bridge error names which Apple Event failed, and bridge errors no longer borrow the "playerState bridge unknown" wording that sent this investigation down the wrong path twice.
- The `#if DEBUG return` escape hatch in `performPlayback` is gone, so DEBUG and Release now take the same path. Removing it turned eight passing tests red at once, which is the whole point. The queue only commits an item to now-playing *after* the controller accepts it, so `testSkipWithQueueItemsAdvancesInternalQueue`, `testRequestWaitsForStreamersOwnTrackToEnd`, `testBoostStartsImmediatelyWhenPlayerIsIdle`, `testSkipInsideMusicAppAdvancesRequestQueue`, both fallback-yield tests, and both `sendChatMessage` tests had each been asserting a commit that the hatch, not the code under test, produced. Four more stayed green while proving nothing, since `playNowCalled == false` is free when `playNow` is unreachable: the flaky-read, transient-blip, boost-no-interrupt, and paused-auto-advance tests. New `makeTestRequestItem` builds a queue item around a real `Song`, and every test whose subject is downstream of playback now uses it. `testSkipInsideMusicAppAdvancesRequestQueue` carried a comment explaining that `playNow` was "intentionally skipped" — it asserts the call now.
- `SongRequestItem.song` is non-optional, so the bug class above is unrepresentable rather than guarded. It was `Song?` only so tests could build an item without one, which made "a queue item that cannot be played" a legal state that nothing outside a test fixture ever produced, and forced a nil branch into both `SongRequestService.performPlayback` and `AppleMusicController.performTargetedPlayback`. Both branches are gone, and `SongRequestQueueView`'s rebuild list drops a `compactMap` that could only ever have discarded a test fixture. The song-less initializer is deleted; tests build items through `makeTestRequestItem`. The Debug tab's fake-request injector needed real songs too, so the Apple Music resource-shape decode moved to `Song.debugPlaceholder` in the app target under `#if DEBUG` and the test factory delegates to it — one copy of that shape, so a MusicKit change breaks both together instead of letting them drift.
- Test-quality pass on the backup and artwork suites: `SettingsBackupCoderTests` compares persisted models instead of raw encoded bytes (byte equality was brittle against key ordering), blocklist round-trips are compared by semantics rather than encoding, `ArtworkServiceNetworkTests` uses isolated mock URL sessions, and the notification test double reports an authorization status.

## [2.0.1] - 2026-07-11

### Fixed

- **Update notes now load.** Sparkle's "What's New" window no longer 404s when you check for updates. (It broke in 2.0.0.)
- **Fewer crashes.** Fixed a crash for people who opted into diagnostics, a crash from an out-of-range widget port, and hard failures when a log write hit a full disk.
- **Music.app can't freeze WolfWave.** Every command to Apple Music now times out instead of hanging the app if Music gets stuck.
- **Snappier menu bar.** Play/pause state reads from cache instead of pinging Music.app while the menu is open.
- **No double actions.** Twitch events that arrive twice (chat commands, channel-point redemptions) only run once now.
- **Overlays keep updating.** Closing the Settings window no longer stops now-playing updates from reaching your overlay.
- **Vote-skip won't get stuck.** A Twitch poll that never closes now falls back cleanly, and chat votes reset between songs.
- **Accurate history.** Listening History no longer double-counts a play, and tells apart songs that share a title.
- **`!playlist` survives hiccups.** A brief network blip while checking your playlist link no longer switches the command off.

### Developer

- Full multi-agent audit pass: 28 native + 9 OBS widget findings, adversarially verified and fixed (#351). `DiagnosticsService` nonisolated, throwing `FileHandle` in Logger, clamped `Preferences.resolvedWidgetPort`/`resolvedWebSocketServerPort`, EventSub `message_id` dedup, per-subscriber connection-state `AsyncStream`s.
- Release workflow uploads the Sparkle release-notes HTML with the DMG + appcast, and hard-fails if it's missing (#349).
- Docs / README / CLAUDE.md synced with the current source tree (#352).

## [2.0.0] - 2026-07-01

### Security

- **Stream Widgets now need an access token.** Every WebSocket client must authenticate with a per-install token kept in the Keychain. Localhost HTML receives it from WolfWave; LAN links carry it as connection bootstrap. Existing OBS sources keep working. Reveal, regenerate, or replace the token in Settings → Stream Widgets.
- **Streamer Mode.** One tray toggle hides anything you wouldn't want on camera: channel name, overlay and widget URLs, and the access token. Copy and Open buttons switch off too. On-screen only. Your overlay, Discord, and chat output are untouched.

### Added

**Song requests**

- **Song Requests.** Viewers request tracks with `!sr <song>`. Plays through Apple Music without stealing focus from your stream. Each request is saved to a "WolfWave Requests" playlist and played from there, so it works on macOS 26 (Tahoe), where Apple Music stopped letting apps play songs you haven't saved.
- **Guided setup.** A quick walk-through (Twitch, Apple Music access, your requests playlist) runs before song requests can be switched on, so nothing goes live half-configured. Re-run it anytime from the pane.
- **Queue commands.** `!queue` and `!myqueue` show the queue. `!skip`/`!next`, `!clearqueue`, and `!hold`/`!resume` are for mods and the broadcaster.
- **`!playlist` command.** Drops a link to your requests playlist in chat. Share the playlist in the guided setup and the link stays live as songs are added. If you later delete or un-share it, WolfWave turns `!playlist` off and shows a "set up again" banner so chat never gets a dead link. Off by default.
- **Chat Vote-Skip.** Chat votes out a song with `!vs`. Counts unique voters, or opens a native Twitch poll (Affiliate/Partner). Set it up in Settings → Song Requests.
- **Song Request Queue view.** A now-playing card, who asked for each track, and Skip / Hold / Clear.
- **Hold the queue.** New requests pile up without auto-playing, so you can line them up first. From the queue view or the menu bar.
- **Requests wait while Apple Music is closed.** Saved, then played when Music reopens.
- **Fallback playlist.** Plays an Apple Music playlist whenever the queue runs dry.
- **Limits and controls.** Per-user and global limits, subscriber-only mode, on/off per command, and custom aliases.
- **Recreate Reward button.** Rebuilds the "Request a Song" Channel-Point reward if you delete it by hand.

**Your music, tracked**

- **Listening History.** An opt-in, on-device log of what you play. Stays on your Mac, never uploaded. Off by default. Skips don't count.
- **Stats and Charts.** Top artists, listening time, a 7-day trend, and a by-hour breakdown. Needs Listening History on.
- **Monthly Wrap.** A personal "Wrapped" for any month. Save it as a PNG or share it.
- **History retention picker.** Keep history forever, or for 7 / 30 / 90 / 180 / 365 days.
- **`!stats` command.** Chat asks for today's top track. Only replies while you're live.

**On stream**

- **`!wolfwave` command.** A one-tap chat shoutout for the app. Four reply styles. Off by default.
- **Widget themes and layouts.** Five selectable themes (Default, Dark, Light, Glass, Neon), plus a hidden internal WolfWave theme, and five layouts (Horizontal, Vertical, Compact, Vinyl, Classic).
- **Live widget preview.** See your overlay update as you tweak the theme, layout, font, and colors.
- **Smoother OBS widget.** Songs slide in, fade out calmly, and crossfade on fast skips. No strobing.
- **Discord idle and pause controls.** Keep an idle marker when nothing plays, or clear your profile while paused. Both off by default.
- **Discord playlist in your presence.** Shows the current Apple Music playlist next to the track.
- **Song-change notifications.** An optional macOS banner on every track change. Off by default.
- **Skip-vote notifications.** Optional banners when a vote starts and when it passes. Off by default.

**The app**

- **Light, Dark, or System appearance.** Pick one in Settings → General. The menu bar follows too.
- **Back up and restore your settings.** Export to a JSON file, restore on another Mac. Credentials and private account IDs stay in the Keychain; the public Twitch channel name travels with your preferences. On import, you choose whether to reconnect Twitch.
- **macOS 26 Liquid Glass redesign.** Settings, menu bar, and a rebuilt onboarding wizard for Tahoe.
- **Nightly update channel.** Opt into dev builds off main from Settings → Software Update. Clearly warned, easy to leave, and Stable stays the default.
- **Diagnostics and bug reporting.** Export/Clear Logs and a one-click Report a Bug, with sensitive details redacted.
- **On-device diagnostics.** An opt-in MetricKit report with a share card. Stays on your Mac. Off by default.
- **Branded About window.** A native WolfWave About replaces the macOS default.
- **WolfMark branding.** A new album-art placeholder and brand polish across the app and overlay.
- **Faster overlay URLs.** WolfWave caches your local IP, so settings no longer pause looking it up.

### Changed

- **Clearer settings headings.** Every pane has one big title with section titles a step below, so it reads top to bottom at a glance. VoiceOver can jump between them by heading.
- **Redesigned Settings sidebar.** A branded header, grouped rows with round icon chips, and an accent-colored selection pill. Sections are grouped by what they're for.
- **Calmer destructive buttons.** Reset, Clear Logs, and Clear Artwork Cache drop the loud red bar for a neutral button with a red label. The Danger Zone card gets a red heading instead of a red wash.
- **Type RESET to wipe everything.** The Reset confirmation spells out what it erases and makes you type RESET first, so a stray click can't reset the app.
- **Apple Music playback keeps your focus.** Music never steals focus from OBS or other streaming tools.
- **MusicKit is only used for search**, never for playback.
- **Steadier under stress.** A safety net catches the rare hard crash. If WolfWave goes down, it shows a one-time "Recovered from a crash" notice in Advanced with a one-click bug report.
- **Permissions live in one onboarding step.** Apple Music access, the notification prompt, and the per-alert toggles are now together.
- **Onboarding polish.** Repeated success rows gone, tighter wording, and pinned sizes so nothing jumps around. VoiceOver announces each step by name.
- **Music permission row is actionable.** Tap it to re-request access or jump into System Settings.
- **App Visibility** is a single-column picker for the menu bar, the Dock, or both. General lays Startup and Display Mode side by side.
- **Tighter wording** across onboarding, settings, and the menu bar.

### Performance

- **Lower idle energy use.** Background timers now let macOS batch their wakeups together, which saves power for an all-day menu bar app. Real-time track changes still arrive instantly.
- **No more jank** when switching between settings sections.
- **Faster first paint** and an instant Now-Playing Server row, thanks to off-main-thread font lookup and the cached local IP.

### Developer

> Developer-facing changes. Not visible to end users.

- **Unified design system.** A single `design-system/tokens.json` feeds `generate.ts`, which emits four platform outputs (Swift `Tokens.generated.swift`, docs CSS, widget JS, marketing TS). A Turbo `tokens` task runs as a build prerequisite (#72, #76).
- **Component catalog.** `design-system/components/` gains one markdown entry per reusable view, tracked against a shared template (#76).
- **DEBUG-only Debug tab.** A developer tooling tab (inspectors, service controls, log/event views, UI previews) plus What's New preview controls, only in DEBUG builds (#66, #69).
- **Expanded design-token roster.** `font.size` gains the 9/15/16/18/24/26/28/36 px slots used across views; `space` gains `s0` (2 px), `s10` (32 px), and `s11` (44 px). Token-only additions with no visual change.
- **Sparkle delegate hardening.** Implemented `allowedSystemProfileKeys(for:)` returning an empty array, opting WolfWave out of Sparkle's system-profile telemetry (OS version, CPU arch, and bundle metadata never leave the user's machine on update checks). Documented why `automaticallyDownloadsUpdates = false`: explicit consent is required before bytes touch the disk.
- **WebSocket security-model docs.** Added a `## Security model` block to `WebSocketServerService.swift` describing the loopback-only contract.
- **New unit tests.** `SongBlocklistTests`, `HistoryFormattingTests`, and `LaunchAtLoginServiceTests` cover three previously-untested services.
- **OBS widget build pipeline.** The overlay source moved out of the hand-edited `apps/native/WolfWave/Resources/widget.html` into a new `apps/widget/` Tailwind + TypeScript workspace. The bundled HTML is now a generated, fully inlined artifact (compiled CSS, design tokens, and JS runtime in one file, no external `<link>` or `<script src>`). Xcode ships the committed `widget.html` as-is; CI rebuilds the widget before every `xcodebuild` run in `test.yml` and `build_release.yml` and fails the PR on any drift. Manual rebuild is `bun run --filter widget build`. The WebSocket payload, widget URL, and theme/layout params are unchanged. Source files are heavily commented so the runtime can be read end to end.
- **Inside-out release signing.** `build_release.yml` now signs nested bundles deepest-first before the app shell, dropping `--deep --force`, which stripped per-bundle entitlements. The pipeline is XPC-ready for a future sandbox helper (#199). The signing sweep also matches Sparkle's extension-less `Autoupdate` helper, which the bundle-only globs skipped, leaving it ad-hoc signed with no secure timestamp and failing notarization (statusCode 4000); it now gets the Developer ID identity and secure timestamp like every other nested binary. The same fix is mirrored in `nightly.yml`.
- **Typed NotificationCenter payload helpers.** `Core/NotificationPayloads.swift` centralizes every notification payload post/observe pair so both sides share the same keys and types, removing about 38 hand-decoded `userInfo` sites (#198).
- **HelixClient.** A shared HTTP wrapper for all Helix API calls, replacing per-service `send()` helpers. Maps 401, 429, and structured Helix errors uniformly; covered by `HelixClientTests` (#197).
- **Preferences typed accessor.** `Core/Preferences.swift` centralizes UserDefaults reads and writes for non-bool keys across AppDelegate and WolfWaveApp (#197).
- **Actor adoption.** `SongBlocklist` and `SkipVoteManager` move from `final class + NSLock` to actors; `BotCommandContext` is marked `nonisolated + Sendable`. Combine is fully removed from the app target, with the last publisher replaced by a `.task` loop (#197).
- **Sparkle release notes.** The release pipeline now turns each version's CHANGELOG section into styled HTML (`scripts/release-notes.mjs`) and embeds it in the appcast, so the in-app update dialog shows what's new with a link out to the full changelog.
- **Crash safety net.** `CrashReporter` installs an uncaught-exception handler plus `sigaction` for SIGABRT/ILL/SEGV/FPE/BUS/TRAP (async-signal-safe write path), records a breadcrumb, flushes the log, and chains the previous handler so the OS crash report and MetricKit diagnostics still fire. `guardedStart()` isolates a synchronous service-setup failure, the three `JSONSerialization.data(withJSONObject:)` sites are fronted by `isValidJSONObject`, and a blocking `swiftlint-crash-safety` CI gate runs force-unwrap/try/cast at error severity across production source (#255, #264).
- **Shared helpers, less copy-paste.** Extracted `StringFormatting.truncatedWithEllipsis` (chat-reply truncation), a generic `Atomic<Value>` box in `ThreadSafeStorage.swift` that replaces the hand-rolled `AtomicBool` and Discord state-snapshot locks, `FeatureFlags.songRequestHoldEnabled`, and a Discord button-key resolver, so the duplicated logic lives in one tested place.

### Fixed

- **Twitch bot no longer goes silent after a relaunch.** It now reconnects to your saved channel on its own, so chat commands work without reopening Twitch settings. The reconnect is silent.
- **One recovery card for denied Music access.** No more stacking the same "Music access denied" warning three times. A single card owns the explanation and the Open System Settings button. "Try again" shows a spinner instead of feeling like a dead button.
- **Now-playing survives Apple Music quirks.** The player-state reader accepts every value Music returns, instead of blanking the now-playing card, Discord presence, and overlay while music is playing.
- **Apple Music control under the sandbox.** The "WolfWave wants to control Music" prompt now appears and WolfWave can actually drive Music.
- **Two-PC stream widget works.** Open your overlay from a second computer or your phone on the same network. The Network Address URL in Settings → Stream Widgets now works (and is gated by the access token).
- **Twitch settings card stops jumping** between the signed-out, authorizing, and error states.
- **Onboarding is steadier.** Steps are centered again, the header no longer drifts between steps, and the Preferences step stops overlapping the nav bar on short windows.
- **Recheck and the Sync toggle** force a fresh now-playing read, so the UI catches up right after you grant permission.
- **Apple Music Recheck button** visibly responds when tapped, instead of looking broken.
- **Stats card layout** no longer jumps around and is gated on Apple Music access.
- **Export Logs no longer crashes** on empty or very large logs.
- **About window Check for Updates** now actually runs Sparkle, and Release Notes points at this changelog.
- **Intel Homebrew detection.** Intel Macs installed via Homebrew now disable Sparkle and show the Homebrew update card.
- **Keychain self-heals** a duplicate item that could appear after onboarding.
- **Settings sidebar toggle** cleaned up: one toggle, no floating reveal control.
- Cleaned up build warnings, layout glitches, duplicate log lines, and small icon and window-sizing issues.

### Removed

- **`WallpaperBloomBackground`**, in favor of native macOS chrome.
- **Repeated onboarding success rows**, for a tighter wizard.

## [1.2.0] - 2026-04-04

### Added

- **Shared UI components.** Extracted reusable `ConnectionTestButton`, `SectionHeaderWithStatus`, `InfoRow`, and `ConfigRequiredBanner` for a consistent settings UI across sections.

### Changed

- **Music playback architecture.** Refactored to a pluggable source system (`PlaybackSourceManager` + `PlaybackSource` protocol), laying the groundwork for music sources beyond Apple Music.
- **AppDelegate decomposed.** Split the monolithic delegate into focused extensions (`+MenuBar`, `+Services`, `+Windows`) for maintainability.
- **Logger format.** Streamlined to local time (`HH:mm:ss.SSS`) with emoji prefixes for faster scanning in the Xcode console.
- **Widget appearance settings.** Reorganized into a compact 2-per-row layout; dropdown pickers now auto-size to content.
- **Discord and Twitch settings.** Unified section headers and connection test buttons using shared components.
- **Code quality.** Added MARK sections and DocC comments across 12+ files for better Xcode navigation; added a `Color` hex initializer and a `NotificationCenter` posting helper.

### Fixed

- Settings window not appearing on screen when opened from the menu bar in menu-bar-only mode. Window show is now deferred to the next run-loop tick after the activation policy switch.
- `@MainActor` isolation for `getCurrentSongInfo()` / `getLastSongInfo()` Twitch bot callbacks. Replaced `DispatchQueue.main.sync` with `MainActor.assumeIsolated` to satisfy Swift strict concurrency.
- 4 Xcode build warnings: actor isolation annotations in `Logger.swift` and unreachable code in `SparkleUpdaterService.swift`.
- Widget favicon broken reference path.

## [1.1.0] - 2026-03-31

### Added

- **Discord buttons.** Rich Presence now shows two clickable buttons: **Open in Apple Music** (direct track link) and **song.link** (opens on Spotify, YouTube Music, Tidal, and more). Buttons appear whenever a track link resolves, even if artwork isn't available.
- **Launch at Login.** A new toggle in Settings → App Visibility. Uses `SMAppService`, so it appears in System Settings → General → Login Items. Turning it on switches "Dock Only" mode to "Dock and Menu Bar" so the app is always reachable.
- **Custom DMG background.** The installer window now has a polished dark background with the WolfWave brand colors and a drag-to-Applications arrow.
- **Homebrew auto-update.** A GitHub Actions workflow now opens a pull request on the Homebrew tap whenever a new release is published.

### Fixed

- iTunes Search API URL encoding. Track and artist names containing `&`, `+`, or `=` no longer break artwork and link lookups (switched to `URLComponents` + `URLQueryItem`).
- Launch at Login toggle now reverts if `SMAppService` registration fails, preventing a mismatch between the UI and the actual system state.

## [1.0.2] - 2026-03-31

### Fixed

- App icon missing in CI-built releases (added a pre-built .icns fallback for Xcode 16 runners).
- Sparkle updater unable to detect new versions (build number now incremented per release).
- Sparkle initialization race condition (restored synchronous init instead of deferred async).

## [1.0.1] - 2026-03-30

### Changed

- Dropped Intel (x86_64) support. Apple Silicon only.
- Raised the minimum macOS version to 26.0 (Tahoe).
- Logger: replaced NSLock with a serial DispatchQueue for thread-safe file I/O.
- TwitchChatService/DiscordRPCService: documented thread safety patterns.
- KeychainService: added error logging for all Keychain operations.
- AppConstants: cached GitHub repo resolution (no longer recomputes on every access).
- Migrated TwitchViewModel and OnboardingViewModel to the @Observable macro.
- WhatsNewView: dynamic version string, native button style, v1.0.1 feature highlights.
- Narrowed the entitlements file exception path.
- Added Twitch user ID redaction to log output.
- NotificationCenter observers now properly cleaned up on app termination.
- Windows (Settings, Onboarding, What's New) properly released on close.
- Deferred Sparkle/onboarding init past the initial layout to fix a layoutSubtreeIfNeeded warning.
- Removed the duplicate "up to date" alert (Sparkle handles it natively).
- Added VoiceOver accessibility labels across all settings and onboarding views.

## [1.0.0] - 2026-03-30

### Added

- Native macOS menu bar app for Apple Music integration.
- Real-time now-playing detection via ScriptingBridge and distributed notifications, with 2-second fallback polling.
- Twitch chat bot with `!song`, `!currentsong`, `!nowplaying`, `!lastsong`, `!last`, `!prevsong` commands.
- Discord Rich Presence showing "Listening to Apple Music" with dynamic album art.
- OBS stream widget via a built-in WebSocket server (browser source overlay).
- Automatic updates via Sparkle for DMG installs; Homebrew Cask installs update separately via `brew upgrade --cask wolfwave`.
- First-launch onboarding wizard (Welcome, Twitch, Discord, OBS Widget).
- macOS Keychain credential storage (no plain-text tokens).
- Twitch OAuth Device Code authentication flow.
- Bot command cooldowns (global + per-user, default 15s) and broadcaster bypass.
- Channel validation with the Twitch Helix API.
- Settings UI with a NavigationSplitView sidebar (Music Monitor, App Visibility, Twitch, Discord, OBS Widget, Advanced).
- Unified Music Monitoring panel with integration status indicators.
- App visibility modes: menu bar only, dock only, or both.
- Diagnostic log export.
- Full reset / danger zone in Advanced settings.
- CI pipeline with Developer ID certificate import, code signing, notarization via `notarytool`, stapling, and keychain cleanup.

### Changed

- **Channel validation.** Moved Twitch channel name validation from keystroke-triggered to connect-button-triggered. No more API calls while typing; validation happens when you click Connect.
- **Bot command toggles.** Fixed a bug where disabling a command toggle didn't persist across restarts. Commands now read their enabled state from UserDefaults at initialization.
- **Command aliases in settings.** Bot command toggle rows now show all trigger aliases (e.g., `!song · !currentsong · !nowplaying`).
- **Onboarding Welcome step.** Updated to list all features (Music Sync, Twitch Chat Bot, Discord Rich Presence, Stream Overlays, Menu Bar) with brand-colored icons.
- **Onboarding window.** Now centers on screen before showing to prevent a flash at the origin.
- **Menu bar simplified.** Removed the now-playing display from the tray menu. The menu now holds only Settings, About, and Quit.
- **macOS system colors.** The UI uses system accent and semantic colors for automatic light/dark support.
- **Discord auto-reconnect.** Exponential backoff reconnection (5s base, doubling to a 60s cap) with availability polling when Discord isn't running.
- **Twitch reconnection.** Network path monitoring with automatic reconnection on connectivity changes, capped at 5 retry cycles with a 60s cooldown.
- **Documentation.** Updated all docs for current features and added a Legal section with the Privacy Policy and Terms of Service.
- **UX wording.** Unified feature naming (Music Sync, Now-Playing Widget), standardized empty states, and shortened descriptions for clarity.
- **Typography hierarchy.** Established an H1/H2/H3 heading system across all settings views.
- **Thread safety.** Fixed MainActor.assumeIsolated crash risks and added lock coverage for Twitch service properties.
- **Sparkle updates.** Completely disabled in DEBUG builds; fixed appcast Ed25519 signing.
- **Dev bundle.** Separate .dev bundle ID for side-by-side development testing.

### Removed

- Now-playing track display from the menu bar dropdown (moved to the Music Monitor settings preview).
