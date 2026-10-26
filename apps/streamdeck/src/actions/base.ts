/**
 * Shared behaviour for every WolfWave key.
 *
 * A key does two things: send a command on press and reflect live state. Both
 * are the same for every key apart from which token it sends and what it
 * renders, so subclasses override only that.
 */

import {
  SingletonAction,
  type KeyAction,
  type WillAppearEvent,
  type WillDisappearEvent,
} from "@elgato/streamdeck";
import { now } from "../clock.js";
import type { WolfWaveClient } from "../wolfwave/client.js";
import type { WolfWaveAction } from "../wolfwave/protocol.js";
import type { WolfWaveState } from "../wolfwave/state.js";

/**
 * The SDK's default settings type. SDK v3 dropped `KeyAction`'s default type
 * argument, so recover it from `SingletonAction`, whose default is unchanged.
 */
type DefaultSettings =
  SingletonAction extends SingletonAction<infer T> ? T : never;

/**
 * A key action with the SDK's default settings type. WolfWave keys carry no
 * per-key settings (see `WolfWaveKeyAction`).
 */
export type WolfWaveKey = KeyAction<DefaultSettings>;

/** Narrows a raw SDK event to a key action, or `undefined` for a dial. */
function asKeyAction(ev: { action: unknown }): WolfWaveKey | undefined {
  const action = ev.action as WolfWaveKey;
  if (typeof action?.isKey !== "function" || !action.isKey()) return undefined;
  return action;
}

/** Key state indices; must match the `States` array order in `manifest.json`. */
export const KeyState = {
  /** Default / off / paused. */
  primary: 0,
  /** Active / on / playing. */
  secondary: 1,
} as const;

/**
 * Not generic over a settings type: connection settings are global (one
 * WolfWave install serves every key), so no action carries per-key settings.
 */
export abstract class WolfWaveKeyAction extends SingletonAction {
  /** Unsubscribe handles for visible keys, so disappearing keys stop rendering. */
  private readonly subscriptions = new Map<string, () => void>();

  constructor(protected readonly client: WolfWaveClient) {
    super();
  }

  /**
   * Per-key paint generation. Bumped whenever a key is repainted, reset to its
   * offline art, or disappears, so a render suspended on an `await` can tell the
   * key moved on while it waited and must not install anything.
   */
  private readonly generations = new Map<string, number>();

  /** Press-start timestamps for keys that must be held. Keyed by action id. */
  private readonly pressStarts = new Map<string, number>();

  /**
   * The command this key sends on press. Return `null` to make the key
   * display-only.
   */
  protected abstract commandFor(state: WolfWaveState): WolfWaveAction | null;

  /**
   * Milliseconds this key must be held down before it fires. `0` (the default)
   * fires on press, which is what every reversible key wants.
   *
   * A key that throws something away and cannot undo it is a different case: a
   * deck is a grid of identical squares under a streamer's hand mid-broadcast,
   * and one wrong square should not delete everyone's requests.
   */
  protected get holdToConfirmMs(): number {
    return 0;
  }

  /**
   * Renders the key for the current state. The base class handles the
   * disconnected and outdated cases before this is called, so implementations
   * only deal with a live connection.
   */
  protected abstract render(
    action: WolfWaveKey,
    state: WolfWaveState,
  ): Promise<void> | void;

  override onWillAppear(ev: WillAppearEvent): void {
    const action = ev.action;
    if (!action.isKey()) return;

    // willAppear can fire again for the same action without an intervening
    // willDisappear — switching back to a profile, a device reconnecting, or a
    // missed willDisappear all do it. Overwriting the handle would strand the
    // previous listener in the client for the life of the process, and every
    // stranded one repaints the same key on every state change.
    this.subscriptions.get(action.id)?.();

    const unsubscribe = this.client.onState((state) => {
      void this.paint(action, state);
    });
    this.subscriptions.set(action.id, unsubscribe);
  }

  override onWillDisappear(ev: WillDisappearEvent): void {
    this.bumpGeneration(ev.action.id);
    const unsubscribe = this.subscriptions.get(ev.action.id);
    if (!unsubscribe) return;
    unsubscribe();
    this.subscriptions.delete(ev.action.id);
  }

  override async onKeyDown(ev: { action: unknown }): Promise<void> {
    const action = asKeyAction(ev);
    if (!action) return;

    if (this.holdToConfirmMs > 0) {
      // Nothing fires yet. The Stream Deck payload carries no press duration,
      // so the plugin has to time the gap between down and up itself.
      this.pressStarts.set(action.id, now());
      return;
    }
    await this.send(action);
  }

  override async onKeyUp(ev: { action: unknown }): Promise<void> {
    const action = asKeyAction(ev);
    if (!action) return;

    const startedAt = this.pressStarts.get(action.id);
    if (startedAt === undefined) return;
    this.pressStarts.delete(action.id);

    if (now() - startedAt < this.holdToConfirmMs) {
      // A tap on a hold key is the accident this exists to catch. Alert rather
      // than stay silent, or the streamer walks away believing it worked.
      await action.showAlert();
      return;
    }
    await this.send(action);
  }

  // MARK: - Subclass hooks

  /**
   * Called when a key leaves the live state (offline, bad token, outdated). A
   * subclass that runs its own timers stops them here, or they keep repainting
   * the last live frame over the "Offline" title.
   */
  protected onReset(_action: WolfWaveKey): void {}

  /**
   * Snapshot of the key's paint generation. Take it at the top of `render`, and
   * check {@link isStale} after each `await`.
   */
  protected generationOf(id: string): number {
    return this.generations.get(id) ?? 0;
  }

  /**
   * True when the key was repainted, reset, or removed since `generation` was
   * taken. A stale render must return without touching the key.
   */
  protected isStale(id: string, generation: number): boolean {
    return this.generationOf(id) !== generation;
  }

  // MARK: - Private helpers

  private bumpGeneration(id: string): void {
    this.generations.set(id, this.generationOf(id) + 1);
  }

  /** Sends this key's command and shows the ack's outcome on the key. */
  private async send(action: WolfWaveKey): Promise<void> {
    const command = this.commandFor(this.client.currentState);
    if (!command) return;

    const ack = await this.client.sendAwaitingAck(command);
    if (ack?.ok) {
      await action.showOk();
    } else {
      await action.showAlert();
    }
  }

  /**
   * Paints connection-level states centrally so no subclass can forget one —
   * a key that silently kept rendering its last-known title after WolfWave quit
   * would be actively misleading on stream.
   */
  private async paint(action: WolfWaveKey, state: WolfWaveState): Promise<void> {
    // Supersedes any render still suspended from an earlier state.
    this.bumpGeneration(action.id);
    switch (state.phase) {
      case "disconnected":
        await this.reset(action, "Offline");
        return;
      case "unauthorized":
        await this.reset(action, "Token?");
        return;
      case "outdated":
        await this.reset(action, "Update");
        return;
      case "connected":
        await this.render(action, state);
    }
  }

  /**
   * Drops a key back to its manifest art and says why.
   *
   * The `setImage()` with no argument matters: the keys that paint live art
   * would otherwise keep showing a queue count from before WolfWave quit,
   * under an "Offline" title, which reads as a live queue.
   */
  private async reset(action: WolfWaveKey, title: string): Promise<void> {
    this.onReset(action);
    await action.setImage();
    await action.setTitle(title);
    await action.setState(KeyState.primary);
  }
}
