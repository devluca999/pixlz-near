import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isReply, HOST } from "../native.js";

test("only replies to our own calls resolve pending requests", () => {
  assert.equal(isReply({ id: "x1", type: "api_result", ok: true }), true);
  assert.equal(isReply({ id: "app-1", type: "get_selection" }), false);   // a request from the app
  assert.equal(isReply({ type: "status", ok: true }), false);
  assert.equal(isReply({ id: 7, type: "api_result" }), false);
  assert.equal(isReply(null), false);
});

test("the manifest pins the extension ID and asks for native messaging", () => {
  const m = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url)));
  assert.ok(m.key && m.key.startsWith("MIIB"), "public key pins the ID the native host allows");
  assert.ok(m.permissions.includes("nativeMessaging"));
  assert.equal(HOST, "dev.pixlz.pixl_memory");
  assert.match(HOST, /^[a-z0-9_]+(\.[a-z0-9_]+)*$/);   // Chrome's host-name rule
});
