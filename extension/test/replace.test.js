import { test } from "node:test";
import assert from "node:assert/strict";

// A pretend Chrome with a tab of three frames: frame 0 (top), 3 and 7. `focus` says which report hasFocus().
const noop = { addListener() {} };
let focus = [];
let replacedIn = [];
let frameResult = () => ({ ok: true, kind: "field" });
const FRAMES = [0, 3, 7];
const TAB = { id: 1, url: "https://example.com/", title: "Example" };
globalThis.chrome = {
  runtime: { onStartup: noop, onInstalled: noop, connectNative() { throw new Error("no host"); }, lastError: null },
  contextMenus: { onClicked: noop, create() {} },
  commands: { onCommand: noop },
  action: { setIcon() {}, setBadgeBackgroundColor() {}, setBadgeText() {}, setTitle() {} },
  storage: { local: { async get() { return {}; } } },
  tabs: { async query() { return [TAB]; } },
  scripting: {
    async executeScript({ target, func }) {
      if (func.name === "pageReplace") {
        assert.equal(target.allFrames, undefined, "replace must never run in all frames");
        replacedIn.push(...target.frameIds);
        return target.frameIds.map((frameId) => ({ frameId, result: frameResult(frameId) }));
      }
      assert.equal(target.allFrames, true);
      return FRAMES.map((frameId) => ({ frameId, result: focus.includes(frameId) }));
    },
  },
};
const { replaceSelection } = await import("../background.js");

test("replace runs only in the focused frame", async () => {
  focus = [3]; replacedIn = [];
  const r = await replaceSelection("old", "new");
  assert.deepEqual(replacedIn, [3]);
  assert.equal(r.ok, true);
});

test("with no frame focused (the Mac app in front) only the top frame is tried", async () => {
  focus = []; replacedIn = [];
  await replaceSelection("old", "new");
  assert.deepEqual(replacedIn, [0]);
});

test("ok only when a frame actually replaced", async () => {
  focus = [3]; replacedIn = [];
  frameResult = () => ({ ok: false, error: "the selection changed" });
  const r = await replaceSelection("old", "new");
  assert.equal(r.ok, false);
  assert.equal(r.error, "the selection changed");
  frameResult = () => null;
  assert.equal((await replaceSelection("old", "new")).ok, false);
});
