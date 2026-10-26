# AlbumArtView

The Discord settings preview resolves buttons through `DiscordPresenceBuilder`,
so custom labels, toggles, missing links, and invalid URLs match the live presence
alongside the artwork.

**File:** [`apps/native/WolfWave/Views/Shared/AlbumArtView.swift`](../../apps/native/WolfWave/Views/Shared/AlbumArtView.swift)

## Purpose
Sized album-art tile with a WolfWave-branded fallback (the wolf mark on a brand-blue gradient) when no artwork is available. Used by the General now-playing hero. Discord preview shares the retained-image loader with its own Apple Music fallback; the AppKit menu uses its existing bitmap cache.

## API
```swift
// Direct image (cache hit / preloaded)
AlbumArtView(image: nsImage, size: 92)

// Phased URL load (cold cache, remote artwork)
AlbumArtView(url: artworkURL, size: 92)

// Fallback only
AlbumArtView(size: 92)
```

| Param | Type | Notes |
|---|---|---|
| `image` | `NSImage?` | Real artwork. Takes precedence over `url`. Nil + nil `url` triggers branded fallback. |
| `url` | `URL?` | Remote artwork. Used only when `image == nil`. Retains the displayed image while loading its replacement. |
| `size` | `CGFloat` | Square edge in points. 36 / 64 / 92 are the documented sizes. |
| `cornerRadius` | `CGFloat?` | Override the default radius (`max(4, size * 0.10)`). |

## Tokens used
- `DSColor.brand500` → `DSColor.brand800`: fallback gradient (topLeading→bottomTrailing)
- `DSRadius.sm`–`DSRadius.lg` (4–10): radius derived as `size * 0.10` (≥4)
- `DSMotion.Duration.base` (0.22): Artwork crossfade duration on `url` path, gated by `@Environment(\.accessibilityReduceMotion)`
- Hairline overlay stroke (`white opacity 0.10`, 0.5pt): separation from any background
- Drop shadow `rgba(0,0,0,0.18)` r=2 y=1: lifts the tile
- `WolfMark` template image, tinted white, at `size * 0.52`

## Loading paths

| `image` | `url` | Renders |
|---|---|---|
| non-nil | _any_ | `Image(nsImage:)` with `.transition(.opacity)` for cross-fade when caller swaps the binding |
| nil | non-nil | Previous cover remains during loading; resolved image crossfades over `DSMotion.Duration.base`; failure uses the placeholder |
| nil | nil | Branded gradient + `WolfMark` |

`ArtworkImageLoader` uses the shared URLSession cache for image bytes and retains one displayed bitmap per tile. Cancelled and superseded requests cannot replace it. A resolved missing URL, invalid image, or download failure clears the previous cover. Metadata callers retain their previous URL only while a lookup is pending.

## Anatomy
```mermaid
graph TB
  Tile[Frame size×size, clipShape RoundedRectangle] --> Pick{image? url?}
  Pick -->|image| Img[Image, resizable fill .transition .opacity]
  Pick -->|url only| Async[ArtworkImageLoader, retain current image while pending]
  Async --> Success[Resolved image, crossfade replacement]
  Async --> EmptyFail[Completed miss or failure, placeholder]
  Pick -->|neither| Placeholder[LinearGradient brand500→brand800 + WolfMark]
  Tile --> Stroke[Hairline overlay 0.5pt white@10%]
  Tile --> Shadow[Shadow r=2 y=1 black@18%]
```

## Accessibility
- Decorative (no `accessibilityLabel`). The parent (e.g. `NowPlayingHeroCard`) is the labelled element.
- The branded fallback is a fixed asset + static gradient. No per-render computation.
- Reduce Motion: artwork animation is disabled, so the resolved replacement appears immediately.

## Do / Don't
- ✅ Pass real artwork when available; `ArtworkService` resolves iTunes Search URLs and caches them.
- ✅ Let the fallback render as-is. It is intentionally identical for every song.
- ❌ Don't stretch with a non-square frame. The tile is clipped square at `size × size`.
- ❌ Don't swap the `WolfMark` asset for a generic glyph. The branded mark is the point of the fallback.

## Example
```swift
AlbumArtView(
    image: nowPlaying?.artwork,
    size: 64
)
```

> The OBS widget (`Resources/widget.html`, `artImg`) mirrors this fallback with the canonical mark from `assets/logo.svg` on the same brand gradient. Keep it in sync with `WolfMark.svg`.
