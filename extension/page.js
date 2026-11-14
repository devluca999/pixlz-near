// Functions that run inside the page (chrome.scripting.executeScript serializes them, so each
// must be self-contained). They read the user's selection and replace it the way typing does.

/** The selected text in this frame, wherever it lives: a form field, a rich editor, Google Docs. */
export function pageSelection() {
  const field = (el) => el && (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|email|url)$/i.test(el.type)));
  const a = document.activeElement;
  if (field(a)) {
    const text = a.value.slice(a.selectionStart ?? 0, a.selectionEnd ?? 0);
    return text ? { ok: true, text, kind: "field" } : null;
  }
  // Google Docs draws text on a canvas: its copy handler (in the typing iframe) knows the selection.
  const docsFrame = document.querySelector("iframe.docs-texteventtarget-iframe");
  if (location.hostname === "docs.google.com" && docsFrame?.contentDocument) {
    const doc = docsFrame.contentDocument;
    let text = "";
    const grab = (e) => { text = e.clipboardData?.getData("text/plain") || ""; };
    doc.addEventListener("copy", grab);  // after Docs' own handler, which fills clipboardData
    try { doc.execCommand("copy"); } finally { doc.removeEventListener("copy", grab); }
    return text ? { ok: true, text, kind: "docs" } : null;
  }
  const sel = window.getSelection();
  const text = sel && !sel.isCollapsed ? sel.toString() : "";
  return text ? { ok: true, text, kind: "page" } : null;
}

/**
 * Replaces `original` with `text`. Only when it's safe: the selection still holds `original`,
 * or (in a form field) `original` occurs exactly once. Uses insertText so editors see a normal
 * input event (and the change can be undone).
 */
export function pageReplace(original, text) {
  const field = (el) => el && (el.tagName === "TEXTAREA" || (el.tagName === "INPUT" && /^(text|search|email|url)$/i.test(el.type)));
  const a = document.activeElement;
  if (field(a)) {
    let s = a.selectionStart ?? 0, e = a.selectionEnd ?? 0;
    if (a.value.slice(s, e) !== original) {
      const i = a.value.indexOf(original);
      if (i < 0 || a.value.indexOf(original, i + 1) >= 0) return { ok: false, error: "the original text changed" };
      s = i; e = i + original.length;
    }
    a.focus();
    a.setSelectionRange(s, e);
    if (!document.execCommand("insertText", false, text)) {
      a.setRangeText(text, s, e, "end");
      a.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: text }));
    }
    return { ok: a.value.slice(s, s + text.length) === text, kind: "field" };
  }
  const docsFrame = document.querySelector("iframe.docs-texteventtarget-iframe");
  if (location.hostname === "docs.google.com" && docsFrame?.contentDocument) {
    // Docs treats text inserted into its typing iframe as typing over the selection.
    const doc = docsFrame.contentDocument;
    let current = "";
    const grab = (ev) => { current = ev.clipboardData?.getData("text/plain") || ""; };
    doc.addEventListener("copy", grab);
    try { doc.execCommand("copy"); } finally { doc.removeEventListener("copy", grab); }
    if (current.trim() !== original.trim()) return { ok: false, error: "the selection in Docs changed" };
    const ok = doc.execCommand("insertText", false, text);
    return { ok, kind: "docs" };
  }
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || sel.toString() !== original) return { ok: false, error: "the selection changed" };
  const editable = (sel.anchorNode?.nodeType === 1 ? sel.anchorNode : sel.anchorNode?.parentElement)?.closest("[contenteditable=''],[contenteditable=true],[contenteditable=plaintext-only]");
  if (!editable) return { ok: false, error: "the selection isn't editable" };
  const ok = document.execCommand("insertText", false, text);
  return { ok, kind: "editable" };
}
