# AGENTS.md: Stream Deck plugin (`apps/streamdeck/`)

> Paths in backticks are relative to the repo root unless they are links. Shared rules (CI, docs sync, versioning, release) are in the root [`AGENTS.md`](../../AGENTS.md).

**Stream Deck plugin**: `apps/streamdeck/` is the Elgato plugin consuming the
app's control API. Unlike the widget, its bundle is **not** committed and is
**not** shipped inside the app; it's distributed through Elgato. `src/wolfwave/`
is the TypeScript mirror of `Services/WebSocket/StreamDeckCommand.swift`: the
action tokens are the Swift enum's raw values and `PROTOCOL_VERSION` must equal
`StreamDeckControl.protocolVersion`. **Change one side, change the other**, and
bump the protocol version on any breaking envelope change. Protocol v3 uses a
dedicated `wolfwave.control.<hex>` credential and fixed loopback transport; the
OBS widget uses a separate read-only `wolfwave.overlay.<hex>` credential that
can never authorize commands. The plugin bundle
lives at `apps/streamdeck/com.mrdemonwolf.wolfwave.sdPlugin/` (`manifest.json`
plus the `ui/` Property Inspector); `manifest.json` is a `streamdeck#build` turbo
input and both it and the Property Inspector have their own tests. The panel can
only check a token's shape; whether WolfWave accepted it reaches the panel through
`src/connection-status.ts` (pure, so it is testable apart from `plugin.ts`, which
connects at import time). The `streamdeck`
CI job runs `typecheck`, `bun test`, `pack`, and an icon-drift check on any change
under `apps/streamdeck/`, so a protocol mismatch fails the PR. Icons are generated
from the brand mark by `scripts/generate-icons.ts`; regenerate rather than hand-editing
them, or the drift check fails. See `apps/native/docs/streamdeck-control-api.md`
and `apps/streamdeck/README.md`.
