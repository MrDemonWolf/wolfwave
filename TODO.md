# TODO

Open follow-ups for the Stream Deck plugin (WW-45) and build hygiene. Shipped items were removed; only work that is still open is listed, with its reasoning.

---

## Stream Deck plugin

The plugin builds, typechecks, and passes its tests, but **has never run on a real device**. Verification and submission need hardware or an Elgato account, not CI.

### 1. Verify on a physical Stream Deck (or the Elgato simulator)

Every one of these is currently an assumption:

- Keys render and update from live state.
- Key presses produce the right command and the ok/alert flash.
- The `Offline` / `Token?` / `Update` states appear when they should.
- Two keys bound to the same action correlate acks in press order (the FIFO scheme has no correlation id, so this is the case most likely to be wrong).
- The Property Inspector saves global settings and the plugin picks them up.

### 2. Submit to the Elgato Marketplace

Packaging is done: `bun run --filter streamdeck pack` emits
`apps/streamdeck/dist/com.mrdemonwolf.wolfwave.streamDeckPlugin` (gitignored), and
CI runs it as a shippability check because packing validates the manifest and
every asset it points at.

What is left is the submission itself, which needs an Elgato Maker account. Do it
after item 1. Once it lands, drop the "not on the Marketplace yet" callout in
`apps/docs/content/docs/streamdeck.mdx` and close item 4.

### 3. Deferred v1 action: now-playing dial

Named in WW-45, out of scope for the first pass: a dial (encoder) with album art
and rotation-bound volume. It wants app-side seams that don't exist yet. Revisit
once the basic key set is confirmed working on hardware.

### 4. `sdPlugin` install is manual

`apps/docs/content/docs/streamdeck.mdx` documents copying the folder into `~/Library/Application Support/com.elgato.StreamDeck/Plugins/` by hand. That's fine pre-Marketplace, but revisit the page's install section once item 2 lands.

---

## Build hygiene

### 5. `widget#build` turbo warning

`turbo build` emits `no output files found for task widget#build`. Worth chasing separately so real drift isn't masked by an expected warning.
