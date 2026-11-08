import { api, getSettings } from "./client.js";
import { froggImageData } from "./icon.js";

const $ = (id) => document.getElementById(id);
$("frogg").getContext("2d").putImageData(froggImageData(2), 0, 0);

function host(url) {
  try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return ""; }
}

function render(highlights) {
  const list = $("list");
  list.replaceChildren();
  $("empty").hidden = highlights.length > 0;
  for (const h of highlights) {
    const li = document.createElement("li");
    const quote = document.createElement("blockquote");
    quote.textContent = h.text.length > 220 ? h.text.slice(0, 220) + "…" : h.text;
    li.append(quote);

    const meta = document.createElement("div");
    meta.className = "meta";
    const link = h.fragment_url || h.url;
    if (link) {
      const a = document.createElement("a");
      a.href = link;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = h.title || host(h.url) || "Open";
      a.title = h.fragment_url ? "Reopen the page at this passage" : link;
      meta.append(a);
    } else {
      meta.append(document.createTextNode(h.title || "Saved text"));
    }
    const del = document.createElement("button");
    del.textContent = "Delete";
    del.className = "link danger";
    del.onclick = async () => {
      try { await api(`/highlights/${encodeURIComponent(h.id)}`, { method: "DELETE" }); li.remove(); }
      catch (e) { $("status").textContent = e.message; }
    };
    meta.append(del);
    li.append(meta);
    list.append(li);
  }
}

let timer;
async function load() {
  const q = $("q").value.trim();
  try {
    const data = await api(`/highlights?limit=30${q ? `&q=${encodeURIComponent(q)}` : ""}`);
    render(data.highlights);
    $("status").textContent = "Saved on this Mac, encrypted.";
  } catch (e) {
    $("status").textContent = e.message;
    render([]);
    $("empty").hidden = true;
  }
}

$("q").addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(load, 200); });

const { token } = await getSettings();
if (!token) {
  $("status").innerHTML = 'Not connected. Open <a href="options.html" target="_blank">Settings</a>.';
} else {
  load();
}
