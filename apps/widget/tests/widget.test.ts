/**
 * WolfWave OBS widget: runtime tests.
 *
 * The widget is a self-booting script (no exports), so each test registers a
 * fresh happy-dom window, installs a fake WebSocket, and imports `widget.ts`
 * under a unique specifier so its module state starts clean. Frames are pushed
 * through the fake socket's `onmessage`, exactly as the native server would.
 */

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { GlobalRegistrator } from "@happy-dom/global-registrator";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const TOKENS_JS = resolve(
  import.meta.dir,
  "../../native/WolfWave/Resources/widget-tokens.generated.js",
);

class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  static throwOnConstruct = false;
  onopen: (() => void) | null = null;
  onmessage: ((e: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: ((e: unknown) => void) | null = null;
  closed = false;
  constructor(
    public url: string,
    public protocols?: string | string[],
  ) {
    if (FakeWebSocket.throwOnConstruct) throw new Error("SecurityError");
    FakeWebSocket.instances.push(this);
  }
  close(): void {
    this.closed = true;
  }
}

interface Timer {
  delay: number;
  fire: () => void;
}

let timers: Timer[] = [];
let loadCount = 0;

/** Boot a fresh widget page. `search` is the query string, e.g. "?port=9000". */
async function boot(search = ""): Promise<void> {
  GlobalRegistrator.register({ url: "http://localhost/" + search });
  document.body.innerHTML =
    '<div id="root"><div id="widget" class="placeholder">Waiting for music&hellip;</div></div>' +
    '<div id="queue-ticker" class="hidden"></div>';
  (globalThis as any).WebSocket = FakeWebSocket;

  // Record reconnect timers so a test can read the delay and fire them on demand.
  const realSetTimeout = window.setTimeout.bind(window);
  (window as any).setTimeout = (fn: () => void, delay?: number, ...rest: unknown[]) => {
    if (typeof delay === "number" && delay >= 500) {
      const t: Timer = { delay, fire: fn };
      timers.push(t);
      return timers.length;
    }
    return realSetTimeout(fn, delay, ...rest);
  };

  (0, eval)(readFileSync(TOKENS_JS, "utf8"));
  await import(`../src/widget.ts?case=${++loadCount}`);
}

function socket(): FakeWebSocket {
  const s = FakeWebSocket.instances.at(-1);
  if (!s) throw new Error("widget never opened a socket");
  return s;
}

function send(msg: unknown): void {
  const s = socket();
  s.onmessage?.({ data: typeof msg === "string" ? msg : JSON.stringify(msg) });
}

const track = (over: Record<string, unknown> = {}) => ({
  type: "now_playing",
  data: {
    track: "Howl at the Moon",
    artist: "Timber Wolf",
    album: "Pack Songs",
    duration: 200,
    elapsed: 12,
    isPlaying: true,
    artworkURL: "https://is1-ssl.mzstatic.com/image/thumb/Music/a/100x100bb.jpg",
    ...over,
  },
});

/** Let the widget's double-rAF entrance settle. */
const settle = () => new Promise<void>((r) => setTimeout(r, 80));

const widgetEl = () => document.getElementById("widget") as HTMLElement;

beforeEach(() => {
  FakeWebSocket.instances = [];
  FakeWebSocket.throwOnConstruct = false;
  timers = [];
});

afterEach(async () => {
  // Stop the widget's own timers (progress loop etc.) with the window.
  await GlobalRegistrator.unregister();
});

describe("rendering", () => {
  test("replayed snapshots preserve artwork while updating elapsed time", async () => {
    await boot();
    send(track());
    const art = widgetEl().querySelector(".artwork");
    send(track({ elapsed: 42 }));
    expect(widgetEl().querySelector(".artwork")).toBe(art);
    expect(widgetEl().querySelector(".elapsed-time")?.textContent).toBe("0:42");
    send({ type: "widget_config", data: {} });
    expect(widgetEl().querySelector(".artwork")).toBe(art);
    send(track({ album: "New album" }));
    expect(widgetEl().querySelector(".artwork")).not.toBe(art);
  });

  test("unchanged native preview drafts preserve the rendered card", async () => {
    await boot("?preview");
    const preview = (window as any).WWPreview;
    preview.track(track().data);
    const art = widgetEl().querySelector(".artwork");
    preview.config({});
    expect(widgetEl().querySelector(".artwork")).toBe(art);
    preview.config({ layout: "Classic" });
    expect(widgetEl().querySelector(".progress-knob")).not.toBeNull();
    expect(FakeWebSocket.instances).toHaveLength(0);
  });

  test("now_playing renders the card", async () => {
    await boot();
    send(track());
    expect(widgetEl().textContent).toContain("Howl at the Moon");
    expect(widgetEl().textContent).toContain("Timber Wolf");
    expect(widgetEl().classList.contains("placeholder")).toBe(false);
    const img = widgetEl().querySelector("img.artwork") as HTMLImageElement;
    expect(img.getAttribute("src")).toStartWith("https://is1-ssl.mzstatic.com/");
  });

  test("playback_state not playing clears the card", async () => {
    await boot();
    send(track());
    await settle();
    expect(widgetEl().classList.contains("widget-visible")).toBe(true);
    send({ type: "playback_state", data: { isPlaying: false, track: "", artist: "", album: "" } });
    expect(widgetEl().classList.contains("widget-visible")).toBe(false);
    expect(widgetEl().classList.contains("widget-exiting")).toBe(true);
  });

  test("track text is HTML-escaped", async () => {
    await boot();
    send(track({ track: '<img src=x onerror="boom()">', artist: "a&b" }));
    expect(widgetEl().querySelector("img[onerror]")).toBeNull();
    expect(widgetEl().textContent).toContain('<img src=x onerror="boom()">');
  });

  test("widget_config layout selects layout markup", async () => {
    await boot();
    send(track());
    expect(widgetEl().querySelector(".progress-knob")).toBeNull();
    send({ type: "widget_config", data: { theme: "Default", layout: "Classic" } });
    expect(widgetEl().querySelector(".progress-knob")).not.toBeNull();
  });

  test("widget_config theme maps to container styling", async () => {
    await boot();
    const themes = (window as any).WW_TOKENS.themes as Record<string, { containerBorder: string }>;
    send(track());
    send({ type: "widget_config", data: { theme: "Neon", layout: "Horizontal" } });
    expect(widgetEl().style.border).toBe(themes.Neon.containerBorder);
  });

  test("?hideAlbumArt drops the artwork", async () => {
    await boot("?hideAlbumArt");
    send(track());
    expect(widgetEl().querySelector(".artwork")).toBeNull();
  });

  test("a non-string widget_config field cannot crash the renderer", async () => {
    await boot();
    send(track());
    send({ type: "widget_config", data: { theme: 7, layout: {}, fontFamily: ["x"] } });
    expect(widgetEl().textContent).toContain("Howl at the Moon");
  });
});

describe("hostile input", () => {
  test("malformed JSON and unknown types are ignored", async () => {
    await boot();
    send(track());
    send("{not json");
    send("[]");
    send({ type: "teleport", data: {} });
    send({ type: "now_playing", data: null });
    send({ type: "now_playing", data: { track: 1, artist: "x" } });
    send({ type: "progress", data: { elapsed: "NaN", duration: 1, isPlaying: true } });
    expect(widgetEl().textContent).toContain("Howl at the Moon");
  });

  test("an oversized frame is ignored", async () => {
    await boot();
    send(track({ track: "x".repeat(70 * 1024) }));
    expect(widgetEl().textContent).not.toContain("xxxxxxxx");
    expect(widgetEl().classList.contains("placeholder")).toBe(true);
  });

  test.each([
    "javascript:alert(1)",
    "data:image/svg+xml,<svg/>",
    "http://example.com/a.jpg",
    "//example.com/a.jpg",
    "not a url",
    'https://user:pw@example.com/a.jpg',
  ])("hostile artwork URL is rejected: %s", async (url) => {
    await boot();
    send(track({ artworkURL: url }));
    expect(widgetEl().querySelector("img.artwork")).toBeNull();
    // Falls back to the WolfWave mark.
    expect(widgetEl().querySelector("div.artwork svg")).not.toBeNull();
    expect(widgetEl().innerHTML).not.toContain("javascript:");
  });

  test("a quote in the artwork URL cannot break out of the attribute", async () => {
    await boot();
    send(track({ artworkURL: 'https://example.com/a.jpg" onerror="boom()' }));
    expect(widgetEl().querySelector("[onerror]")).toBeNull();
    const blur = widgetEl().querySelector(".blur-layer");
    if (blur) expect(blur.getAttribute("style")).not.toContain('" onerror');
  });

  test("queue_upcoming titles are escaped", async () => {
    await boot("?queueTicker=1");
    send({
      type: "queue_upcoming",
      data: { items: [{ title: "<b>x</b>", requesterUsername: "<i>y</i>" }] },
    });
    const ticker = document.getElementById("queue-ticker") as HTMLElement;
    expect(ticker.querySelector("b")).toBeNull();
    expect(ticker.querySelector("i")).toBeNull();
  });
});

describe("websocket", () => {
  test("connects to the default port", async () => {
    await boot();
    expect(socket().url).toBe("ws://localhost:8765");
  });

  test("?port= is honored when valid", async () => {
    await boot("?port=9001");
    expect(socket().url).toBe("ws://localhost:9001");
  });

  test.each(["abc", "0", "65536", "99999", "-1", "80/evil", "1e3", "123456", " 80"])(
    "invalid port %p falls back to 8765",
    async (port) => {
      await boot("?port=" + encodeURIComponent(port));
      expect(socket().url).toBe("ws://localhost:8765");
    },
  );

  test("reconnects after close with a bounded, jittered delay", async () => {
    await boot();
    const first = socket();
    first.onclose?.();
    expect(timers).toHaveLength(1);
    // attempt 1: base 1000ms * (0.75..1.25)
    expect(timers[0].delay).toBeGreaterThanOrEqual(750);
    expect(timers[0].delay).toBeLessThanOrEqual(1250);
    timers[0].fire();
    expect(FakeWebSocket.instances).toHaveLength(2);
  });

  test("backoff never exceeds 10 seconds", async () => {
    await boot();
    for (let i = 0; i < 12; i++) {
      socket().onclose?.();
      const t = timers.at(-1)!;
      expect(t.delay).toBeLessThanOrEqual(10_000);
      t.fire();
    }
    expect(timers.at(-1)!.delay).toBeGreaterThanOrEqual(7_500);
  });

  test("close clears the card", async () => {
    await boot();
    send(track());
    await settle();
    expect(widgetEl().classList.contains("widget-visible")).toBe(true);
    socket().onclose?.();
    expect(widgetEl().classList.contains("widget-visible")).toBe(false);
  });

  test("a throwing WebSocket constructor schedules a retry", async () => {
    FakeWebSocket.throwOnConstruct = true;
    await boot();
    expect(FakeWebSocket.instances).toHaveLength(0);
    expect(timers).toHaveLength(1);
    FakeWebSocket.throwOnConstruct = false;
    timers[0].fire();
    expect(FakeWebSocket.instances).toHaveLength(1);
  });
});
