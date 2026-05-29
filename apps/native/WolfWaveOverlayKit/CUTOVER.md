# Overlay Server XPC Cutover

Phase 2 of [process-separation-research.md](../docs/process-separation-research.md).
Moves the WebSocket overlay + Widget HTTP server out of the app process into a
`WolfWaveOverlayServer.xpc` service, via the `WolfWaveOverlayKit` package.

**What's already done (verified):**
- `WolfWaveOverlayKit` package: server logic, XPC protocols, models, pure token
  rules. `swift build` + `swift test` green (20 tests).
- Staged, not yet in the Xcode project:
  - `apps/native/WolfWaveOverlayServer/` — `main.swift`, `Info.plist`, `WolfWaveOverlayServer.entitlements` (the `.xpc` target's files).
  - `apps/native/_cutover-staging/WebSocketServerService.swift` — the in-app facade.

**Why the Xcode steps are manual:** the project is `objectVersion 77` with
`PBXFileSystemSynchronizedRootGroup`. Adding a target + a local package ref +
membership exceptions by hand corrupts that format; Xcode's editor does it
safely. Each step below is a GUI action.

---

## Steps (in Xcode)

### 1. Add the local package
File ▸ Add Package Dependencies… ▸ **Add Local…** ▸ select
`apps/native/WolfWaveOverlayKit`. Add the `WolfWaveOverlayKit` library product to
the **WolfWave** app target (General ▸ Frameworks, Libraries, and Embedded Content).

### 2. Create the XPC Service target
File ▸ New ▸ Target ▸ macOS ▸ **XPC Service**.
- Product Name: `WolfWaveOverlayServer`
- Team: `HBB7T99U79`, deployment target macOS 26.
- After creation, **delete the auto-generated** `main.swift` / protocol / Info.plist
  in the new group, and add the staged files from `apps/native/WolfWaveOverlayServer/`
  (`main.swift`, `Info.plist`, `WolfWaveOverlayServer.entitlements`) to the target.
- Build Settings:
  - `PRODUCT_BUNDLE_IDENTIFIER = com.mrdemonwolf.wolfwave.overlayserver`
    (MUST match `OverlayConstants.xpcServiceName`, the Info.plist `CFBundleIdentifier`,
    and the facade's `NSXPCConnection(serviceName:)`).
  - `INFOPLIST_FILE` → the staged `Info.plist`.
  - `CODE_SIGN_ENTITLEMENTS` → `WolfWaveOverlayServer.entitlements`.
  - `ENABLE_HARDENED_RUNTIME = YES`.
- Add the `WolfWaveOverlayKit` product to this target's Frameworks too.

### 3. Embed the service in the app
Xcode usually adds an **Embed XPC Services** copy-files phase to the host app
automatically. Verify: WolfWave app target ▸ Build Phases ▸ a Copy Files phase
with Destination = **XPC Services** containing `WolfWaveOverlayServer.xpc`. Add it
if missing.

### 4. Bundle the widget assets into the .xpc
Select `apps/native/WolfWave/Resources/widget.html` and
`widget-tokens.generated.js` ▸ File inspector ▸ Target Membership ▸ check
**WolfWaveOverlayServer** (in addition to the app). They must land in the `.xpc`'s
Copy Bundle Resources — `OverlayWidgetHTTPServer` reads them from its own
`Bundle.main`. (Optional: add a `favicon.png` to the xpc for the browser-tab icon;
otherwise `/favicon.*` returns 404.)

### 5. Swap the app's server for the facade
- **Remove from the app target** (logic now lives in the package):
  `apps/native/WolfWave/Services/WebSocket/WebSocketServerService.swift` and
  `WidgetHTTPService.swift`.
- **Add** the facade: move
  `apps/native/_cutover-staging/WebSocketServerService.swift` into
  `apps/native/WolfWave/Services/WebSocket/` (synced root → auto-joins the app target).
- Keep `WebSocketAuthToken.swift` (it mints/persists the token via Keychain — still
  used by `setupWebSocketServer`). Its pure helpers are now superseded by the
  package's `WebSocketTokenRules`; trimming them is optional cleanup.
- `import WolfWaveOverlayKit` is already in the facade. No AppDelegate call sites
  change — the facade keeps the same method names, `state`, `connectedClientCount`,
  and `stateChanges`.

### 6. Fix the app test target
Delete these app tests — their coverage moved to `WolfWaveOverlayKitTests`
(`swift test`):
`WebSocketServerServiceTests.swift`, `WebSocketServerAuthTests.swift`,
`WidgetHTTPServiceTests.swift`, `WebSocketServerIntegrationTests.swift`.
(Optional: add a facade test that mocks the `OverlayServerXPC` proxy and asserts
`updateNowPlaying` JSON-encodes correctly.)

---

## CI / signing
No further CI change needed. Phase 1 already converted release signing to
inside-out with `--preserve-metadata=entitlements`
([build_release.yml](../../../.github/workflows/build_release.yml)), which keeps
the `.xpc`'s `network.server` grant from xcodebuild's signature. Do NOT reintroduce
`codesign --deep --force`.

## Accepted regressions (document in PR)
- Server logs move to Console subsystem `com.mrdemonwolf.wolfwave.overlayserver`
  (not the in-app Debug "Logs & Events" tab).
- Favicon served only if a `favicon.png` is bundled in the `.xpc` (else 404);
  the old code rendered `AppIcon` via `NSImage`/AppKit (dropped to keep the
  package AppKit-free).
- Per-message byte metric dropped. Client-count metric is preserved (facade
  records it on each state change).
- Total memory rises modestly (second process). This is the expected tradeoff —
  the win is crash isolation + a `network.server`-only sandbox.

## Verification (on your machine)
1. `make test` (app) and `swift test` (package) both green.
2. Run app, enable overlay + Widget HTTP. Activity Monitor shows
   `WolfWaveOverlayServer.xpc` as a separate process.
3. Load the OBS widget URL: now-playing card + the user's theme render (proves
   appearance crossed XPC and loopback token injection still works).
4. Try a WebSocket connect with a wrong/missing `wolfwave.token.<hex>`
   subprotocol → rejected.
5. Kill `WolfWaveOverlayServer.xpc` in Activity Monitor while streaming → the
   overlay recovers within a few seconds (facade `interruptionHandler` re-configures
   and replays the last track).
6. Toggle overlay off → the `.xpc` exits (idle) and the port closes.
7. `make prod-build && make notarize && make verify-notarize`; `spctl --assess`
   the app; launch the notarized build and confirm the overlay works (proves the
   `network.server` entitlement survived inside-out signing).
