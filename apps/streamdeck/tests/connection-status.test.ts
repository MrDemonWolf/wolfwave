import { describe, expect, test } from "bun:test";
import { connectionStatus } from "../src/connection-status.js";
import { initialState } from "../src/wolfwave/state.js";

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

  test("a live connection is never reported as rejected", () => {
    const live = { ...initialState, phase: "connected" as const };
    expect(connectionStatus(live, true).phase).toBe("connected");
  });
});
