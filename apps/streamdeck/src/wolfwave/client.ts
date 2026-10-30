/**
 * The plugin's single connection to WolfWave.
 *
 * One socket is shared by every key: the app broadcasts `queue_state` / `health`
 * to all connected clients, so opening a socket per action would multiply the
 * broadcast fan-out for no benefit. Actions subscribe to state changes and send
 * commands through this client.
 *
 * Reconnects with capped exponential backoff, because "WolfWave isn't running
 * yet" is the normal state when a Stream Deck boots before the Mac finishes
 * logging in.
 */

import WebSocket from "ws";
import { now } from "../clock.js";
import {
  encodeCommand,
  parseFrame,
  socketURL,
  tokenSubprotocol,
  type AckFrame,
  type WolfWaveAction,
  type ProgressData,
} from "./protocol.js";
import {
  initialState,
  reduce,
  withPhase,
  type WolfWaveState,
} from "./state.js";

export interface ClientSettings {
  port: number;
  token: string;
}

const RECONNECT_BASE_MS = 1_000;
const RECONNECT_MAX_MS = 30_000;

/**
 * How long a key waits for its ack before giving up and showing an alert.
 * Generous: `play_pause` and `skip` cross an Apple Event round trip, which is
 * slow when Music.app is busy.
 */
const ACK_TIMEOUT_MS = 5_000;

/**
 * How long a timed-out press stays "owed" an ack. A late ack normally lands
 * within seconds; an ack the app never sends must not poison every later press
 * of that key, so the debt expires.
 */
const LATE_ACK_TTL_MS = 30_000;

interface PendingAck {
  resolve: (ack: AckFrame | null) => void;
  timer: ReturnType<typeof setTimeout>;
  /**
   * Set when an ack for this action was swallowed as an earlier press's late
   * ack while this press was waiting. That ack may in fact have been this
   * press's, so if this press then times out it owes no new debt. Without it,
   * one never-answered press would swallow every following press's real ack
   * for as long as presses arrive inside the late-ack window.
   */
  forgiven?: boolean;
}

export class WolfWaveClient {
  private socket: WebSocket | null = null;
  private settings: ClientSettings | null = null;
  private state: WolfWaveState = initialState;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private attempt = 0;
  /** Set while `stop()` is in effect so a close event doesn't reconnect. */
  private stopped = true;

  private readonly stateListeners = new Set<(s: WolfWaveState) => void>();
  private progress: ProgressData | null = null;
  private readonly progressListeners = new Set<(progress: ProgressData | null) => void>();
  private readonly ackListeners = new Set<(a: AckFrame) => void>();
  /**
   * Keys awaiting an ack, bucketed by action token and resolved FIFO.
   *
   * The app's ack carries the action but no correlation id, so two keys bound to
   * the same action are matched in press order. That's the best available
   * correlation without a protocol change, and it's correct for the common case
   * of one key per action.
   */
  private readonly pendingAcks = new Map<string, PendingAck[]>();
  /**
   * Expiry times of presses that timed out, per action token.
   *
   * A timed-out press's ack can still arrive later. Without this it would be
   * handed to the *next* press of the same action, which would then show the
   * wrong outcome. Each late ack is swallowed against one entry here, so the
   * protocol is unchanged (the ack still has no correlation id).
   */
  private readonly lateAcks = new Map<string, number[]>();
  /**
   * True when the last handshake was answered with an HTTP rejection rather than
   * a refused connection: WolfWave is up but did not accept the token.
   */
  private rejected = false;
  private readonly rejectionListeners = new Set<() => void>();
  private readonly ackTimeoutMs: number;

  constructor(options: { ackTimeoutMs?: number } = {}) {
    this.ackTimeoutMs = options.ackTimeoutMs ?? ACK_TIMEOUT_MS;
  }

  // MARK: - Public API

  get currentState(): WolfWaveState {
    return this.state;
  }

  get currentProgress(): ProgressData | null {
    return this.progress;
  }

  onProgress(listener: (progress: ProgressData | null) => void): () => void {
    this.progressListeners.add(listener);
    return () => this.progressListeners.delete(listener);
  }

  onState(listener: (state: WolfWaveState) => void): () => void {
    this.stateListeners.add(listener);
    // Hand the new subscriber the current snapshot so a key added mid-session
    // renders correctly instead of waiting for the next broadcast.
    listener(this.state);
    return () => this.stateListeners.delete(listener);
  }

  /** Whether WolfWave answered the last handshake by rejecting the token. */
  get handshakeRejected(): boolean {
    return this.rejected;
  }

  /** Fires each time a handshake is rejected, even if the phase did not change. */
  onRejection(listener: () => void): () => void {
    this.rejectionListeners.add(listener);
    return () => this.rejectionListeners.delete(listener);
  }

  onAck(listener: (ack: AckFrame) => void): () => void {
    this.ackListeners.add(listener);
    return () => this.ackListeners.delete(listener);
  }

  /**
   * Points the client at a WolfWave install and connects.
   *
   * Safe to call repeatedly — settings that haven't changed are a no-op, so the
   * Property Inspector can push on every keystroke without thrashing the socket.
   *
   * The `!this.stopped` term is load-bearing: clearing the token calls `stop()`
   * but leaves the last settings cached, so re-entering the *same* token would
   * otherwise match the cache, return early, and never reconnect — leaving every
   * key on "Offline" until Stream Deck restarts.
   */
  configure(settings: ClientSettings): void {
    if (
      !this.stopped &&
      this.settings &&
      this.settings.port === settings.port &&
      this.settings.token === settings.token
    ) {
      return;
    }
    // A configuration change revokes the old authority synchronously. Do not
    // leave an authenticated socket usable until the zero-delay reconnect runs.
    this.clearTimer();
    this.closeSocket();
    this.flushPending();
    this.setProgress(null);
    this.setState(withPhase(this.state, "disconnected"));
    this.settings = settings;
    this.rejected = false;
    this.attempt = 0;
    this.stopped = false;
    this.reconnect(0);
  }

  /** Closes the socket and stops reconnecting. */
  stop(): void {
    this.stopped = true;
    this.clearTimer();
    this.closeSocket();
    this.flushPending();
    this.setProgress(null);
    this.setState(withPhase(this.state, "disconnected"));
  }

  /**
   * Sends a command. Returns false when there is no open socket, so the caller
   * can show an alert instead of silently dropping the key press.
   */
  send(action: WolfWaveAction, args?: Record<string, string>): boolean {
    if (this.socket?.readyState !== WebSocket.OPEN) return false;
    this.socket.send(encodeCommand(action, args));
    return true;
  }

  /**
   * Sends a command and resolves with its ack.
   *
   * Resolves `null` when there's no open socket, or when no ack arrives within
   * the ack timeout — both mean "show an alert", so the caller doesn't
   * need to tell them apart.
   */
  sendAwaitingAck(
    action: WolfWaveAction,
    args?: Record<string, string>,
  ): Promise<AckFrame | null> {
    if (!this.send(action, args)) return Promise.resolve(null);

    return new Promise<AckFrame | null>((resolve) => {
      const queue = this.pendingAcks.get(action) ?? [];
      const pending: PendingAck = {
        resolve,
        timer: setTimeout(() => {
          this.removePending(action, pending);
          if (!pending.forgiven) this.oweLateAck(action);
          resolve(null);
        }, this.ackTimeoutMs),
      };
      pending.timer.unref?.();
      queue.push(pending);
      this.pendingAcks.set(action, queue);
    });
  }

  // MARK: - Connection lifecycle

  private connect(): void {
    const settings = this.settings;
    if (!settings || this.stopped) return;

    // Retire any previous authority before validating replacement settings.
    this.closeSocket();

    const subprotocol = tokenSubprotocol(settings.token);
    if (!subprotocol) {
      // A malformed token can never succeed, so don't burn a reconnect loop on
      // it — surface it and wait for the Property Inspector to fix it.
      this.setState(withPhase(this.state, "unauthorized"));
      return;
    }

    const socket = new WebSocket(socketURL(settings.port), [
      subprotocol,
    ]);
    this.socket = socket;

    socket.on("message", (raw: WebSocket.RawData) => {
      this.handleMessage(raw.toString());
    });

    socket.on("open", () => {
      this.attempt = 0;
      this.rejected = false;
    });

    socket.on("close", () => {
      if (socket !== this.socket) return;
      this.socket = null;
      this.flushPending();
      this.setState(withPhase(this.state, "disconnected"));
      this.scheduleReconnect();
    });

    socket.on("error", (error: Error) => {
      // `ws` always follows an error with a close, which is where the reconnect
      // is scheduled. Handling it here too would double-schedule; this only
      // records *why*. An HTTP answer to the upgrade means the app is running
      // and refused us, which looks identical to "app not running" otherwise.
      if (/^Unexpected server response/.test(error?.message ?? "")) {
        this.rejected = true;
        for (const listener of this.rejectionListeners) listener();
      }
    });
  }

  private handleMessage(text: string): void {
    const frame = parseFrame(text);
    if (!frame) return;

    if (frame.kind === "ack") {
      this.resolvePending(frame);
      for (const listener of this.ackListeners) listener(frame);
    }

    const previous = this.state;
    this.setState(reduce(previous, frame));
    if (frame.kind === "now_playing" || frame.kind === "progress") {
      this.setProgress(frame.data);
    } else if (frame.kind === "playback_state" &&
      (!frame.data.track || frame.data.track !== previous.track || frame.data.artist !== previous.artist || frame.data.album !== previous.album)) {
      this.setProgress(null);
    }
  }

  /** Records that a press timed out and its ack may still arrive. */
  private oweLateAck(action: string): void {
    const list = this.lateAcks.get(action) ?? [];
    list.push(now() + LATE_ACK_TTL_MS);
    this.lateAcks.set(action, list);
  }

  /** Consumes one owed late ack for `action`; true when this ack was it. */
  private swallowLateAck(action: string): boolean {
    const list = this.lateAcks.get(action);
    if (!list) return false;
    const t = now();
    const live = list.filter((expiry) => expiry > t);
    const swallowed = live.length > 0;
    if (swallowed) live.shift();
    if (live.length === 0) this.lateAcks.delete(action);
    else this.lateAcks.set(action, live);
    return swallowed;
  }

  private resolvePending(ack: AckFrame): void {
    if (this.swallowLateAck(ack.action)) {
      // The swallowed ack may have been the oldest waiting press's own; if so
      // that press will time out, and must not start a new debt (cascade).
      const oldest = this.pendingAcks.get(ack.action)?.find((p) => !p.forgiven);
      if (oldest) oldest.forgiven = true;
      return;
    }
    const queue = this.pendingAcks.get(ack.action);
    const pending = queue?.shift();
    if (!pending) return;
    if (queue && queue.length === 0) this.pendingAcks.delete(ack.action);
    clearTimeout(pending.timer);
    pending.resolve(ack);
  }

  private removePending(action: string, pending: PendingAck): void {
    const queue = this.pendingAcks.get(action);
    if (!queue) return;
    const index = queue.indexOf(pending);
    if (index >= 0) queue.splice(index, 1);
    if (queue.length === 0) this.pendingAcks.delete(action);
  }

  /**
   * Fails every in-flight ack wait. Called when the socket drops so keys show
   * an alert immediately instead of sitting until their individual timeouts.
   */
  private flushPending(): void {
    for (const queue of this.pendingAcks.values()) {
      for (const pending of queue) {
        clearTimeout(pending.timer);
        pending.resolve(null);
      }
    }
    this.pendingAcks.clear();
    // A dropped socket takes its unanswered commands with it.
    this.lateAcks.clear();
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    const delay = Math.min(
      RECONNECT_BASE_MS * 2 ** this.attempt,
      RECONNECT_MAX_MS,
    );
    this.attempt += 1;
    this.reconnect(delay);
  }

  private reconnect(delayMs: number): void {
    this.clearTimer();
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delayMs);
    // Don't hold the plugin process open purely to retry a socket.
    this.reconnectTimer.unref?.();
  }

  private clearTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
  }

  private closeSocket(): void {
    if (!this.socket) return;
    const socket = this.socket;
    this.socket = null;
    // Drop handlers first: otherwise this deliberate close fires the `close`
    // handler and schedules a reconnect we're about to supersede.
    socket.removeAllListeners();
    // `ws` emits an asynchronous error when a CONNECTING handshake is aborted.
    // Keep one sink installed so that deliberate retirement cannot become an
    // unhandled EventEmitter `error` and terminate the Stream Deck plugin.
    socket.once("error", () => {});
    socket.close();
  }

  private setState(next: WolfWaveState): void {
    if (next === this.state) return;
    this.state = next;
    if (next.phase !== "connected") this.setProgress(null);
    for (const listener of this.stateListeners) listener(next);
  }

  private setProgress(progress: ProgressData | null): void {
    this.progress = progress;
    for (const listener of this.progressListeners) listener(progress);
  }
}
