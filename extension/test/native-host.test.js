import { test } from "node:test";
import assert from "node:assert/strict";

// A pretend native host. `onPost` decides what the host does with each message the extension sends.
let ports = [];
let onPost = () => {};
let lastError = null;
let fetched = [];
function fakePort() {
  const msgL = [], discL = [];
  const port = {
    onMessage: { addListener: (f) => msgL.push(f) },
    onDisconnect: { addListener: (f) => discL.push(f) },
    postMessage: (m) => onPost(port, m),
    reply: (m) => msgL.forEach((f) => f(m)),
    die: () => discL.forEach((f) => f()),
  };
  return port;
}
let hostUp = true;
globalThis.chrome = {
  runtime: {
    connectNative() { if (!hostUp) throw new Error("no host"); const p = fakePort(); ports.push(p); return p; },
    get lastError() { return lastError; },
  },
  storage: { local: { async get() { return { token: "t", port: 7341 }; } } },
};
globalThis.fetch = async (url, init) => { fetched.push({ url, method: init.method }); return { ok: true, status: 200, json: async () => ({ via: "http" }) }; };
// Keep reconnect timers from firing during the test.
const timers = [];
const realSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = (fn, ms) => { if (ms >= 1000 && ms < 130_000) { timers.push(ms); return 0; } return realSetTimeout(fn, ms); };

const native = await import("../native.js");
const { api } = await import("../client.js");

test("backoff grows while the host keeps dying before it says anything, and resets once it answers", () => {
  timers.length = 0;
  for (let i = 0; i < 3; i++) { native.connect(); ports.at(-1).die(); }
  assert.deepEqual(timers, [2000, 4000, 8000]);
  native.connect();
  ports.at(-1).reply({ type: "status", ok: true });
  assert.equal(native._internals.retryMs(), 1000);
  ports.at(-1).die();
});

test("a POST sent before the host died is not resent over HTTP", async () => {
  fetched = [];
  onPost = (port) => port.die();
  await assert.rejects(api("/highlights", { method: "POST", body: { text: "x" } }), /closed mid-request/);
  assert.equal(fetched.length, 0);
});

test("a GET may still fall back to HTTP when the host dies", async () => {
  fetched = [];
  onPost = (port) => port.die();
  assert.deepEqual(await api("/folders"), { via: "http" });
  assert.equal(fetched.length, 1);
});

test("with no host at all, a POST goes over HTTP", async () => {
  fetched = [];
  hostUp = false;
  native.connect();  // port is null after the last die
  await api("/highlights", { method: "POST", body: { text: "x" } });
  assert.equal(fetched[0].method, "POST");
});
