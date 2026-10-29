# End-to-end testing

WolfWave has three test boundaries. This page says what each one covers, how to
run it, and what is left over for a human. The goal is that the leftover list
only ever contains things a machine genuinely cannot do.

| Boundary | Where | Run it |
|---|---|---|
| Unit / service | `apps/native/WolfWaveTests/` | `make test` |
| Integration (real transports, loopback) | `apps/native/WolfWaveTests/` | `make test` |
| End-to-end (real app, real windows) | `apps/native/WolfWaveUITests/` | `make test-ui` |

`make test-ci` is the CI entry point and is **unit + integration only**. UI tests
run in their own `ui-test` CI job on their own scheme, so a slow or flaky UI run
never gates a release.

## The UI tests

`make test-ui` builds `WolfWave Dev.app`, launches it, and drives it the way a
person would. It needs no Twitch account, no Apple Music, no network, and it
keeps account and Apple Music permission prompts out of the app. Local builds
prefer Apple Development signing, then an installed Developer ID Application
identity. Without either, macOS may block the ad hoc test build from launching.

### macOS UI-testing permission

Apple's [UI automation guide](https://developer.apple.com/documentation/XCUIAutomation/recording-ui-automation-for-testing)
requires permission for **Xcode Helper** to control the Mac. In System Settings,
open Privacy & Security, then Accessibility. This development Mac labels that
pane **Device Control and Data Access**. Use the entry matching the installed
Xcode; its helper lives at:

```text
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/Xcode Helper.app
```

If Xcode is installed elsewhere, use that installation's equivalent path.
Adding or enabling it grants broad device-control access and may require the
Mac's owner to unlock System Settings. Handle that approval manually.

`Timed out while enabling automation mode` before any test case starts is a
runner setup failure. An absent Xcode Helper entry alone does not establish its
cause. Try one focused test in a fresh session before changing app code or
permissions. If macOS requests helper access, handle that approval explicitly.
A successful build does not prove that UI tests executed.

That is possible because of one seam: `Core/UITestMode.swift`. The UI test bundle
sets `WOLFWAVE_UI_TEST=1` on the app's launch environment, and the app responds by

- routing `DefaultsStore.store` and `KeychainService.backend` to throwaway
  storage, wiped at launch, so a test toggling a real setting cannot reach the
  developer's live `com.mrdemonwolf.wolfwave.dev` domain or real credentials;
- leaving `AppleMusicSource`, `TwitchChatService`, `DiscordRPCService`, and
  Sparkle down, because those need Apple Events (a TCC dialog parked over the
  runner), an account, a live IPC socket, and the network respectively.

Additional environment flags shape the starting state, declared in
`UITestMode` and mirrored in `UITestEnvironment` in the test bundle:

| Flag | Effect |
|---|---|
| `WOLFWAVE_UI_TEST_ONBOARDED=1` | Start past the wizard. |
| `WOLFWAVE_UI_TEST_NO_WHATS_NEW=1` | Suppress the What's New window. |
| `WOLFWAVE_UI_TEST_SONG_REQUESTS_ENABLED=1` | Show configured Song Requests without external accounts. |
| `WOLFWAVE_UI_TEST_SETTINGS_SIZE=minimum` or `ideal` | Use the design system's corresponding window dimensions. |
| `WOLFWAVE_UI_TEST_APPEARANCE=light` or `dark` | Seed the isolated appearance preference before the first frame. |

Subclasses of `WolfWaveUITestCase` declare what they want through
`launchOptions` and get a launched, activated `app`.

> `app.activate()` in `setUp` is load-bearing. An inactive macOS app reports its
> entire window tree as disabled, so every element is still *findable* but
> nothing is `isHittable`, and clicks silently do nothing.

### What the UI suite covers today

- **Onboarding**: the window opens on a true first launch; walking Next through
  every step reaches Finish and closes the wizard; Back (and Escape) returns a step; the progress header names the step; Skip setup
  dismisses it.
- **Settings**: the native App menu opens the window, and every sidebar pane renders. That
  second one exists because of a real shipped bug: a persisted value outside a
  picker's tag set trapped inside SwiftUI's layout and took the whole settings
  window down. No unit test can see that, because the crash is in SwiftUI, not
  in our code. Rendering each pane for real is the assertion. A second pass over
  the panes catches teardown that only misbehaves on a revisit.
- **Window lifecycle and navigation**: close and reopen Settings three times
  with Cmd+comma, restore a minimized window, keep one Settings instance, follow
  the selected pane in the toolbar title, and navigate the stock sidebar with
  Down/Up Arrow.
- **Pane screenshots**: `testCapturesEveryPane` captures every pane at minimum
  and ideal width, in Light and Dark (40 images). It checks the window width,
  minimum sidebar width, and horizontal pane containment. The images still need visual review for internal
  alignment, wrapping, and density. Pull them out with:

  ```bash
  make test-ui
  xcrun xcresulttool export attachments \
    --path DerivedData/Tests/Logs/Test/<newest>.xcresult \
    --output-path /tmp/panes
  ```

  Files are named by UUID; the `manifest.json` beside them maps each back to
  its pane. In CI the same attachments ride along in the uploaded `.xcresult`.

- **Request playlist safety**: Clear Requests opens a confirmation, and Cancel
  leaves the queue controls available. Actual Music playlist mutation remains a
  manual account check; unit tests cover active, idle, and cleanup-failure paths.

- **Layout regressions**: History & Stats retains its privacy introduction, the selected pane title appears in the native toolbar, and the request queue appears above request configuration.
- **Compact queue controls**: the 640-point window keeps Hold and Clear Requests
  reachable, and Hold changes to Resume even before any songs arrive. A fixed offline fixture also checks the held queue count and pending approval actions at 640 points. Real Apple Music playback remains a separate release check.

### Adding a UI test

1. Subclass `WolfWaveUITestCase` and override `launchOptions` if you need to
   start somewhere other than a first run.
2. Query by **accessibility identifier**, never by visible label. Several panes
   repeat their own section's name in the body, so a label query matches both
   the sidebar row and the content.
3. If the element you need has no identifier, add one in the app in the same
   change. Sidebar rows use `settings.sidebar.<section title>`; the wizard uses
   `onboarding.<button>`.
4. Check the element type against the real tree before asserting on it. SwiftUI
   maps a sidebar row's `Label` to a **`staticText`**, not a button. When a query
   comes back empty, print `app.windows["…"].debugDescription` to see what
   actually shipped.

## Still manual

Everything below needs hardware, a real account, or a live third-party service.
These are the release checks a person still runs.

| Check | Why it cannot be automated |
|---|---|
| Apple Music playback drives now-playing | Needs the TCC Automation grant and a real Music.app with a real library. The grant is a system dialog outside the app. |
| Twitch connect, chat commands, EventSub | Needs a real Twitch account and OAuth device-code flow against live Helix. |
| Channel points and Bits redemptions | Needs an affiliate/partner channel and real viewers spending. |
| Discord Rich Presence shows the track | Needs the Discord desktop app running and its IPC socket. |
| Sparkle update install | Needs a signed, notarized build and a published appcast; the updater relaunches the app. |
| Notification banners | Needs the system notification authorization grant. |
| Stream Deck plugin on real hardware | Needs the physical device and Elgato's software. The control protocol itself is covered end to end by `StreamDeckControlIntegrationTests` over a real loopback socket, so what is left is the device and Elgato's runtime. |
| OBS widget inside OBS | The widget's HTTP and WebSocket layers are covered by integration tests; OBS's own browser source is not. |

Some of these could be partly automated later with a stubbed Helix or a fake
Discord socket, at the cost of the stub being the thing under test rather than
the integration. That trade has not been worth it so far.
