import { api, getSettings, DEFAULT_PORT } from "./client.js";

const $ = (id) => document.getElementById(id);
const settings = await getSettings();
$("token").value = settings.token;
$("port").value = settings.port;

$("save").onclick = async () => {
  const token = $("token").value.trim();
  const port = Number($("port").value) || DEFAULT_PORT;
  if (!/^[0-9a-f]{64}$/.test(token)) {
    $("result").textContent = "That doesn't look like a Pixl Memory token (64 hex characters).";
    return;
  }
  await chrome.storage.local.set({ token, port });
  $("result").textContent = "Testing…";
  try {
    const data = await api("/highlights?limit=1");
    $("result").textContent = `Connected. ${data.highlights.length ? "Highlights found." : "No highlights yet."}`;
  } catch (e) {
    $("result").textContent = e.message;
  }
};
