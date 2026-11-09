// Pixl Memory: save the selection with a text-fragment backlink to the local service.
import { buildFragmentUrl, countOccurrences } from "./fragment.js";
import { api } from "./client.js";
import { froggImageData } from "./icon.js";
import { connect, onAppRequest } from "./native.js";
import { pageSelection, pageReplace } from "./page.js";

// Keep a port to the Mac app open (it also keeps this worker alive while the app is running).
connect();

const MENU_ID = "pixl-save";

function setIcon() {
  chrome.action.setIcon({ imageData: { 16: froggImageData(1), 32: froggImageData(2) } });
}
chrome.runtime.onStartup.addListener(() => { setIcon(); connect(); });

chrome.runtime.onInstalled.addListener(async () => {
  setIcon();
  chrome.contextMenus.create({ id: MENU_ID, title: "Save to Pixl Memory", contexts: ["selection"] });
  connect();
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === MENU_ID && tab?.id !== undefined) save(tab, info.selectionText);
});

chrome.commands.onCommand.addListener(async (command, tab) => {
  if (command === "save-selection" && tab?.id !== undefined) save(tab, null);
});

/**
 * Runs inside the page. Must be self-contained (it is serialized by executeScript).
 * Returns the selection plus the text right around it, for word trimming and
 * disambiguation, and how often its first words occur on the page.
 */
function readSelection() {
  const active = document.activeElement;
  if (active && (active.tagName === "TEXTAREA" || (active.tagName === "INPUT" && active.type === "text"))) {
    // Text inside form fields can't be targeted by a fragment link.
    const text = active.value.slice(active.selectionStart ?? 0, active.selectionEnd ?? 0);
    return { text, before: "", after: "", pageText: "", linkable: false };
  }
  const sel = window.getSelection();
  if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
  const range = sel.getRangeAt(0);
  const blockOf = (node) => {
    const el = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    return el?.closest("p,li,td,th,dd,dt,h1,h2,h3,h4,h5,h6,blockquote,pre,figcaption,article,section,div") || document.body;
  };
  const beforeRange = document.createRange();
  beforeRange.selectNodeContents(blockOf(range.startContainer));
  beforeRange.setEnd(range.startContainer, range.startOffset);
  const afterRange = document.createRange();
  afterRange.selectNodeContents(blockOf(range.endContainer));
  afterRange.setStart(range.endContainer, range.endOffset);
  return {
    text: sel.toString(),
    before: beforeRange.toString().slice(-120),
    after: afterRange.toString().slice(0, 120),
    pageText: document.body?.innerText ?? "",
    linkable: true,
  };
}

/**
 * Runs inside the page: a short description of it, for saving a page with nothing selected.
 * Self-contained (serialized by executeScript).
 */
function readSummary() {
  const meta = (n) => document.querySelector(`meta[name="${n}"],meta[property="${n}"]`)?.content?.trim();
  const lead = [...document.querySelectorAll("article p, main p, p")].map((p) => p.innerText.trim()).find((t) => t.length > 80);
  return (meta("og:description") || meta("description") || lead || "").slice(0, 600);
}

async function save(tab, fallbackText) {
  const r = await saveFrom(tab, fallbackText);
  if (r.ok) flash(tab.id, "✓", "#2f9e44", "Saved to Pixl Memory");
  else flash(tab.id, r.error === "nothing selected" ? "?" : "!", r.error === "nothing selected" ? "#888" : "#e03131",
             r.error === "nothing selected" ? "Select some text first" : `Not saved: ${r.error}`);
}

/**
 * Saves the selection in `tab` with a text-fragment backlink. With `wholePage`, a page with
 * nothing selected is saved too: its title, description and URL (the URL is the backlink).
 * `note` (the user's words) goes in front. Returns { ok, text, url, title, link } or { ok: false, error }.
 */
export async function saveFrom(tab, fallbackText, { wholePage = false, note = null } = {}) {
  let sel = null;
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readSelection });
    sel = res?.result ?? null;
  } catch {
    // chrome:// pages, the PDF viewer, the Web Store: no script access. Save the plain text.
  }
  let text = (sel?.text || fallbackText || "").trim();
  let pageOnly = false;
  if (!text && wholePage && /^https?:/.test(tab.url || "")) {
    let summary = "";
    try {
      const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readSummary });
      summary = res?.result || "";
    } catch { /* no script access: title and link only */ }
    text = [tab.title, summary].filter(Boolean).join(" — ") || tab.url;
    pageOnly = true;
  }
  if (!text) return { ok: false, error: "nothing selected" };
  if (note) text = `${note}\n\n${text}`;

  let fragmentUrl = null;
  if (!pageOnly && sel?.linkable && /^https?:/.test(tab.url || "")) {
    const firstWords = text.split(/\s+/).slice(0, 4).join(" ");
    fragmentUrl = buildFragmentUrl(tab.url, {
      text: sel.text,
      before: sel.before,
      after: sel.after,
      occurrences: countOccurrences(sel.pageText, firstWords),
    });
  }

  try {
    await api("/highlights", {
      method: "POST",
      body: { text, url: tab.url || null, title: tab.title || null, fragment_url: fragmentUrl,
              folder: (await chrome.storage.local.get("folder")).folder || null },
    });
    return { ok: true, text, url: tab.url || null, title: tab.title || null, link: fragmentUrl || tab.url || null };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

function flash(tabId, text, color, title) {
  chrome.action.setBadgeBackgroundColor({ tabId, color });
  chrome.action.setBadgeText({ tabId, text });
  chrome.action.setTitle({ tabId, title });
  setTimeout(() => {
    chrome.action.setBadgeText({ tabId, text: "" });
    chrome.action.setTitle({ tabId, title: "Pixl Memory" });
  }, 4000);
}

// ---- requests from the Mac app (Polish in web pages) ----

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

/** Runs `func` in every frame of the active tab and returns the first useful answer. */
async function inActiveTab(func, args = []) {
  const tab = await activeTab();
  if (!tab?.id || !/^(https?|file):/.test(tab.url || "")) return { ok: false, error: "no web page in front" };
  const results = await chrome.scripting.executeScript({ target: { tabId: tab.id, allFrames: true }, func, args });
  const hit = results.map((r) => r.result).find((r) => r && r.ok);
  return { ...(hit || results.map((r) => r.result).find(Boolean) || { ok: false, error: "nothing selected" }), url: tab.url, title: tab.title };
}

onAppRequest("get_selection", () => inActiveTab(pageSelection));
onAppRequest("replace_selection", (msg) => inActiveTab(pageReplace, [msg.original ?? "", msg.text ?? ""]));
/**
 * Runs inside the page: its readable text as blocks (headings, paragraphs, list items) in reading
 * order, so the Pixl can find "the part about …". Self-contained (serialized by executeScript).
 */
export function pageBlocks() {
  const root = document.querySelector("article, main, [role=main]") || document.body;
  if (!root) return { ok: false, error: "empty page" };
  const sel = "h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,dd,dt,figcaption,td";
  const blocks = [];
  let size = 0;
  for (const el of root.querySelectorAll(sel)) {
    if (el.querySelector(sel)) continue;            // a list item holding paragraphs: take the paragraphs
    if (el.closest("nav, footer, aside, [aria-hidden=true]")) continue;
    const t = (el.innerText || "").replace(/\s+/g, " ").trim();
    if (t.length < 2) continue;
    blocks.push(t);
    size += t.length;
    if (size > 300000) break;
  }
  return { ok: blocks.length > 0, text: blocks.join("\n\n"), error: blocks.length ? undefined : "no readable text" };
}

// "save this" said to the Pixl: the selection in the active tab, or the page itself, with a backlink.
onAppRequest("page_text", () => inActiveTab(pageBlocks));
onAppRequest("save_page", async (msg) => {
  const tab = await activeTab();
  if (!tab?.id || !/^(https?|file):/.test(tab.url || "")) return { ok: false, error: "no web page in front" };
  const r = await saveFrom(tab, null, { wholePage: true, note: msg.text || null });
  if (r.ok) flash(tab.id, "✓", "#2f9e44", "Saved to Pixl Memory");
  return r;
});
