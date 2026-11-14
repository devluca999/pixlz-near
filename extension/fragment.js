// Text-fragment links (#:~:text=…), per https://wicg.github.io/scroll-to-text-fragment/
// Pure functions: no DOM, so they run under `node --test`.

const LONG_TEXT = 80;     // above this, use textStart,textEnd instead of the whole passage
const EDGE_WORDS = 4;     // words kept at each end of a long passage
const CONTEXT_WORDS = 3;  // words of prefix/suffix used to disambiguate

/** Percent-encode one fragment term. "-", "," and "&" are delimiters in the syntax. */
export function encodeTerm(s) {
  return encodeURIComponent(s).replace(/-/g, "%2D");
}

/** Collapse whitespace the way the matcher sees rendered text. */
export function normalize(s) {
  return (s || "").replace(/\s+/g, " ").trim();
}

const WORD_CHAR = /[\p{L}\p{N}_]/u;

/**
 * Drop a partial word at either end of the selection. Fragments only match at
 * word boundaries, so "ick brown fo" would never match "quick brown fox".
 * `before`/`after` are the characters just outside the selection.
 * Returns the trimmed term plus the context around *it*: what was cut off the
 * start joins `before`, what was cut off the end joins `after`, so a prefix or
 * suffix built from them sits right next to the term.
 */
export function splitSelection(text, before = "", after = "") {
  let t = text || "";
  let head = "";
  let tail = "";
  if (t && before && WORD_CHAR.test(before.slice(-1)) && WORD_CHAR.test(t[0])) {
    head = t.match(/^[\p{L}\p{N}_]+/u)[0];
    t = t.slice(head.length);
  }
  if (t && after && WORD_CHAR.test(after[0]) && WORD_CHAR.test(t.slice(-1))) {
    tail = t.match(/[\p{L}\p{N}_]+$/u)[0];
    t = t.slice(0, t.length - tail.length);
  }
  // Punctuation stranded at the edges (e.g. the "(" left after dropping "(aposemat")
  // adds nothing to the match and only makes it more fragile.
  const lead = t.match(/^[^\p{L}\p{N}]*/u)[0];
  t = t.slice(lead.length);
  const trail = t.match(/[^\p{L}\p{N}]*$/u)[0];
  t = t.slice(0, t.length - trail.length);
  return { text: normalize(t), before: before + head + lead, after: trail + tail + after };
}

export function trimPartialWords(text, before = "", after = "") {
  return splitSelection(text, before, after).text;
}

function firstWords(s, n) {
  return s.split(" ").slice(0, n).join(" ");
}

function lastWords(s, n) {
  const w = s.split(" ");
  return w.slice(Math.max(0, w.length - n)).join(" ");
}

/** Remove any existing fragment directive (":~:…") from a URL, keeping a normal #hash. */
export function stripDirective(url) {
  const i = url.indexOf(":~:");
  if (i === -1) return url;
  const base = url.slice(0, i);
  return base.endsWith("#") ? base.slice(0, -1) : base;
}

function terms(text) {
  if (text.length > LONG_TEXT && text.split(" ").length > EDGE_WORDS * 2) {
    return { start: firstWords(text, EDGE_WORDS), end: lastWords(text, EDGE_WORDS) };
  }
  return { start: text, end: null };
}

/**
 * The start term buildDirective puts in the link for this selection (null if nothing
 * linkable): count its occurrences on the page to fill `sel.occurrences`.
 */
export function startTerm(sel) {
  const { text } = splitSelection(sel.text || "", sel.before || "", sel.after || "");
  return text ? terms(text).start : null;
}

/**
 * Build the directive for a selection.
 *   sel.text       the selected text
 *   sel.before     text just before it (same block), for word trimming and prefix
 *   sel.after      text just after it
 *   sel.occurrences how many times the start term appears on the page (1 = unique)
 * Returns "text=…" or null when there is nothing linkable.
 */
export function buildDirective(sel) {
  const { text, before, after } = splitSelection(sel.text || "", sel.before || "", sel.after || "");
  if (!text) return null;
  const { start, end } = terms(text);

  const parts = [];
  // Prefix/suffix only when the start term isn't unique: they must sit right next to
  // the match, so adding them when not needed only adds ways to fail.
  if ((sel.occurrences ?? 1) > 1) {
    const prefix = lastWords(normalize(before), CONTEXT_WORDS);
    const suffix = firstWords(normalize(after), CONTEXT_WORDS);
    if (prefix) parts.push(encodeTerm(prefix) + "-");
    parts.push(encodeTerm(start));
    if (end) parts.push(encodeTerm(end));
    if (suffix) parts.push("-" + encodeTerm(suffix));
  } else {
    parts.push(encodeTerm(start));
    if (end) parts.push(encodeTerm(end));
  }
  return "text=" + parts.join(",");
}

/** Full link that reopens `url` scrolled to and highlighting the selection. */
export function buildFragmentUrl(url, sel) {
  const directive = buildDirective(sel);
  const base = stripDirective(url);
  if (!directive) return base;
  return base + (base.includes("#") ? ":~:" : "#:~:") + directive;
}

/** Count non-overlapping occurrences of `needle` in `haystack` (both normalized). */
export function countOccurrences(haystack, needle) {
  const h = normalize(haystack).toLowerCase();
  const n = normalize(needle).toLowerCase();
  if (!n) return 0;
  let count = 0;
  for (let i = h.indexOf(n); i !== -1; i = h.indexOf(n, i + n.length)) count++;
  return count;
}

export const _internals = { LONG_TEXT, EDGE_WORDS, firstWords, lastWords };
