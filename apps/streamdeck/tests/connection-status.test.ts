import { describe, expect, test } from "bun:test";
import { connectionStatus } from "../src/connection-status.js";
import { initialState } from "../src/wolfwave/state.js";

/**
 * Covers the phase relayed to the Property Inspector. Pure, so no socket or
 * Stream Deck runtime is involved.
 */
describe("connectionStatus", () => {
  test("a refused handshake while disconnected reads as rejected", () => {
    expect(connectionStatus(initialState, true)).toEqual({
      type: "connection",
      phase: "rejected",
    });
  });

  test("a plain disconnect stays disconnected", () => {
    expect(connectionStatus(initialState, false).phase).toBe("disconnected");
  });

  // A stale rejection flag must not override a socket that is actually up.
  test("a live connection is never reported as rejected", () => {
    const live = { ...initialState, phase: "connected" as const };
    expect(connectionStatus(live, true).phase).toBe("connected");
  });
});
