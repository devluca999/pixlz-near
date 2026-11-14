// Talks to the local pixl-memory service: through the Mac app's native host when it's installed
// (no token in the extension), else directly with a token pasted in the options page (kept in
// chrome.storage.local, this profile only, sent only to 127.0.0.1).
import { call } from "./native.js";

export const DEFAULT_PORT = 7341;

export async function getSettings() {
  const { token = "", port = DEFAULT_PORT } = await chrome.storage.local.get(["token", "port"]);
  return { token, port: Number(port) || DEFAULT_PORT };
}

export async function api(path, { method = "GET", body } = {}) {
  try {
    return await call(method, path, body);
  } catch (e) {
    // Fall back to HTTP only if nothing reached the service, or the call is a read. A write sent
    // before the host died may already have happened: resending could save it twice.
    if (e.message === "native host closed" && method !== "GET") {
      throw new Error("the Pixl Memory app closed mid-request: check whether it went through before retrying");
    }
    if (e.message !== "no native host" && e.message !== "native host closed") throw e;  // the host answered: its error is the real one
  }
  const { token, port } = await getSettings();
  if (!token) throw new Error("install the Pixl Memory app, or paste a token in the extension options");
  let res;
  try {
    res = await fetch(`http://127.0.0.1:${port}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch {
    throw new Error("Pixl Memory isn't running (make -C memory serve)");
  }
  if (res.status === 401) throw new Error("wrong token: copy it again from `pixl-memory token`");
  if (!res.ok) throw new Error(`service returned ${res.status}`);
  return res.status === 204 ? null : res.json();
}
