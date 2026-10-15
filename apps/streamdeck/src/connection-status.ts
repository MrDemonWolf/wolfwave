/**
 * What the Property Inspector is told about the connection.
 *
 * The panel can only validate the token's *shape*. Whether WolfWave accepted it
 * is known only here, so the plugin relays it. Kept apart from `plugin.ts`
 * (which connects at import time) so it can be unit tested.
 */

import type { WolfWaveState } from "./wolfwave/state.js";

/** Message sent to the Property Inspector via `sendToPropertyInspector`. */
export type ConnectionStatus = {
  type: "connection";
  /** `rejected` is a `disconnected` socket that WolfWave answered with a refusal. */
  phase: "connected" | "disconnected" | "unauthorized" | "outdated" | "rejected";
};

/**
 * Builds the message for the Property Inspector.
 *
 * @param handshakeRejected - WolfWave answered the handshake with a refusal.
 *   Only reported while disconnected; a live connection always reports its phase.
 */
export function connectionStatus(
  state: WolfWaveState,
  handshakeRejected: boolean,
): ConnectionStatus {
  if (state.phase === "disconnected" && handshakeRejected) {
    return { type: "connection", phase: "rejected" };
  }
  return { type: "connection", phase: state.phase };
}
