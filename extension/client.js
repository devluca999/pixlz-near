// Talks to the local pixl-memory service. The token stays in chrome.storage.local
// (this browser profile only) and is sent only to 127.0.0.1.

export const DEFAULT_PORT = 7341;

export async function getSettings() {
  const { token = "", port = DEFAULT_PORT } = await chrome.storage.local.get(["token", "port"]);
  return { token, port: Number(port) || DEFAULT_PORT };
}

export async function api(path, { method = "GET", body } = {}) {
  const { token, port } = await getSettings();
  if (!token) throw new Error("no token: open the extension options");
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
