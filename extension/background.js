// Pixl Memory: save the selection with a text-fragment backlink to the local service.
import { buildFragmentUrl, countOccurrences } from "./fragment.js";
import { api, getSettings } from "./client.js";
import { froggImageData } from "./icon.js";

const MENU_ID = "pixl-save";

function setIcon() {
  chrome.action.setIcon({ imageData: { 16: froggImageData(1), 32: froggImageData(2) } });
}
chrome.runtime.onStartup.addListener(setIcon);

chrome.runtime.onInstalled.addListener(async () => {
  setIcon();
  chrome.contextMenus.create({ id: MENU_ID, title: "Save to Pixl Memory", contexts: ["selection"] });
  const { token } = await getSettings();
  if (!token) chrome.runtime.openOptionsPage();
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

async function save(tab, fallbackText) {
  let sel = null;
  try {
    const [res] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readSelection });
    sel = res?.result ?? null;
  } catch {
    // chrome:// pages, the PDF viewer, the Web Store: no script access. Save the plain text.
  }
  const text = (sel?.text || fallbackText || "").trim();
  if (!text) return flash(tab.id, "?", "#888", "Select some text first");

  let fragmentUrl = null;
  if (sel?.linkable && /^https?:/.test(tab.url || "")) {
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
      body: { text, url: tab.url || null, title: tab.title || null, fragment_url: fragmentUrl },
    });
    flash(tab.id, "✓", "#2f9e44", "Saved to Pixl Memory");
  } catch (e) {
    flash(tab.id, "!", "#e03131", `Not saved: ${e.message}`);
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
