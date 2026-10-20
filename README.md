![WolfWave](assets/logo-128.png)

# WolfWave - Apple Music, Live on Your Stream

WolfWave is a free, native macOS menu bar app for streamers who use
Apple Music. Play a song and your Twitch chat, Discord profile, and
OBS overlay all update on their own. Your chat can request songs, and
you stay in charge of what plays.

Your music plays. Everything else keeps up.

[![GitHub license](https://img.shields.io/github/license/mrdemonwolf/wolfwave.svg?style=for-the-badge&logo=github)](https://github.com/MrDemonWolf/WolfWave/blob/main/LICENSE)

## Table of Contents

- [Quick Start](#quick-start)
- [Features](#features)
  - [For Streamers](#for-streamers)
  - [For Your Chat](#for-your-chat)
  - [For Developers](#for-developers)
- [Usage](#usage)
- [Docs](#docs)
- [Tech Stack](#tech-stack)
- [Development](#development)
- [Project Structure](#project-structure)
- [License](#license)
- [Contact](#contact)

## Quick Start

**You need:** a Mac with Apple Silicon (M1 or later), macOS 26
(Tahoe) or newer, and the Music app.

**Option 1: DMG (recommended)**

1. Download the latest `.dmg` from
   [GitHub Releases](https://github.com/MrDemonWolf/WolfWave/releases).
2. Open it and drag **WolfWave** to **Applications**.
3. Launch WolfWave and follow the setup wizard.

**Option 2: Homebrew**

```bash
brew tap mrdemonwolf/den
brew install --cask wolfwave
```

WolfWave is signed and notarized by Apple, so macOS opens it without
Gatekeeper warnings. DMG installs update themselves. Homebrew installs
update with `brew upgrade --cask`.

## Features

### For Streamers

**Twitch song requests**

- **Requests from chat.** Viewers type `!sr` with a song name or an
  Apple Music, Spotify, or YouTube link. Songs play through Apple Music
  without stealing focus from OBS.
- **Channel points and Bits.** WolfWave can add a "Request a Song"
  channel-point reward. A Bits cheer can request a song, or bump the
  viewer's queued song to the front. Failed channel-point requests are
  refunded.
- **Require My Approval.** Opt-in. Every request waits in the queue
  until you approve or decline it.
- **Hold the queue.** Requests still come in, but nothing plays until
  you resume.
- **Fair-share order.** Everyone's first request plays before anyone's
  second. On by default.
- **Sub / VIP priority.** Optional. Subs and VIPs skip the cooldown or
  jump ahead within a round. Off by default.
- **Blocklist.** Block a song, a whole artist, or a person.
- **Vote-to-skip.** Chat votes with `!voteskip`, as a chat tally or a
  native Twitch Poll.
- **Fallback playlist.** Pick an Apple Music playlist to play when the
  queue runs dry.
- **Live queue view.** See what's playing, what's next, and who asked
  for it, right in the app.

**Chat commands**

- **Built-in commands.** `!song`, `!last`, `!queue`, `!stats`, and
  more. Turn each one on or off and add your own aliases.
- **Custom commands.** Make your own, with variables (`$user`,
  `$touser`, `$args`, `$1`-`$9`, `$song`, `$lastsong`), a cooldown, and
  a permission level. Each one replies to the chatter, posts a plain
  message, or sends a Twitch announcement.

**Discord**

- **Rich Presence.** Shows "Listening to WolfWave" on your Discord
  profile with Apple Music album art and buttons to open the song.

**Stream overlay**

- **OBS browser source.** A now-playing card with five themes
  (`Default`, `Dark`, `Light`, `Glass`, `Neon`) and five layouts
  (`Horizontal`, `Vertical`, `Compact`, `Vinyl`, `Classic`).
- **Queue ticker.** Opt-in `?queueTicker=1` panel showing the next 3
  requests and who asked for them.
- **Two-PC setups.** An OBS PC on the same network can show the
  overlay with a read-only token.
- **Light on OBS.** Progress updates are batched, rendering sleeps
  while hidden, and Reduce Motion turns off continuous animation.
- **Smoother updates.** Repeated snapshots preserve artwork and Vinyl
  rotation. Preset text contrast is checked against light and dark scenes;
  custom colors still need checking against your scene.

**Stream Deck (optional)**

- **Twelve keys.** Play / Pause, Skip, Hold Queue, Approve Next,
  Reject Request, Clear Queue, Block Song, Block Requester, Request
  Access, Announce Song, Overlay, and Now Playing.
- **Manual install for now.** The plugin is built from
  `apps/streamdeck/` until it's on the Elgato Marketplace. See the
  [Stream Deck guide](https://mrdemonwolf.github.io/wolfwave/docs/streamdeck).

**History & Stats**

- **Listening history.** Opt-in and on your Mac only. Top artists,
  listening time, a 7-day trend, and listening by hour.
- **Monthly Wrap.** A "wrapped"-style summary for any month, saved as
  a shareable image.

**Everyday comfort**

- **Streamer Mode.** One click masks your channel name, overlay links,
  and tokens so Settings is safe to show on camera.
- **Song-change banners.** Opt-in Mac notifications for song changes
  and vote-skips. A new banner replaces the last one of its kind.
- **Backup & restore.** Export your settings to a file in Settings >
  Advanced and import them on another Mac. Logins and tokens stay in
  each Mac's Keychain, so you sign in to Twitch once per Mac.
- **Sync with iCloud.** Opt-in, off by default. Mirrors that same
  export between your Macs. It needs a build signed with iCloud
  access; if your settings don't sync, Export and Import always work.
- **Menu bar, Dock, or both.** Plus launch at login and Light, Dark,
  or System appearance.
- **Updates your way.** Stable by default, or opt into
  [Nightly builds](https://mrdemonwolf.github.io/wolfwave/docs/nightly)
  in Settings > Software Update.
- **Helpful errors.** Error messages name the cause and offer the fix.
  Export Logs and a pre-filled bug report live in Settings > Advanced.

### For Your Chat

Viewers on a stream running WolfWave can type the commands in
[Usage](#usage). In short:

- **Request a song** with `!sr <song name or link>`.
- **See the song** with `!song`, or the one before with `!last`.
- **See the line** with `!queue`, or just your own with `!myqueue`.
- **Vote to skip** with `!voteskip` or `!vs`.
- **Spend channel points or Bits** to request, if the streamer turned
  them on.

### For Developers

- **Local WebSocket feed.** Every play, pause, and skip as JSON on
  `ws://localhost:8765`, authenticated with a read-only overlay token.
  See the [Widget docs](https://mrdemonwolf.github.io/wolfwave/docs/widget).
- **Stream Deck control API.** A separate control token runs commands,
  and only from the same Mac. Documented in
  [Stream Deck Control API](apps/native/docs/streamdeck-control-api.md).
- **Settings deep links.** `wolfwave://settings/<pane>/<section>` opens
  Settings at a card. The names are listed in the
  [Settings docs](https://mrdemonwolf.github.io/wolfwave/docs/settings#deep-links).
- **Native and open source.** Swift 6, SwiftUI, sandboxed. GPL-3.0.

## Usage

### Viewer Commands

| Command                                | What it does                                |
| -------------------------------------- | ------------------------------------------- |
| `!sr <song>` `!request` `!songrequest` | Requests a song (name or link)              |
| `!song` `!currentsong` `!nowplaying`   | Shows the current song                      |
| `!last` `!lastsong` `!prevsong`        | Shows the previous song                     |
| `!queue` `!songlist` `!requests`       | Shows the request queue                     |
| `!myqueue` `!mysongs`                  | Shows only your own requests                |
| `!voteskip` `!vs`                      | Votes to skip the current song              |
| `!playlist`                            | Links the streamer's request playlist       |
| `!stats` `!musicstats`                 | Shows today's listening stats (live only)   |
| `!wolfwave`                            | Tells chat what WolfWave is (off by default) |

The streamer turns each command on or off and can add aliases in
**Settings > Twitch** and **Settings > Song Requests**.

### Mod and Broadcaster Commands

| Command                     | What it does                          |
| --------------------------- | ------------------------------------- |
| `!skip` `!next`             | Skips the current request             |
| `!hold` `!resume` `!unhold` | Holds or resumes the request queue    |
| `!clearqueue` `!cq`         | Clears every request                  |

### First-Time Setup

1. **Allow Music access.** The setup wizard asks macOS to let
   WolfWave read the Music app.
2. **Connect Twitch.** Settings > Twitch. Sign in with the code
   WolfWave shows you.
3. **Turn on requests.** Settings > Song Requests > Enable Song
   Requests. Add **Require My Approval** if you want to screen them.
4. **Turn on Discord.** Settings > Discord.
5. **Add the overlay.** Settings > Stream Widgets. Turn it on, then
   add the browser source link to OBS.

### Overlay Sizes

| Layout     | Recommended OBS canvas |
| ---------- | ---------------------: |
| Horizontal |              532 x 132 |
| Vertical   |              252 x 312 |
| Compact    |               382 x 88 |
| Vinyl      |              292 x 332 |
| Classic    |              472 x 144 |

Sizes include the widget's transparent padding. On the same Mac, use
the localhost link. For a second computer, use the LAN link on a
trusted network only.

## Docs

Full docs live at
[mrdemonwolf.github.io/wolfwave](https://mrdemonwolf.github.io/wolfwave).

Read released updates on the public [Changelog](https://mrdemonwolf.github.io/wolfwave/changelog/),
or explore the [Design system](https://mrdemonwolf.github.io/wolfwave/design-system/)
for typography, measured color pairs, components, and motion. Unreleased notes
stay in the repository and are excluded from the website's changelog and search.

- [Installation](https://mrdemonwolf.github.io/wolfwave/docs/installation)
- [Features](https://mrdemonwolf.github.io/wolfwave/docs/features)
- [Bot Commands](https://mrdemonwolf.github.io/wolfwave/docs/bot-commands)
- [Settings](https://mrdemonwolf.github.io/wolfwave/docs/settings)
- [Troubleshooting](https://mrdemonwolf.github.io/wolfwave/docs/troubleshooting)
- [FAQ](https://mrdemonwolf.github.io/wolfwave/docs/faq)
- [Architecture](https://mrdemonwolf.github.io/wolfwave/docs/architecture)
- [Development](https://mrdemonwolf.github.io/wolfwave/docs/development)

## Tech Stack

| Layer       | Technology                                                    |
| ----------- | ------------------------------------------------------------- |
| Language    | Swift 6.0                                                     |
| UI          | SwiftUI, AppKit                                               |
| Platform    | macOS 26.0+ (Tahoe), Apple Silicon, Apple Music app required  |
| Music       | ScriptingBridge, MusicKit, AppleScript                        |
| Twitch      | EventSub WebSocket, Helix API                                 |
| Discord     | Rich Presence via local IPC Unix domain socket                |
| Networking  | URLSession, Network framework, NWListener (WebSocket overlay)  |
| Updates     | Sparkle (EdDSA-signed appcast)                                |
| Charts      | SwiftUI Charts (History & Stats)                              |
| Diagnostics | MetricKit (opt-in)                                            |
| Tests       | XCTest, Swift Testing, XCUITest                               |
| Security    | macOS Keychain (Security framework)                           |
| Docs        | Fumadocs (Next.js), bun, Turborepo                            |
| Marketing   | Remotion                                                      |

## Development

The short version is below. The full guide is in the
[Development docs](https://mrdemonwolf.github.io/wolfwave/docs/development)
and [CONTRIBUTING.md](CONTRIBUTING.md).

### Prerequisites

- macOS 26.0+ (Tahoe) on Apple Silicon
- Xcode 26+ and Swift 6.0
- [bun](https://bun.sh) (the version pinned in `package.json`) for the
  docs, widget, and Stream Deck workspaces
- Command Line Tools: `xcode-select --install`

### Setup

1. Clone the repo:

```bash
git clone https://github.com/MrDemonWolf/WolfWave.git
cd WolfWave
```

2. Copy the config template:

```bash
cp apps/native/WolfWave/Config.xcconfig.example apps/native/WolfWave/Config.xcconfig
```

3. Add your Twitch Client ID
   ([dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps))
   and Discord Application ID
   ([discord.com/developers/applications](https://discord.com/developers/applications))
   to `Config.xcconfig`.

4. Open the project and press `Cmd+R`:

```bash
make open-xcode
```

### Development Scripts

Native app:

- `make build` runs a debug build.
- `make test` runs the unit tests.
- `make test-ui` runs the XCUITest suite against the real app.
- `make clean-dev` resets WolfWave Dev to a fresh first run. It never
  touches the production app.
- `make check-drift` regenerates the widget, tokens, sponsor config,
  and Debug icon, and fails on drift (the same gate as CI).
- `make prod-build` builds a release DMG in `builds/`.

Monorepo (bun + Turborepo):

- `bun install` installs every workspace.
- `bun run build` builds every workspace in order.
- `bun run dev --filter docs` starts the docs site.
- `bun run --filter widget test` runs the OBS widget tests.
- `bun run --filter streamdeck test` runs the Stream Deck plugin tests.
- `bun run tokens` regenerates the design tokens.

The full list of `make` and `bun` targets is in `Makefile`,
`package.json`, and [CLAUDE.md](CLAUDE.md).

### Code Quality

- SwiftLint, plus blocking crash-safety (no force unwrap, `try!`, or
  `as!`), file-header, and docs-sync checks: `make lint`,
  `make lint-crash-safety`, `make lint-headers`, `make lint-sync`.
- Design-system lint: `bun run ds:lint`.
- Swift 6 async/await, MVVM with `@Observable` view models.
- Credentials always go through the Keychain, never `UserDefaults`.

## Project Structure

```text
wolfwave/
├── apps/
│   ├── native/                 # Native macOS app (Swift, SwiftUI, AppKit)
│   │   ├── WolfWave/           # App source
│   │   ├── WolfWaveTests/      # Unit tests
│   │   ├── WolfWaveUITests/    # XCUITest suite (drives the real app)
│   │   ├── docs/               # Internal design and protocol docs
│   │   └── WolfWave.xcodeproj  # Xcode project
│   ├── docs/                   # Fumadocs documentation site
│   ├── marketing/              # Remotion-based promo videos
│   ├── streamdeck/             # Elgato Stream Deck plugin (TypeScript)
│   └── widget/                 # OBS overlay widget source (builds Resources/widget.html)
├── assets/                     # Brand assets, logos
├── design-system/              # Design tokens + component catalog
├── docs/                       # Repo-level engineering standards
├── scripts/                    # Release, versioning, and lint helper scripts
├── CHANGELOG.md                # Release history
├── CONTRIBUTING.md             # How to build, test, and submit changes
├── Makefile                    # Build, test, lint, release targets
├── package.json                # bun workspaces root
└── turbo.json                  # Turborepo pipeline config
```

## License

[![GitHub license](https://img.shields.io/github/license/mrdemonwolf/wolfwave.svg?style=for-the-badge&logo=github)](https://github.com/MrDemonWolf/WolfWave/blob/main/LICENSE)

WolfWave is released under the GNU General Public License v3.0
(GPL-3.0).

## Contact

Questions or feedback?

- Discord: [Join my server](https://mrdwolf.net/discord)
- Issues: [GitHub Issues](https://github.com/MrDemonWolf/WolfWave/issues)
- Docs: [mrdemonwolf.github.io/wolfwave](https://mrdemonwolf.github.io/wolfwave)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
- Security: [SECURITY.md](.github/SECURITY.md)

---

Made with love by [MrDemonWolf, Inc.](https://www.mrdemonwolf.com)
