/**
 * Every key must actually paint.
 *
 * The bug this exists to catch: a `render()` that throws is turned into an
 * unhandled rejection by the base class's `void this.paint(...)`, which kills
 * the Node plugin process. Stream Deck restarts it, the same key throws again,
 * and the deck sits showing its last cached image — indistinguishable, from the
 * outside, from an image the renderer rejected. Hours went into bisecting SVG
 * that was never being sent.
 */

import { afterEach, describe, expect, test } from "bun:test";
import { ACTION_CLASSES, TrackTimeAction } from "../src/actions/index.js";
import { trackTimeImage, nowPlayingImage } from "../src/keyart.js";
import { WolfWaveClient } from "../src/wolfwave/client.js";
import {
  initialState,
  withPhase,
  type WolfWaveState,
} from "../src/wolfwave/state.js";

interface Painted {
  images: string[];
  titles: string[];
  states: number[];
}

/** Stand-in for the SDK's KeyAction, recording what it was told to draw. */
function fakeKey(id = "key-1") {
  const painted: Painted = { images: [], titles: [], states: [] };
  const key = {
    id,
    painted,
    isKey: () => true,
    setImage: async (image?: string) => {
      painted.images.push(image ?? "<cleared>");
    },
    setTitle: async (title?: string) => {
      painted.titles.push(title ?? "");
    },
    setState: async (state: number) => {
      painted.states.push(state);
    },
    showOk: async () => {},
    showAlert: async () => {},
    setSettings: async (_settings: Record<string, unknown>) => {},
  };
  return key;
}

/** Calls the protected renderer the way the base class does. */
async function render(instance: object, key: unknown, state: WolfWaveState) {
  await (
    instance as { render(k: unknown, s: WolfWaveState): Promise<void> | void }
  ).render(key, state);
}

const timers: Array<ReturnType<typeof setInterval>> = [];
afterEach(() => {
  for (const t of timers) clearInterval(t);
  timers.length = 0;
});

describe("connection artwork", () => {
  test("static keys restore manifest art after a disconnect and reconnect", async () => {
    const client = new WolfWaveClient();
    const key = fakeKey();
    const action = new ACTION_CLASSES[1](client); // Next Track has no live image.
    action.onWillAppear({ action: key } as never);
    await Bun.sleep(0);
    expect(key.painted.images.at(-1)).toContain("Offline");

    (client as unknown as { setState(state: WolfWaveState): void }).setState({ ...initialState, phase: "connected" });
    await Bun.sleep(0);
    expect(key.painted.images.at(-1)).toBe("<cleared>");
    const images = key.painted.images.length;
    (client as unknown as { setState(state: WolfWaveState): void }).setState({ ...initialState, phase: "connected", queueCount: 1 });
    await Bun.sleep(0);
    expect(key.painted.images.length).toBe(images);
    action.onWillDisappear({ action: key } as never);
  });

  test("a stale reconnect does not render live state after going offline again", async () => {
    const client = new WolfWaveClient();
    const key = fakeKey();
    const action = new ACTION_CLASSES[0](client); // Play / Pause sets live state.
    const push = (state: WolfWaveState) => (client as unknown as { setState(state: WolfWaveState): void }).setState(state);
    action.onWillAppear({ action: key } as never);
    await Bun.sleep(0);
    let release: () => void = () => {};
    let started: () => void = () => {};
    const restored = new Promise<void>((resolve) => { started = resolve; });
    const paint = key.setImage;
    key.setImage = async (image?: string) => {
      await paint(image);
      if (image === undefined) {
        started();
        await new Promise<void>((resolve) => { release = resolve; });
      }
    };
    push({ ...initialState, phase: "connected", isPlaying: true });
    await restored;
    client.stop();
    await Bun.sleep(0);
    release();
    await Bun.sleep(0);
    expect(key.painted.images.at(-1)).toContain("Offline");
    expect(key.painted.states.at(-1)).toBe(0);
    action.onWillDisappear({ action: key } as never);
  });
});

describe("track time", () => {
  test("formats elapsed, remaining, unknown and clamped progress", () => {
    expect(trackTimeImage(65, 180, false)).toContain("1:05");
    expect(trackTimeImage(65, 180, true)).toContain("−1:55");
    expect(trackTimeImage(1, 0, false)).toContain("--:--");
    expect(trackTimeImage(300, 180, true)).toContain("−0:00");
    expect(trackTimeImage(65, 180, true, true)).toContain("PAUSED");
    expect(trackTimeImage(0, 0, true, true)).not.toContain("PAUSED");
  });

  test("updates only time keys and retains each key's chosen mode", async () => {
    const client = new WolfWaveClient();
    const push = (frame: object) => (client as unknown as { handleMessage(text: string): void }).handleMessage(JSON.stringify(frame));
    push({ type: "welcome", version: "2.2" });
    push({ type: "now_playing", data: { track: "Howl", elapsed: 65, duration: 180, isPlaying: true } });
    const action = new TrackTimeAction(client);
    const elapsed = fakeKey("elapsed");
    const remaining = fakeKey("remaining");
    let saved: Record<string, unknown> = {};
    elapsed.setSettings = async (settings) => { saved = settings; };
    const appear = (key: typeof elapsed, mode: boolean) => action.onWillAppear({ action: key, payload: { settings: { remaining: mode } } } as never);
    appear(elapsed, false);
    appear(remaining, true);
    const now = new ACTION_CLASSES[ACTION_CLASSES.length - 1](client);
    const other = fakeKey("now");
    (now as unknown as { onWillAppear(ev: unknown): void }).onWillAppear({ action: other });
    await Bun.sleep(10);
    const before = other.painted.images.length;
    push({ type: "progress", data: { elapsed: 66, duration: 180, isPlaying: true } });
    await Bun.sleep(10);
    expect(elapsed.painted.images.at(-1)).toContain("1:06");
    expect(remaining.painted.images.at(-1)).toContain("−1:54");
    expect(other.painted.images.length).toBe(before);
    await action.onKeyDown({ action: elapsed, payload: { settings: {} } });
    expect(elapsed.painted.images.at(-1)).toContain("−1:54");
    expect(saved.remaining).toBe(true);
    action.onWillDisappear({ action: elapsed } as never);
    appear(elapsed, saved.remaining === true);
    await Bun.sleep(10);
    expect(elapsed.painted.images.at(-1)).toContain("−1:54");
    push({ type: "now_playing", data: { track: "Howl", elapsed: 68, duration: 180, isPlaying: false } });
    await Bun.sleep(10);
    expect(remaining.painted.images.at(-1)).toContain("−1:52");
    push({ type: "playback_state", data: { track: "", isPlaying: false } });
    await Bun.sleep(10);
    expect(remaining.painted.images.at(-1)).toContain("--:--");
    action.onWillDisappear({ action: elapsed } as never);
    const count = elapsed.painted.images.length;
    push({ type: "progress", data: { elapsed: 67, duration: 180, isPlaying: true } });
    await Bun.sleep(10);
    expect(elapsed.painted.images.length).toBe(count);
    action.onWillDisappear({ action: remaining } as never);
    (now as unknown as { onWillDisappear(ev: unknown): void }).onWillDisappear({ action: other });
  });

  test("shows a pause badge over artwork only when paused", () => {
    expect(nowPlayingImage({ label: "Song", paused: true })).toContain('M56 8h2.5');
    expect(nowPlayingImage({ label: "Song" })).not.toContain('M56 8h2.5');
  });

  test("a delayed time paint cannot overwrite the offline reset", async () => {
    const client = new WolfWaveClient();
    const push = (frame: object) => (client as unknown as { handleMessage(text: string): void }).handleMessage(JSON.stringify(frame));
    push({ type: "welcome", version: "2.2" });
    push({ type: "now_playing", data: { track: "Howl", elapsed: 65, duration: 180, isPlaying: true } });
    const action = new TrackTimeAction(client);
    const key = fakeKey();
    let release: () => void = () => {};
    let started: () => void = () => {};
    const startedPromise = new Promise<void>((resolve) => { started = resolve; });
    let delayNextImage = true;
    key.setImage = async (image?: string) => {
      if (delayNextImage) {
        delayNextImage = false;
        started();
        await new Promise<void>((resolve) => { release = resolve; });
      }
      key.painted.images.push(image ?? "<cleared>");
    };
    action.onWillAppear({ action: key, payload: { settings: {} } } as never);
    await startedPromise;
    client.stop();
    release();
    await Bun.sleep(10);
    expect(key.painted.images.at(-1)).toContain("Offline");
    expect(key.painted.titles.at(-1)).toBe("");
    action.onWillDisappear({ action: key } as never);
  });

  test("reconfiguration clears the old track time immediately", () => {
    const client = new WolfWaveClient();
    const push = (frame: object) => (client as unknown as { handleMessage(text: string): void }).handleMessage(JSON.stringify(frame));
    push({ type: "welcome", version: "2.2" });
    push({ type: "now_playing", data: { track: "Howl", elapsed: 65, duration: 180 } });
    expect(client.currentProgress?.elapsed).toBe(65);
    client.configure({ port: 8765, token: "bad" });
    expect(client.currentProgress).toBeNull();
    expect(client.currentState.phase).toBe("disconnected");
    client.stop();
  });
});

/** A live connection with a long track, i.e. the marquee case. */
const playing: WolfWaveState = {
  ...initialState,
  phase: "connected",
  track: "Trapped at Midnight",
  artist: "Grey Wolf",
  isPlaying: true,
  queueCount: 3,
  queuePending: 1,
};

describe("every action renders without throwing", () => {
  for (const ActionClass of ACTION_CLASSES) {
    test(ActionClass.name, async () => {
      const instance = new ActionClass(new WolfWaveClient());
      const key = fakeKey();

      // The assertion is simply that this resolves. A throw here is what took
      // the whole plugin process down on hardware.
      await render(instance, key, playing);

      const drew =
        key.painted.images.length > 0 ||
        key.painted.titles.length > 0 ||
        key.painted.states.length > 0;
      expect(drew).toBe(true);

      const scrollers = (instance as unknown as { scrollers?: Map<string, ReturnType<typeof setInterval>> })
        .scrollers;
      if (scrollers) timers.push(...scrollers.values());
    });
  }
});

describe("NowPlayingAction", () => {
  test("paints an image, not just a title", async () => {
    // Looked up by position, not by `name`: the `@action` decorator replaces
    // the class, so the constructor's `.name` is not the source name.
    const NowPlaying = ACTION_CLASSES[ACTION_CLASSES.length - 1];
    const action = new NowPlaying(new WolfWaveClient());
    const key = fakeKey();
    await render(action, key, playing);

    const scrollers = (action as unknown as { scrollers?: Map<string, ReturnType<typeof setInterval>> })
      .scrollers;
    if (scrollers) timers.push(...scrollers.values());

    expect(key.painted.images.length).toBeGreaterThan(0);
    expect(key.painted.images[0]).toContain("<svg");
  });
});

describe("willAppear wiring", () => {
  /** Drives the real subscription path rather than calling render directly. */
  function appear(instance: object, key: unknown) {
    (instance as { onWillAppear(ev: { action: unknown }): void }).onWillAppear({
      action: key,
    });
  }

  function disappear(instance: object, key: { id: string }) {
    (
      instance as { onWillDisappear(ev: { action: { id: string } }): void }
    ).onWillDisappear({ action: key });
  }

  test("a key paints as soon as it appears", async () => {
    // `onState` hands a new subscriber the current snapshot, so a key added
    // mid-session must not sit blank waiting for the next broadcast.
    const action = new ACTION_CLASSES[0](new WolfWaveClient());
    const key = fakeKey();

    appear(action, key);
    await Bun.sleep(0);

    expect(key.painted.titles.length + key.painted.images.length).toBeGreaterThan(0);
  });

  test("appearing twice without a disappear does not strand a listener", async () => {
    // Profile switches and device reconnects both deliver a second willAppear.
    // A stranded listener repaints the same key forever.
    const client = new WolfWaveClient();
    const action = new ACTION_CLASSES[0](client);
    const key = fakeKey();

    appear(action, key);
    appear(action, key);
    await Bun.sleep(0);

    const subs = (action as unknown as { subscriptions?: Map<string, unknown> }).subscriptions;
    expect(subs?.size).toBe(1);
  });

  test("a key stops painting once it disappears", async () => {
    const action = new ACTION_CLASSES[0](new WolfWaveClient());
    const key = fakeKey();

    appear(action, key);
    disappear(action, key);

    const subs = (action as unknown as { subscriptions?: Map<string, unknown> }).subscriptions;
    expect(subs?.size).toBe(0);
  });
});

describe("NowPlayingAction marquee lifecycle", () => {
  const NowPlaying = ACTION_CLASSES[ACTION_CLASSES.length - 1];

  function scrollerCount(action: object): number {
    return (action as unknown as { scrollers: Map<string, unknown> }).scrollers
      .size;
  }

  /** Pushes a state through the client the way a socket frame would. */
  function push(client: WolfWaveClient, state: WolfWaveState) {
    (client as unknown as { setState(s: WolfWaveState): void }).setState(state);
  }

  test("disconnectStopsMarqueeInterval", async () => {
    const client = new WolfWaveClient();
    push(client, playing);
    const action = new NowPlaying(client);
    const key = fakeKey();
    (action as unknown as { onWillAppear(e: unknown): void }).onWillAppear({
      action: key,
    });
    await Bun.sleep(20);
    expect(scrollerCount(action)).toBe(1);

    push(client, withPhase(playing, "disconnected"));
    await Bun.sleep(20);
    expect(scrollerCount(action)).toBe(0);
    expect(key.painted.images.at(-1)).toContain("Offline");

    // No further frames once the marquee is stopped.
    const frames = key.painted.images.length;
    await Bun.sleep(600);
    expect(key.painted.images.length).toBe(frames);
  });

  test("renderAfterDisappearDoesNotStartInterval", async () => {
    const realFetch = globalThis.fetch;
    let release: (r: Response) => void = () => {};
    globalThis.fetch = (() =>
      new Promise<Response>((resolve) => {
        release = resolve;
      })) as unknown as typeof fetch;
    try {
      const client = new WolfWaveClient();
      push(client, {
        ...playing,
        artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/pending-art/1.jpg",
      });
      const action = new NowPlaying(client);
      const key = fakeKey();
      const a = action as unknown as {
        onWillAppear(e: unknown): void;
        onWillDisappear(e: unknown): void;
      };
      a.onWillAppear({ action: key });
      await Bun.sleep(20); // render is now parked on the artwork fetch
      a.onWillDisappear({ action: key });
      release(new Response(null, { status: 404 }));
      await Bun.sleep(20);

      expect(scrollerCount(action)).toBe(0);
      expect(key.painted.images).toEqual([]);
    } finally {
      globalThis.fetch = realFetch;
    }
  });
});
