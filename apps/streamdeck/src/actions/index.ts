/**
 * The v3 key set. One class per manifest action.
 *
 * Every UUID here must match an entry in
 * `com.mrdemonwolf.wolfwave.sdPlugin/manifest.json`; the SDK silently ignores a
 * registered action whose UUID isn't in the manifest.
 */

import {
  action,
  type WillDisappearEvent,
  type WillAppearEvent,
} from "@elgato/streamdeck";
import { artworkDataURI } from "../artwork.js";
import {
  REPEAT_SEPARATOR,
  STEP_MS,
  offsetAt,
  overflows,
  visibleSlice,
} from "../marquee.js";
import {
  KEY_SIZE,
  Palette,
  audienceGate,
  check,
  countKeyImage,
  hold,
  labelKeyImage,
  nowPlayingImage,
  resume,
  trash,
  trackTimeImage,
} from "../keyart.js";
import { AUDIENCE_LABELS, type WolfWaveAction } from "../wolfwave/protocol.js";
import type { WolfWaveState } from "../wolfwave/state.js";
import { KeyState, WolfWaveKeyAction, type WolfWaveKey } from "./base.js";

const PLUGIN_UUID = "com.mrdemonwolf.wolfwave";

// MARK: - Playback

@action({ UUID: `${PLUGIN_UUID}.playpause` })
class PlayPauseAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "play_pause";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    // No track text. This is a transport control, and the Now Playing key is
    // where the track belongs; writing it here also stole the title from any
    // label the streamer set.
    await key.setTitle("");
    await key.setState(state.isPlaying ? KeyState.secondary : KeyState.primary);
  }
}

@action({ UUID: `${PLUGIN_UUID}.skip` })
class SkipAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "skip";
  }

  protected async render(key: WolfWaveKey): Promise<void> {
    await key.setTitle("");
  }
}

// MARK: - Queue

/**
 * One key for both hold and resume: which command it sends depends on whether
 * the queue is currently held, read from `queue_state.held`.
 *
 * Reading real state rather than tracking a local toggle matters because hold is
 * changeable from the tray, chat (`!hold`), and Settings — a plugin-local guess
 * inverts the moment hold is used from any of those. The app rebroadcasts
 * `queue_state` on every hold change, so the key follows.
 */
@action({ UUID: `${PLUGIN_UUID}.queuehold` })
export class QueueHoldAction extends WolfWaveKeyAction {
  protected commandFor(state: WolfWaveState): WolfWaveAction {
    return state.queueHeld ? "resume_queue" : "hold_queue";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    await key.setImage(
      countKeyImage({
        glyph: state.queueHeld ? resume : hold,
        label: state.queueHeld ? "RESUME" : "HOLD",
        count: state.queueCount,
        tile: state.queueHeld ? Palette.tile : undefined,
      }),
    );
    await key.setTitle("");
    await key.setState(state.queueHeld ? KeyState.secondary : KeyState.primary);
  }
}

@action({ UUID: `${PLUGIN_UUID}.approvenext` })
class ApproveNextAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "approve_next";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    // Pending is the whole point of this key. Amber rather than brand blue:
    // this one is asking the streamer to do something, not reporting a state.
    const pending = state.queuePending > 0;
    await key.setImage(
      countKeyImage({
        glyph: check,
        label: "APPROVE",
        count: state.queuePending,
        tile: pending ? Palette.warning : undefined,
        tint: Palette.dim,
      }),
    );
    await key.setTitle("");
    await key.setState(pending ? KeyState.secondary : KeyState.primary);
  }
}

/**
 * The one key that destroys something with no undo, so it is the one key you
 * have to hold. A stray press here throws away every request in the queue,
 * which on a live stream is a mess of "where did my song go" in chat.
 */
@action({ UUID: `${PLUGIN_UUID}.clearqueue` })
export class ClearQueueAction extends WolfWaveKeyAction {
  /** Long enough to be deliberate, short enough not to feel broken. */
  protected override get holdToConfirmMs(): number {
    return 800;
  }

  protected commandFor(): WolfWaveAction {
    return "clear_queue";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    await key.setImage(
      countKeyImage({
        glyph: trash,
        label: "CLEAR",
        count: state.queueCount,
        tint: Palette.danger,
      }),
    );
    await key.setTitle("");
  }
}

@action({ UUID: `${PLUGIN_UUID}.blockcurrent` })
class BlockCurrentAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "block_current";
  }

  protected async render(key: WolfWaveKey): Promise<void> {
    await key.setTitle("");
  }
}

// MARK: - Integration toggles

@action({ UUID: `${PLUGIN_UUID}.overlaytoggle` })
class OverlayToggleAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "overlay_toggle";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    await key.setTitle("");
    await key.setState(
      state.health.overlay ? KeyState.secondary : KeyState.primary,
    );
  }
}

// MARK: - Chat

@action({ UUID: `${PLUGIN_UUID}.announcesong` })
class AnnounceSongAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "announce_song";
  }

  protected async render(key: WolfWaveKey): Promise<void> {
    await key.setTitle("");
  }
}

/**
 * Rejects the request that is playing and tells chat it went. Distinct from
 * Skip, which advances playback and says nothing — a silent removal reads to
 * the requester like the bot ate their song.
 */
@action({ UUID: `${PLUGIN_UUID}.rejectcurrent` })
class RejectCurrentAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "reject_current";
  }

  protected async render(key: WolfWaveKey): Promise<void> {
    await key.setTitle("");
  }
}

/**
 * Bars the person who requested what is playing. Held, like Clear Queue: it
 * shuts someone out of the queue entirely, and the app has no undo beyond
 * removing the entry in Settings.
 */
@action({ UUID: `${PLUGIN_UUID}.blockrequester` })
export class BlockRequesterAction extends WolfWaveKeyAction {
  protected override get holdToConfirmMs(): number {
    return 800;
  }

  protected commandFor(): WolfWaveAction {
    return "block_requester";
  }

  protected async render(key: WolfWaveKey): Promise<void> {
    await key.setTitle("");
  }
}

/**
 * Walks the request gate one step tighter each press and wraps back to open.
 *
 * Renders the audience it reads from the app rather than the one it last sent,
 * so changing the audience in Settings moves the key too.
 */
@action({ UUID: `${PLUGIN_UUID}.cycleaudience` })
export class CycleAudienceAction extends WolfWaveKeyAction {
  protected commandFor(): WolfWaveAction {
    return "cycle_audience";
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    const open = state.requestAudience === "everyone";
    await key.setImage(
      labelKeyImage({
        glyph: audienceGate,
        label: AUDIENCE_LABELS[state.requestAudience],
        // Open is the resting state; anything narrower is a gate the streamer
        // put up on purpose and should be able to see at a glance.
        tile: open ? undefined : Palette.tile,
      }),
    );
    await key.setTitle("");
    await key.setState(open ? KeyState.primary : KeyState.secondary);
  }
}

// MARK: - Display

/** A tap switches this key between elapsed and remaining time. */
@action({ UUID: `${PLUGIN_UUID}.tracktime` })
export class TrackTimeAction extends WolfWaveKeyAction {
  private readonly modes = new Map<string, boolean>();
  private readonly progressSubscriptions = new Map<string, () => void>();
  private readonly paints = new Map<string, Promise<void>>();
  private readonly revisions = new Map<string, number>();

  protected commandFor(): null { return null; }

  override onWillAppear(ev: WillAppearEvent): void {
    if (!ev.action.isKey()) return;
    const key = ev.action;
    this.modes.set(key.id, ev.payload.settings.remaining === true);
    this.progressSubscriptions.get(key.id)?.();
    this.progressSubscriptions.set(key.id, this.client.onProgress(() => {
      if (this.client.currentState.phase === "connected") void this.paint(key, this.client.currentState);
    }));
    super.onWillAppear(ev);
  }

  override onWillDisappear(ev: WillDisappearEvent): void {
    this.progressSubscriptions.get(ev.action.id)?.();
    this.progressSubscriptions.delete(ev.action.id);
    this.modes.delete(ev.action.id);
    this.revisions.set(ev.action.id, (this.revisions.get(ev.action.id) ?? 0) + 1);
    super.onWillDisappear(ev);
  }

  override async onKeyDown(ev: { action: unknown; payload: { settings: Record<string, unknown> } }): Promise<void> {
    const key = ev.action as WolfWaveKey;
    if (!key.isKey()) return;
    const remaining = !this.modes.get(key.id);
    this.modes.set(key.id, remaining);
    await key.setSettings({ ...ev.payload.settings, remaining });
    if (this.client.currentState.phase === "connected") await this.paint(key, this.client.currentState);
  }

  protected override paint(key: WolfWaveKey, state: WolfWaveState): Promise<void> {
    const revision = (this.revisions.get(key.id) ?? 0) + 1;
    this.revisions.set(key.id, revision);
    const previous = this.paints.get(key.id) ?? Promise.resolve();
    const next = previous.then(async () => {
      if (this.revisions.get(key.id) === revision) await super.paint(key, state);
    }).catch(() => {});
    this.paints.set(key.id, next);
    void next.finally(() => {
      if (this.paints.get(key.id) === next) {
        this.paints.delete(key.id);
        if (!this.modes.has(key.id)) this.revisions.delete(key.id);
      }
    }).catch(() => {});
    return next;
  }

  protected async render(key: WolfWaveKey, state: WolfWaveState): Promise<void> {
    const progress = this.client.currentProgress;
    const generation = this.generationOf(key.id);
    await key.setTitle("");
    if (this.isStale(key.id, generation) || this.client.currentState.phase !== "connected") return;
    await key.setImage(trackTimeImage(
      state.track ? progress?.elapsed ?? 0 : 0,
      state.track ? progress?.duration ?? 0 : 0,
      this.modes.get(key.id) ?? false,
      !state.isPlaying,
    ));
  }
}

/**
 * Display-only: what is playing, over its album art. Pressing it does nothing
 * rather than firing a command the streamer didn't intend mid-broadcast.
 */
@action({ UUID: `${PLUGIN_UUID}.nowplaying` })
export class NowPlayingAction extends WolfWaveKeyAction {
  /** Marquee timers, one per visible key. */
  private readonly scrollers = new Map<string, ReturnType<typeof setInterval>>();

  protected commandFor(): null {
    return null;
  }

  override onWillDisappear(ev: WillDisappearEvent): void {
    // The timer outlives the key otherwise, repainting something nobody is
    // looking at for the rest of the session.
    this.stopScrolling(ev.action.id);
    super.onWillDisappear(ev);
  }

  protected override onReset(action: WolfWaveKey): void {
    // Going offline must stop the marquee, or it keeps scrolling the last track
    // over the "Offline" title and reads as live.
    this.stopScrolling(action.id);
  }

  protected async render(
    key: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> {
    // Every await below is a point where the key can go offline or disappear.
    // A render that resumes after that must not install a timer nobody clears.
    const generation = this.generationOf(key.id);

    // The title is the streamer's to label the key with; the track goes in the
    // art, which is the only way it can scroll.
    await key.setTitle("");
    if (this.isStale(key.id, generation)) return;
    await key.setState(state.isPlaying ? KeyState.secondary : KeyState.primary);
    if (this.isStale(key.id, generation)) return;

    const label = nowPlayingLabel(state);
    const art = state.artworkURL
      ? await artworkDataURI(state.artworkURL)
      : undefined;
    if (this.isStale(key.id, generation)) return;

    // Last step before the new timer, so overlapping renders leave one interval.
    this.stopScrolling(key.id);
    if (!overflows(label, MARQUEE_FONT_SIZE, KEY_SIZE)) {
      // Short enough to sit still. Scrolling "Home" back and forth forever
      // would be worse than not scrolling, and it would repaint for nothing.
      await key.setImage(nowPlayingImage({ art, label, paused: !!state.track && !state.isPlaying }));
      return;
    }
    // Two copies end to end, so scrolling past the tail runs into the head
    // rather than snapping back. The separator is shared with `offsetAt`'s wrap
    // calculation; two notions of the gap drift and the wrap visibly jumps.
    // Which characters are visible is worked out here, not by the renderer --
    // QtSvg has no clipPath.
    const doubled = `${label}${REPEAT_SEPARATOR}${label}`;
    let step = 0;
    // One send at a time. `setInterval` does not wait, so a slow write would
    // otherwise overlap the next tick and queue frames faster than they drain.
    let inFlight = false;
    const paint = (): void => {
      if (inFlight) return;
      const slice = visibleSlice(
        doubled,
        offsetAt(step, label, MARQUEE_FONT_SIZE),
        MARQUEE_FONT_SIZE,
        KEY_SIZE,
      );
      step += 1;
      inFlight = true;
      key
        .setImage(nowPlayingImage({ art, label: slice.text, offset: slice.x, paused: !!state.track && !state.isPlaying }))
        .catch(() => {
          // A dropped frame is nothing; an unhandled rejection takes the whole
          // plugin process down, and the key freezes on its last art.
        })
        .finally(() => {
          inFlight = false;
        });
    };
    paint();
    this.scrollers.set(key.id, setInterval(paint, STEP_MS));
  }

  private stopScrolling(id: string): void {
    const timer = this.scrollers.get(id);
    if (!timer) return;
    clearInterval(timer);
    this.scrollers.delete(id);
  }
}

// MARK: - Helpers

/** Font size of the scrolling track label, shared with the width estimate. */
const MARQUEE_FONT_SIZE = 14;

/**
 * What the Now Playing key spells out: track, then artist when there is one.
 *
 * One string rather than two lines because it scrolls — two scrolling lines on
 * a 72px key is noise, and the artist is the part you can afford to wait for.
 */
function nowPlayingLabel(state: WolfWaveState): string {
  if (!state.track) return "Nothing playing";
  return state.artist ? `${state.track} — ${state.artist}` : state.track;
}

/** Every action class, in manifest order. */
export const ACTION_CLASSES = [
  PlayPauseAction,
  SkipAction,
  QueueHoldAction,
  ApproveNextAction,
  ClearQueueAction,
  BlockCurrentAction,
  OverlayToggleAction,
  AnnounceSongAction,
  RejectCurrentAction,
  BlockRequesterAction,
  CycleAudienceAction,
  TrackTimeAction,
  NowPlayingAction,
] as const;
