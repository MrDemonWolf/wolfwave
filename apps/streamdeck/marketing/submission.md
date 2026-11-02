# WolfWave Marketplace submission draft

Local draft only. No product has been submitted by this workflow. Requirements checked against Elgato's official documentation on October 28, 2026; recheck before uploading.

## Listing

- **Name:** WolfWave
- **Maker:** MrDemonWolf, Inc. (must match the Maker organization)
- **Price:** Free
- **Product file:** `../dist/com.mrdemonwolf.wolfwave.streamDeckPlugin`
- **Website and setup:** [Stream Deck guide](https://wolfwave.mrdemonwolf.dev/docs/streamdeck/)
- **Support:** [GitHub issues](https://github.com/MrDemonWolf/WolfWave/issues)
- **Privacy:** [Privacy policy](https://wolfwave.mrdemonwolf.dev/docs/privacy-policy/)

### Description to paste

Control Apple Music and your stream's song-request queue with WolfWave on Stream Deck. See the current song and album artwork, watch elapsed or remaining track time, and manage requests without switching away from your stream.

The free plugin provides 13 actions: Play / Pause, Next Track, Hold / Resume Queue, Approve Next, Clear Queue, Block Song, Show / Hide Overlay, Announce Song, Reject Request, Block Requester, Request Audience, Track Time, and Now Playing. Queue keys show live counts; destructive queue and requester actions require a deliberate hold. Track Time saves your elapsed or remaining choice per key.

Requires the free WolfWave companion app on an Apple Silicon Mac running macOS 26 or later, the Music app, and Stream Deck software 6.5 or later. Install matching current builds of WolfWave and the plugin. Connect once with WolfWave's local Stream Deck control token. Twitch chat actions require a connected Twitch account. Keys are supported; Stream Deck + dial controls are not included.

### Initial release notes to paste

Initial release with 13 key actions for Apple Music playback, Twitch song requests, queue management, overlay visibility, Now Playing artwork, and elapsed or remaining track time. Requires WolfWave on the same Mac.

## Build and verify

Run these from the repository root with the Bun version pinned in `package.json`:

```bash
bun run --filter streamdeck icons
bun run --filter streamdeck typecheck
bun run --filter streamdeck test
bun run --filter streamdeck pack
```

Packaging validates the manifest and referenced assets. It does not prove physical key rendering or live integrations. Follow the [plugin README](../README.md) for local installation and the [end-to-end checklist](../../native/docs/end-to-end-testing.md) for live verification.

## Media and evidence still needed

- [x] `app-icon.png`: 288 × 288 PNG, verified in this folder.
- [ ] One thumbnail: 1920 × 960 PNG.
- [ ] Three gallery items: 1920 × 960 PNG images or 1920 × 1080 MP4 video; videos must be under 250 MB.
- [ ] Functional demo video for the review team. Elgato requires this for hardware or paid-service integrations; show WolfWave's Apple Music flow and the Stream Deck keys working.
- [ ] Confirm live playback, pause, seek, reconnect, hidden-overlay timing, saved time mode, and hold confirmation on the target device. Capture screenshots with no tokens or private account information visible.
- [ ] Confirm the packaged manifest and listing accurately state companion-app, macOS, architecture, software, and device requirements.
- [ ] Verify Maker organization access and signed Maker Agreement; account state has not been checked by this draft.

Use owned or licensed media and actual product captures. Marketplace media must be English, legible, and accurate. Review the finished description against the 250–1,500 character limit before uploading.

## Submit when ready

1. Sign in to [Maker Console](https://maker.elgato.com/), create or select the MrDemonWolf, Inc. organization, and sign the Maker Agreement if needed. The agreement is an owner action.
2. Choose **Create product → Stream Deck plugin** and upload the packaged file.
3. Review the name, description, tags, free pricing, and setup/support/privacy links. Choose the name and monetization carefully: changing them later requires contacting Elgato.
4. Upload the app icon, thumbnail, and three gallery items; add release notes and the functional demo requested for review.
5. **Uncheck “Automatically publish after being approved.”** Review the concrete listing and package before sending it for review.
6. Submit for review when authorized. Elgato says to allow 4–10 working days; feedback arrives by email. An approved product can then be released manually. Every new version is reviewed too.

## Official references

- [Become a Maker](https://docs.elgato.com/marketplace/become-a-maker/): organization and Maker Agreement.
- [Submitting products](https://docs.elgato.com/maker-console/submitting-products/): upload flow and required material.
- [Product guidelines](https://docs.elgato.com/guidelines/products/): description, app icon, thumbnail, and gallery requirements.
- [Plugin guidelines](https://docs.elgato.com/guidelines/stream-deck/plugins/): action icons, key images, metadata, and feedback.
- [Review process](https://docs.elgato.com/maker-console/review-process/): demonstration evidence, review time, and automatic publication.
- [Distribution](https://docs.elgato.com/streamdeck/sdk/introduction/distribution/): packaging and optional DRM. DRM is not required by this draft.
