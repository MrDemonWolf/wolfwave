"use strict";

/**
 * Property Inspector for the WolfWave plugin.
 *
 * Talks Elgato's Property Inspector protocol directly (the
 * `connectElgatoStreamDeckSocket` global) rather than through a component
 * library, so the panel has no network dependency.
 *
 * Settings are *global*, not per-action: one WolfWave install serves every key,
 * so asking for the token once per key would be busywork.
 */

const DEFAULT_PORT = 8765;
/** Matches the app's 64-hex token (`WebSocketAuthToken.generate`). */
const TOKEN_PATTERN = /^[0-9a-fA-F]{64}$/;

let socket = null;
let uuid = null;
let settings = {};
/**
 * Last connection phase relayed by the plugin (`connected`, `disconnected`,
 * `rejected`, `outdated`, `unauthorized`), or `null` when unknown or stale. It is
 * cleared on every edit, because it describes the *old* token.
 */
let connection = null;
/** Settings signature last written by an as-you-type save, to avoid a double write. */
let autoSaved = null;

const fields = {
  token: document.getElementById("token"),
  port: document.getElementById("port"),
};
const status = document.getElementById("status");

/**
 * Stream Deck's Property Inspector entry point. Argument names and order are
 * fixed by Elgato; the app calls this global once the panel loads.
 */
globalThis.connectElgatoStreamDeckSocket = function (
  inPort,
  inUUID,
  inRegisterEvent,
  _inInfo,
  _inActionInfo,
) {
  uuid = inUUID;
  socket = new WebSocket(`ws://127.0.0.1:${inPort}`);

  socket.onopen = () => {
    send({ event: inRegisterEvent, uuid: inUUID });
    send({ event: "getGlobalSettings", context: inUUID });
  };

  socket.onmessage = (event) => {
    let payload;
    try {
      payload = JSON.parse(event.data);
    } catch {
      return;
    }
    if (payload.event === "sendToPropertyInspector") {
      const message = payload.payload;
      if (message?.type === "connection") {
        connection = message.phase ?? null;
        refreshStatus();
      }
      return;
    }
    if (payload.event !== "didReceiveGlobalSettings") return;
    settings = payload.payload?.settings ?? {};
    hydrate();
  };
};

function send(message) {
  if (socket?.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(message));
  }
}

function hydrate() {
  fields.token.value = settings.token ?? "";
  fields.port.value = settings.port ?? "";
  refreshStatus();
}

/**
 * Strictly parses a port.
 *
 * `Number.parseInt` is too lenient for a field that has to agree with
 * `readPort` in `src/plugin.ts`: it turns `123abc` into 123, `1.5` into 1, and
 * `1e3` into 1. Any of those would be persisted as a number the streamer never
 * typed. Digits only, or it isn't a port.
 *
 * Returns `null` for blank (meaning "use the default") and `undefined` for
 * invalid, so callers can tell the two apart.
 */
function parsePort(raw) {
  if (!raw) return null;
  if (!/^\d+$/.test(raw)) return undefined;
  const port = Number(raw);
  return port > 0 && port <= 65535 ? port : undefined;
}

/**
 * Validates the token and port and paints the single status line.
 *
 * Deliberately one function rather than one per field: there is only one status
 * element, so independent validators would overwrite each other's message and
 * leave a corrected field still showing its old error. Errors are reported
 * token-first because an unusable token blocks the connection outright, while a
 * bad port only falls back to the default.
 *
 * Local validation earns its keep because a bad token and a closed WolfWave
 * produce the same silent handshake rejection on the wire — without it, a typo
 * looks exactly like "the app isn't running".
 */
function refreshStatus() {
  const token = fields.token.value.trim();
  const tokenValid = TOKEN_PATTERN.test(token);
  if (!token) fields.token.removeAttribute("aria-invalid");
  else fields.token.setAttribute("aria-invalid", String(!tokenValid));

  const port = parsePort(fields.port.value.trim());
  const portValid = port !== undefined;
  fields.port.setAttribute("aria-invalid", String(!portValid));

  if (token && !tokenValid) {
    setStatus("That token isn't 64 hex characters.", false);
  } else if (!portValid) {
    setStatus("Port must be a whole number between 1 and 65535.", false);
  } else if (!token) {
    setStatus("Paste your control token to connect.", null);
  } else if (connection === "connected") {
    setStatus("Connected.", true);
  } else if (connection === "rejected") {
    // WolfWave answered and said no: a stale token after a rotation, or the
    // overlay token pasted by mistake. Without this it reads as "Offline".
    setStatus(
      "WolfWave rejected this token. Re-copy the Stream Deck Control Token from Settings → Stream Deck.",
      false,
    );
  } else if (connection === "outdated") {
    setStatus("Update the plugin.", false);
  } else {
    // Shape only. The app, not this panel, decides whether it is the right token.
    setStatus("Token format is valid.", true);
  }

  return { tokenValid, port };
}

function setStatus(text, ok) {
  status.textContent = text;
  if (ok === null) status.removeAttribute("data-ok");
  else status.setAttribute("data-ok", String(ok));
}

/**
 * Persists the current field values.
 *
 * Sends unconditionally, including when the token is blank or malformed. Both
 * cases have to reach the plugin: a blank token is how it knows to disconnect,
 * and a malformed one is what puts the keys into their "Token?" state. Gating
 * the send on validity would strand the plugin on the last good token while the
 * panel showed something else.
 */
function save() {
  const { port } = refreshStatus();
  settings = {
    token: fields.token.value.trim(),
    // null (blank) and undefined (invalid) both fall back to the default, which
    // is what plugin.ts's readPort does with the same values.
    port: port ?? DEFAULT_PORT,
  };
  autoSaved = null;
  send({ event: "setGlobalSettings", context: uuid, payload: settings });
}

// `change` alone, not `change` + `blur`: a text field fires both when an edited
// value loses focus, which wrote settings twice per edit. `change` is the right
// one of the pair — it fires on commit (blur or Enter) and stays silent when the
// value didn't actually change.
/**
 * As-you-type handler. Once the token is a well-formed 64-hex string it is saved
 * straight away: a pasted token otherwise sat unsent until the field lost focus,
 * and the streamer saw "looks right" while every key still said Offline.
 * Incomplete values only revalidate, so a half-typed token is never persisted.
 */
function onTokenInput() {
  // Whatever the plugin last said described the previous value.
  connection = null;
  const token = fields.token.value.trim();
  if (!TOKEN_PATTERN.test(token)) {
    refreshStatus();
    return;
  }
  save();
  autoSaved = signature();
}

function signature() {
  return JSON.stringify([fields.token.value.trim(), fields.port.value.trim()]);
}

/** Commit handler: skips the write an as-you-type save already made. */
function onChange() {
  if (autoSaved !== null && autoSaved === signature()) {
    autoSaved = null;
    return;
  }
  save();
}

/** Port edits only revalidate while typing: a save per digit would reconnect per digit. */
function onPortInput() {
  connection = null;
  refreshStatus();
}

for (const field of Object.values(fields)) {
  field.addEventListener("change", onChange);
}
fields.token.addEventListener("input", onTokenInput);
fields.port.addEventListener("input", onPortInput);
