// The bridge to the Mac app (Chrome native messaging → pixl-native-host).
// - Service calls go through the host, which holds the token: the extension never sees it.
// - The app asks for the active tab's selection, and to replace it (Polish in web pages).

export const HOST = "dev.pixlz.pixl_memory";

let port = null;
let nextId = 0;
const pending = new Map();
let appConnected = false;
let retryMs = 1000;
const handlers = {};

/** Pure: is this message a reply we're waiting for? (tested under node) */
export function isReply(msg) {
  return !!msg && typeof msg.id === "string" && !msg.id.startsWith("app-") && msg.type === "api_result";
}

export function onAppRequest(type, fn) {
  handlers[type] = fn;
}

export function status() {
  return { host: !!port, app: appConnected };
}

export function connect() {
  if (port) return port;
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch {
    port = null;
    return null;
  }
  port.onMessage.addListener(async (msg) => {
    retryMs = 1000;  // the host is really up (connectNative succeeds even when it then dies)
    if (isReply(msg)) {
      const p = pending.get(msg.id);
      if (p) { pending.delete(msg.id); p(msg); }
      return;
    }
    if (msg.type === "status") { appConnected = !!msg.ok; return; }
    const fn = handlers[msg.type];
    if (!fn) return;
    let reply;
    try {
      reply = await fn(msg);
    } catch (e) {
      reply = { ok: false, error: String(e?.message || e) };
    }
    const replyType = { get_selection: "selection", replace_selection: "replaced", save_page: "saved", page_text: "page" }[msg.type] || "reply";
    port?.postMessage({ id: msg.id, type: replyType, ...reply });
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || "";
    port = null;
    appConnected = false;
    for (const [, p] of pending) p({ ok: false, status: 0, error: "native host closed" });
    pending.clear();
    // "not found": the app isn't installed (or its host isn't registered). Back off.
    retryMs = /not found|forbidden/i.test(err) ? 60_000 : Math.min(retryMs * 2, 30_000);
    setTimeout(connect, retryMs);
  });
  return port;
}

/**
 * Calls the local service through the host. Rejects with "no native host" if nothing was sent,
 * "native host closed" if the host went away after the request was sent.
 */
export function call(method, path, body) {
  return new Promise((resolve, reject) => {
    const p = connect();
    if (!p) return reject(new Error("no native host"));
    const id = `x${++nextId}`;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("Pixl Memory didn't answer")); }, 130_000);
    pending.set(id, (msg) => {
      clearTimeout(timer);
      // Sent, then the host died: the service may have acted. Callers must not blindly resend.
      if (msg.status === 0 && msg.error === "native host closed") return reject(new Error("native host closed"));
      if (!msg.ok) return reject(new Error(msg.error || `service returned ${msg.status}`));
      resolve(msg.body ?? null);
    });
    p.postMessage({ id, type: "api", method, path, ...(body ? { body } : {}) });
  });
}

export const _internals = { retryMs: () => retryMs };
