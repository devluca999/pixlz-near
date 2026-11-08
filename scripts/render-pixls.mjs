// Renders every Pixl's frames from the Claude Design pixel engine (design/explorations/c3,
// synced with the design project on 2026-11-08: C10 revisions) into indexed-colour JSON.
// No canvas, no PNGs: the engine's render() is pure, and the repo keeps PNGs in Git LFS.
//
//   node scripts/render-pixls.mjs              writes assets/<pet>/sprites.json for every pet
//   node scripts/render-pixls.mjs --swift      also writes the Swift embedding for the Mac app
//
// Frame names are the same for every pet (the app's motion code depends on them):
//   <slot>_0…2 for the nine behavior slots (SPEC §3.1), emotion_<name> for the six emotions.
// Frogg keeps the hand-picked poses he shipped with; the others come straight from their C7
// behavior sheets and emotion sets.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const repo = fileURLToPath(new URL("../", import.meta.url));
const root = repo + "design/explorations/c3/";
const ctx = { console, Math, Object, Array, Uint8Array, Float32Array, Number, String, JSON, parseInt, isNaN, Infinity, Map, Set };
ctx.window = ctx;
ctx.document = { createElement() { throw new Error("DOM not available in the exporter"); } };
vm.createContext(ctx);
for (const f of ["engine.js", "pets-a.js", "pets-b.js", "pets-c.js", "pets-d.js", "pets-e.js", "pets-f.js", "pets-g.js",
                 "behavior.js", "pets-h.js", "pets-i.js", "pets-j.js"]) {
  vm.runInContext(readFileSync(root + f, "utf8"), ctx, { filename: f });
}
const X = ctx.PX3;
export const PETS = ["frogg", "cat", "shiba", "ghost", "widow"];
const SLOT = { "Idle": "idle", "Move": "move", "Rest": "rest", "Poke": "poke", "Grab": "grab", "File ride": "file_ride",
               "Perch / climb": "perch", "Signature": "signature", "Mischief": "mischief" };

// Frogg: the poses he shipped with (hand-picked from his C7 sheet; grab_2 kept for the old splat
// reaction, the motion code no longer uses it).
const fr = (o) => Object.assign({ v: "F" }, o);
const FROGG = {
  idle_0: fr({ eyes: "half", mouth: "line" }),
  idle_1: fr({ eyes: "closed", head: { rot: 5 } }),
  idle_2: fr({ eyes: "smug", throat: 0.7, head: { dy: -1 } }),
  move_0: "coiled", move_1: "hop", move_2: { v: "side", rot: 9 },
  poke_0: fr({ eyes: "low", head: { dy: 3, rot: -5 } }),
  poke_1: fr({ eyes: "half", look: [1.4, -1.4], head: { rot: -8 } }),
  poke_2: fr({ eyes: "smug", throat: 1, mouth: "smile", head: { dy: -2, rot: -3 } }),
  rest_0: fr({ eyes: "closed", mouth: "yawn", head: { rot: -6, dy: -1 } }),
  rest_1: "sleep",
  rest_2: fr({ eyes: "closed", throat: 0.4, head: { rot: 12, dy: 2 } }),
  grab_0: { pose: { v: "hang", ph: 0 }, at: [36, 10] },
  grab_1: { pose: { v: "hang", ph: 1 }, at: [36, 10] },
  grab_2: fr({ splat: true, eyes: "half", mouth: "line", arms: "out" }),
  perch_2: fr({ eyes: "half", arms: "out" }),
  signature_0: fr({ eyes: "round", look: [1.8, -1], head: { rot: -6 } }),
  signature_1: "snap",
  signature_2: fr({ eyes: "closed", throat: 1, mouth: "smile" }),
};

/** name → { pose, at?, topPin? } for one pet. */
function posesFor(pet) {
  const out = {};
  if (pet === "frogg") {
    for (const [n, e] of Object.entries(FROGG)) out[n] = e && e.pose ? e : { pose: e };
    // the slots Frogg's table doesn't hand-pick come from his sheet, like everyone else's
  }
  for (const slot of X.sheets[pet]) {
    const key = SLOT[slot.slot];
    if (!key) throw new Error(`${pet}: unknown slot ${slot.slot}`);
    slot.frames.forEach((f, i) => {
      const name = `${key}_${i}`;
      if (out[name]) return;
      const p = f.pets.find((q) => q.k === pet);
      if (!p) throw new Error(`${pet}: ${name} has no ${pet} in it`);
      out[name] = { pose: p.pose, at: p.at, topPin: !!(p.top || p.pin), cap: f.cap };
    });
  }
  for (const [label, pose] of X.emotions[pet]) out["emotion_" + label.toLowerCase()] = { pose };
  return out;
}

const CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!#$%&()*+,-/:;<=>?@[]^_{|}~";

function renderPet(pet) {
  const p = X.pets[pet];
  const palette = [], index = new Map(), frames = {};
  for (const [name, entry] of Object.entries(posesFor(pet))) {
    const spr = Object.assign(p.build(entry.pose), { shadow: null });
    // auras are an FX-layer effect (SPEC §8), not sprite pixels: the design draws them over dark scenes
    if (Array.isArray(spr.parts)) spr.parts = spr.parts.filter((q) => q.m !== "aura");
    const r = X.render(spr, p.pal, { rim: p.rim, rimTop: p.rimTop });
    const [x0, y0, x1, y1] = X.cropBox(r, spr);
    const rows = [];
    for (let y = y0; y <= y1; y++) {
      let row = "";
      for (let x = x0; x <= x1; x++) {
        const g = r.G[y * r.W + x];
        if (!g) { row += "."; continue; }
        if (!index.has(g.c)) {
          if (palette.length >= CHARS.length) throw new Error(`${pet}: palette too large`);
          index.set(g.c, CHARS[palette.length]);
          palette.push(g.c);
        }
        row += index.get(g.c);
      }
      rows.push(row);
    }
    // cropBox pads transparent pixels: trim them so the feet are the bottom row
    let top = 0;
    while (rows.length && /^\.+$/.test(rows[0])) { rows.shift(); top++; }
    while (rows.length && /^\.+$/.test(rows[rows.length - 1])) rows.pop();
    if (!rows.length) throw new Error(`${pet}: ${name} rendered empty`);
    const opaqueCol = (i) => rows.some((row) => row[i] !== ".");
    let left = 0, right = rows[0].length - 1;
    while (!opaqueCol(left)) left++;
    while (!opaqueCol(right)) right--;
    const trimmed = rows.map((row) => row.slice(left, right + 1));
    const f = { w: right - left + 1, h: trimmed.length, rows: trimmed };
    // Pins: only the grab frames hang from the cursor (other frames' `at` anchors a prop).
    if (name.startsWith("grab_") && entry.at) {
      f.pin = [entry.at[0] - x0 - left, entry.at[1] - y0 - top];   // the pin in sprite pixels, moved into this frame
    } else if (name.startsWith("grab_") && entry.topPin) {
      // held by the scruff / pinched at the top: the middle of the body's top few rows
      const xs = [];
      for (let y = 0; y < Math.min(6, f.h); y++) for (let x = 0; x < f.w; x++) if (trimmed[y][x] !== ".") xs.push(x);
      xs.sort((a, b) => a - b);
      const x = xs[Math.floor(xs.length / 2)];
      let y = 0;
      while (y < f.h - 1 && trimmed[y][x] === ".") y++;
      f.pin = [x, y];
    }
    frames[name] = f;
  }
  return { source: `design/explorations/c3 (Claude Design C7–C10), rendered by scripts/render-pixls.mjs`,
           pet, name: p.name, species: p.species, transparent: ".", chars: CHARS.slice(0, palette.length), palette, frames };
}

const all = {};
for (const pet of PETS) {
  const data = renderPet(pet);
  all[pet] = data;
  mkdirSync(`${repo}assets/${pet}`, { recursive: true });
  writeFileSync(`${repo}assets/${pet}/sprites.json`, JSON.stringify(data, null, 1) + "\n");
  const ws = Object.values(data.frames).map((f) => f.w), hs = Object.values(data.frames).map((f) => f.h);
  console.error(`${pet}: ${Object.keys(data.frames).length} frames, ${data.palette.length} colours, max ${Math.max(...ws)}×${Math.max(...hs)}`);
}

if (process.argv.includes("--swift")) {
  let swift = "// Generated by scripts/render-pixls.mjs from the Claude Design pixel engine. Do not edit.\n" +
    "// Indexed-colour frames as JSON text (no PNGs: the repo keeps PNGs in Git LFS), and each\n" +
    "// Pixl's assets/<pet>/pixl.json.\n\n";
  swift += "let pixlSpriteJSON: [String: String] = [\n";
  for (const pet of PETS) {
    const json = JSON.stringify(all[pet]);
    if (json.includes('"##')) throw new Error("JSON would end the Swift raw string");
    swift += `    "${pet}": ##"""\n${json}\n"""##,\n`;
  }
  swift += "]\n\nlet pixlManifestJSON: [String: String] = [\n";
  for (const pet of PETS) {
    const m = readFileSync(`${repo}assets/${pet}/pixl.json`, "utf8").trim();
    if (m.includes('"##')) throw new Error("pixl.json would end the Swift raw string");
    swift += `    "${pet}": ##"""\n${m}\n"""##,\n`;
  }
  swift += "]\n\n/// The order the skin picker shows them in.\nlet pixlOrder = " + JSON.stringify(PETS) + "\n";
  writeFileSync(`${repo}macos/PixlMemory/Sources/PixlMemoryKit/PixlSpriteData.swift`, swift);
  console.error("wrote PixlSpriteData.swift");
}
