import { test } from "node:test";
import assert from "node:assert/strict";

// A pretend Chrome: no native host (so the token path is used), one tab, a page with or without a selection.
const posted = [];
let selection = null;
const noop = { addListener() {} };
globalThis.chrome = {
  runtime: { onStartup: noop, onInstalled: noop, connectNative() { throw new Error("no host"); }, lastError: null },
  contextMenus: { onClicked: noop, create() {} },
  commands: { onCommand: noop },
  action: { setIcon() {}, setBadgeBackgroundColor() {}, setBadgeText() {}, setTitle() {} },
  storage: { local: { async get() { return { token: "t", port: 7341 }; } } },
  tabs: { async query() { return [TAB]; } },
  scripting: {
    async executeScript({ func }) {
      if (func.name === "readSelection") return [{ result: selection }];
      if (func.name === "readSummary") return [{ result: "Glass frogs are frogs of the family Centrolenidae." }];
      return [{ result: null }];
    },
  },
};
globalThis.fetch = async (url, init) => { posted.push({ url, body: JSON.parse(init.body) }); return { ok: true, status: 201, json: async () => ({ id: "h1" }) }; };
const TAB = { id: 1, url: "https://en.wikipedia.org/wiki/Glass_frog", title: "Glass frog - Wikipedia" };
const { saveFrom } = await import("../background.js");

test("“save this” with nothing selected saves the page: title, description, and its URL as the backlink", async () => {
  selection = null; posted.length = 0;
  const r = await saveFrom(TAB, null, { wholePage: true, note: "frog research" });
  assert.equal(r.ok, true);
  assert.equal(r.link, TAB.url);
  assert.equal(posted[0].url, "http://127.0.0.1:7341/highlights");
  assert.equal(posted[0].body.text, "frog research\n\nGlass frog - Wikipedia — Glass frogs are frogs of the family Centrolenidae.");
  assert.equal(posted[0].body.fragment_url, null);
});

test("with a selection it saves the passage with a text-fragment link to it", async () => {
  selection = { text: "translucent skin", before: "have ", after: " on", pageText: "they have translucent skin on the belly", linkable: true };
  posted.length = 0;
  const r = await saveFrom(TAB, null, { wholePage: true });
  assert.equal(r.ok, true);
  assert.equal(posted[0].body.text, "translucent skin");
  assert.match(r.link, /#:~:text=translucent%20skin$/);
});

test("the old right-click save still needs a selection", async () => {
  selection = null;
  assert.deepEqual(await saveFrom(TAB, null), { ok: false, error: "nothing selected" });
});
