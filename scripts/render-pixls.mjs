// Renders every Pixl's frames from the Claude Design pixel engine (design/explorations/c3,
// synced with the design project on 2026-11-09: C8–C15) into indexed-colour JSON.
// No PNGs: the repo keeps PNGs in Git LFS. A tiny pixel-buffer canvas stands in for the DOM
// canvas the pond board draws on.
//
//   node scripts/render-pixls.mjs              writes assets/<pet>/sprites.json for every pet
//                                              (and assets/frogg/pond.json, the pond layers), each
//                                              pet's alternate skins (C15) into its pixl.json
//                                              (a palette, or sprites_<skin>.json when the shape changes)
//   node scripts/render-pixls.mjs --swift      also writes the Swift embedding for the Mac app
//   node scripts/render-pixls.mjs --review DIR contact sheets (PPM) of the frames to review
//
// Frame names (the app's motion code depends on them):
//   <slot>_0…2 for the nine behavior slots (SPEC §3.1), emotion_<name> for the six emotions, blink;
//   locomotion loops (C13): walk_0…7, trot_0…5, climb_0…5 (Nox), trot_0…5 (Mochi),
//   crawl_0…7 and ceiling_0…5 (Slugg; each with _body and _shell layers for the shell lag);
//   pond_0…11 (Frogg in the pond, C14; composited between pond.json's layers with its masks).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { deflateRawSync } from "node:zlib";

const repo = fileURLToPath(new URL("../", import.meta.url));
const root = repo + "design/explorations/c3/";

// ---- a pixel-buffer canvas: fillStyle/fillRect, drawImage (source-over), getImageData
const parseColor = (c) => {
  if (typeof c !== "string") return [0, 0, 0, 255];
  if (c[0] === "#") {
    const h = c.length === 4 ? [...c.slice(1)].map((d) => d + d).join("") : c.slice(1, 7);
    const a = c.length === 9 ? parseInt(c.slice(7, 9), 16) : 255;
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), a];
  }
  const m = c.match(/rgba?\(([^)]+)\)/);
  if (m) { const v = m[1].split(",").map(parseFloat); return [v[0], v[1], v[2], Math.round((v[3] ?? 1) * 255)]; }
  return [0, 0, 0, 255];
};
class Canvas {
  constructor() { this._w = 0; this._h = 0; this.data = new Uint8ClampedArray(0); this.style = {}; }
  get width() { return this._w; } set width(v) { this._w = v; this.data = new Uint8ClampedArray(v * this._h * 4); }
  get height() { return this._h; } set height(v) { this._h = v; this.data = new Uint8ClampedArray(this._w * v * 4); }
  toDataURL() { return ""; }
  getContext() {
    const c = this;
    // any drawing call the boards make that the exporter doesn't need is a no-op
    const noop = () => {}, grad = { addColorStop: noop };
    return new Proxy({
      canvas: c, fillStyle: "#000", globalAlpha: 1, imageSmoothingEnabled: false, font: "", strokeStyle: "#000", lineWidth: 1,
      fillRect(x, y, w, h) {
        const [r, g, b, a] = parseColor(this.fillStyle);
        for (let j = Math.max(0, Math.floor(y)); j < Math.min(c._h, Math.floor(y + h)); j++)
          for (let i = Math.max(0, Math.floor(x)); i < Math.min(c._w, Math.floor(x + w)); i++) {
            const k = (j * c._w + i) * 4; c.data[k] = r; c.data[k + 1] = g; c.data[k + 2] = b; c.data[k + 3] = a;
          }
      },
      clearRect(x, y, w, h) { for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) if (i >= 0 && j >= 0 && i < c._w && j < c._h) c.data.fill(0, (j * c._w + i) * 4, (j * c._w + i) * 4 + 4); },
      drawImage(src, dx, dy) {
        for (let j = 0; j < src._h; j++) for (let i = 0; i < src._w; i++) {
          const s = (j * src._w + i) * 4; if (src.data[s + 3] < 128) continue;
          const x = Math.round(dx) + i, y = Math.round(dy) + j; if (x < 0 || y < 0 || x >= c._w || y >= c._h) continue;
          const d = (y * c._w + x) * 4; c.data[d] = src.data[s]; c.data[d + 1] = src.data[s + 1]; c.data[d + 2] = src.data[s + 2]; c.data[d + 3] = 255;
        }
      },
      getImageData(x, y, w, h) {
        const out = new Uint8ClampedArray(w * h * 4);
        for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) { const s = ((y + j) * c._w + x + i) * 4, d = (j * w + i) * 4; for (let k = 0; k < 4; k++) out[d + k] = c.data[s + k]; }
        return { data: out, width: w, height: h };
      },
      measureText: () => ({ width: 0 }), createLinearGradient: () => grad, createRadialGradient: () => grad, createPattern: () => null,
    }, { get: (t, k) => (k in t ? t[k] : noop), set: (t, k, v) => { t[k] = v; return true; } });
  }
}
const fakeEl = () => new Proxy({ style: {}, children: [], append() {}, appendChild() {}, setAttribute() {}, addEventListener() {}, classList: { add() {} } },
  { get: (t, k) => (k in t ? t[k] : () => {}), set: (t, k, v) => { t[k] = v; return true; } });
const ctx = { console, Math, Object, Array, Uint8Array, Uint8ClampedArray, Float32Array, Number, String, JSON, parseInt, parseFloat, isNaN, Infinity, Map, Set, Proxy };
ctx.window = ctx;
ctx.document = { createElement: (t) => (t === "canvas" ? new Canvas() : fakeEl()), getElementById: () => fakeEl(), querySelector: () => fakeEl(),
                 querySelectorAll: () => [], head: fakeEl(), body: fakeEl(), documentElement: fakeEl() };
ctx.getComputedStyle = () => ({ getPropertyValue: () => "" });
ctx.requestAnimationFrame = () => 0; ctx.setTimeout = () => 0; ctx.setInterval = () => 0; ctx.addEventListener = () => {};
vm.createContext(ctx);
// the boards' load order: pets-l (Nox rebuild, gait engine) before pets-j; Slugg's pets-k then pets-m
for (const f of ["engine.js", "pets-a.js", "pets-b.js", "pets-d.js", "pets-f.js", "pets-g.js", "behavior.js", "pets-h.js", "pets-i.js",
                 "pets-l.js", "pets-j.js", "glass.js", "ui-kit.js", "pets-k.js", "pets-m.js", "slugg-flex.js", "skins.js", "pond.js"]) {
  vm.runInContext(readFileSync(root + f, "utf8"), ctx, { filename: f });
}
const X = ctx.PX3;
export const PETS = ["frogg", "cat", "shiba", "ghost", "widow", "slugg"];
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
  // C13 locomotion loops (start and end on a contact pose, so they tile)
  const sway = (i, n) => 4 * Math.sin(2 * Math.PI * i / n);
  if (pet === "cat") {
    for (let i = 0; i < 8; i++) out[`walk_${i}`] = { pose: { v: "walk", t: i / 8, sway: sway(i, 8) } };
    for (let i = 0; i < 6; i++) out[`trot_${i}`] = { pose: { v: "trot", t: i / 6, sway: sway(i, 6) } };
    for (let i = 0; i < 6; i++) out[`climb_${i}`] = { pose: { v: "climb", t: i / 6, tail: "low", sway: sway(i, 6) * 0.5 } };   // the app turns it onto the wall
  }
  if (pet === "shiba") for (let i = 0; i < 6; i++) out[`trot_${i}`] = { pose: { v: "trot", t: i / 6 } };
  if (pet === "slugg") {
    // C11/C13 soft body (slugg-flex.js): each loop is built along a contact path and cropped to
    // one box for the whole loop (so the foot never jitters), with the point where it touches:
    // crawl 8 (two-step: the front stretches, then the back catches up), climb 8 (up a wall on
    // its right), under 6 (upside down beneath an edge), wrapin 8 (floor → wall, the head finds
    // the wall first), wrapout 8 (up a side and over the top: the head wraps first, the tail last).
    const F = X.sluggFlex, mkPath = X.sluggPath.mkPath, K = 1.05, KD = [12, 8], CX = 40, GB = 66;
    const fromC = ([x, y]) => [CX + (x - KD[0] - CX) / K, GB + (y - KD[1] - GB) / K];
    const flex = (kind, i) => {
      const c = F.SC[kind], q = Object.assign({ v: "side", cw: c.W, ch: c.H, s0: c.s0(i, c.n), D: c.D, corner: c.corner }, c.pose(i, c.n));
      if (c.fn) {   // the underside: the body sags between its two contact points
        const y0 = 26.5, sag = 5.5;
        q.path = (sT, sH) => { const pts = []; for (let s = 0; s <= 400; s += 1) { const f = (s - sT) / (sH - sT || 1), d = f > 0 && f < 1 ? Math.sin(Math.PI * f) * sag : 0; pts.push(fromC([300 - s * K, y0 + d * K])); } return mkPath(pts); };
      } else { const pts = c.path(); q.path = c.maxH ? mkPath(pts, { maxH: c.maxH() }) : pts; }
      return q;
    };
    // where it touches, in scene pixels (the edges drawn in slugg-flex.js): x or y may be null = the box's middle
    const touch = { crawl: [null, 85], climb: [87, null], under: [null, 27], inside: [161, 161], outside: [105, 79] };
    const loops = { crawl: "crawl", climb: "climb", under: "under", inside: "wrapin", outside: "wrapout" };
    for (const [kind, name] of Object.entries(loops)) {
      const c = F.SC[kind];
      for (let i = 0; i < c.n; i++) out[`${name}_${i}`] = { pose: flex(kind, i), layers: true, group: name, touch: touch[kind] };
    }
    // the Memory bubble: the shell swings open like a vault; Focus and hidden: tucks in and seals
    const sd = (o) => Object.assign({ v: "side" }, o);
    [[0, { sa: [20, 4] }], [0.5, { sa: [30, 20] }], [1, { sa: [8, -6], eyes: "happy", mouth: "grin" }]]
      .forEach(([v, ex], i) => { out[`vault_${i}`] = { pose: sd(Object.assign({ vault: v }, ex)) }; });
    [sd({ out: 0.26, st: 0.6, sa: [30, 16], eyes: "half" }), sd({ out: 0, st: 0, seal: 0.5 }), sd({ out: 0, st: 0, seal: 1 })]
      .forEach((q, i) => { out[`seal_${i}`] = { pose: q }; });
  }
  // blink: the exact idle pose with the eyes shut (spiders don't blink: half-lidded), so a
  // blink never shifts the body
  const idle = out.idle_0.pose;
  out.blink = { pose: Object.assign({ v: "F" }, typeof idle === "object" ? idle : {}, { eyes: pet === "widow" ? "half" : "closed" }) };
  if (pet === "widow") delete out.blink.pose.fore;  // both forelegs down while it rests its eyes
  return out;
}

const CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!#$%&()*+,-/:;<=>?@[]^_{|}~";

/// The opaque box of a render, [x0, y0, x1, y1] inclusive.
function opaqueBox(r) {
  let x0 = 1e9, y0 = 1e9, x1 = -1, y1 = -1;
  for (let i = 0; i < r.G.length; i++) if (r.G[i]) { const x = i % r.W, y = (i / r.W) | 0; x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
  return [x0, y0, x1, y1];
}

function renderPet(pet, variant) {
  const p = X.pets[variant || pet];
  const palette = [], index = new Map(), frames = {};
  const poses = posesFor(pet);
  const draw = (entry) => {
    const spr = Object.assign(p.build(entry.pose), { shadow: null });
    // auras are an FX-layer effect (SPEC §8), not sprite pixels: the design draws them over dark scenes
    if (Array.isArray(spr.parts)) spr.parts = spr.parts.filter((q) => q.m !== "aura");
    return { spr, r: X.render(spr, p.pal, { rim: p.rim, rimTop: p.rimTop }) };
  };
  // a loop shares one box: the union of its frames' pixels
  const groups = {};
  for (const entry of Object.values(poses)) {
    if (!entry.group) continue;
    const b = opaqueBox(draw(entry).r), g = groups[entry.group] || [1e9, 1e9, -1, -1];
    groups[entry.group] = [Math.min(g[0], b[0]), Math.min(g[1], b[1]), Math.max(g[2], b[2]), Math.max(g[3], b[3])];
  }
  for (const [name, entry] of Object.entries(poses)) {
    const { spr, r } = draw(entry);
    if (entry.group) {
      const [gx0, gy0, gx1, gy1] = groups[entry.group];
      const rows = [], lrows = { _body: [], _shell: [] };
      const pick = (G, x, y) => { const g = G[y * r.W + x]; if (!g) return "."; if (!index.has(g.c)) { if (palette.length >= CHARS.length) throw new Error(`${pet}: palette too large`); index.set(g.c, CHARS[palette.length]); palette.push(g.c); } return index.get(g.c); };
      const SHELL = new Set(["shell", "cave", "band", "lip", "seal", "hat", "gold", "tip", "visor", "stripe", "wing", "decal"]);
      const layers = entry.layers ? { _body: X.render(Object.assign({}, spr, { parts: spr.parts.filter((q) => !SHELL.has(q.m)) }), p.pal, { rim: p.rim, rimTop: p.rimTop }),
                                      _shell: X.render(Object.assign({}, spr, { parts: spr.parts.filter((q) => SHELL.has(q.m)) }), p.pal, { rim: p.rim, rimTop: p.rimTop }) } : {};
      for (let y = gy0; y <= gy1; y++) {
        let row = ""; for (let x = gx0; x <= gx1; x++) row += pick(r.G, x, y); rows.push(row);
        for (const k of Object.keys(layers)) { let lr = ""; for (let x = gx0; x <= gx1; x++) lr += pick(layers[k].G, x, y); lrows[k].push(lr); }
      }
      const w = gx1 - gx0 + 1, h = gy1 - gy0 + 1;
      // the touch point in frame pixels (edges: x = 0 is the left edge, y = h the bottom)
      const [tx, ty] = entry.touch || [null, null];
      const clamp = (v, hi) => Math.max(0, Math.min(hi, v));   // flush with the body when the line is a pixel past it
      const f = { w, h, rows, anchor: [tx == null ? w / 2 : clamp(tx - gx0, w), ty == null ? h / 2 : clamp(ty - gy0, h)] };
      frames[name] = f;
      for (const k of Object.keys(layers)) frames[name + k] = { w, h, rows: lrows[k], anchor: f.anchor };
      continue;
    }
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
    // Slugg's shell as its own layer (the app lags it behind the body), cropped exactly like the full frame
    if (entry.layers) {
      const SHELL = new Set(["shell", "band", "lip", "seal", "hat", "gold", "tip"]);
      for (const [suffix, keep] of [["_body", (q) => !SHELL.has(q.m)], ["_shell", (q) => SHELL.has(q.m)]]) {
        const part = Object.assign({}, spr, { parts: spr.parts.filter(keep) });
        const rr = X.render(part, p.pal, { rim: p.rim, rimTop: p.rimTop });
        const lr = [];
        for (let y = y0 + top; y < y0 + top + f.h; y++) {
          let row = "";
          for (let x = x0 + left; x <= x0 + right; x++) {
            const g = rr.G[y * rr.W + x];
            if (!g) { row += "."; continue; }
            if (!index.has(g.c)) { index.set(g.c, CHARS[palette.length]); palette.push(g.c); }
            row += index.get(g.c);
          }
          lr.push(row);
        }
        frames[name + suffix] = { w: f.w, h: f.h, rows: lr };
      }
    }
    // Pins: only the grab frames hang from the cursor (other frames' `at` anchors a prop).
    if (name.startsWith("grab_") && entry.at) {
      f.pin = [entry.at[0] - x0 - left, entry.at[1] - y0 - top];   // the pin in sprite pixels, moved into this frame
    } else if (name.startsWith("grab_")) {
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
  if (pet === "frogg") {
    // the pond draws whichever Frogg is worn: his above-water frames here, his under-water body in its layers
    const base = X.pets.frogg;
    X.pets.frogg = p;
    try { const pd = pondFrames(palette, index); Object.assign(frames, pd.sprites); ponds[variant || "frogg"] = pd.data; } finally { X.pets.frogg = base; }
  }
  return { source: `design/explorations/c3 (Claude Design C7–C14), rendered by scripts/render-pixls.mjs`,
           pet, name: p.name, species: p.species, transparent: ".", chars: CHARS.slice(0, palette.length), palette, frames };
}

// ---- C14 Frogg's pond: the sequence from pond.js, exported as layers + masks; Frogg's pose per
// frame becomes sprite frame pond_<i>, which the app draws live between the layers.
const pondSrc = readFileSync(root + "pond.js", "utf8");
const grab = (re) => { const m = pondSrc.match(re); if (!m) throw new Error("pond.js: " + re); return m[0]; };
const POND = vm.runInContext(`(() => { const P = PX3.pond, AX = P.AX, AY = P.AY, PC = [AX, AY - 2];
  ${grab(/const F = o => [^\n]*\n/)}${grab(/const SEQ = \[[\s\S]*?\n\];/)}
  ${grab(/const fxFor = \(f, key\) => \{[\s\S]*?\n\};/)}
  return { SEQ, fxFor }; })()`, ctx);
// how long each step shows (ms) and which steps loop while asleep (C14: 4 frames at 2 fps)
const POND_MS = [320, 220, 320, 420, 500, 500, 500, 500, 240, 220, 320, 480];
const POND_LOOP = [4, 7];
const ponds = {};   // "frogg" or the skin key → pond layers

function pondFrames(palette, index) {
  const P = X.pond, out = {}, pondData = { frames: [] };
  const col = (d, k) => "#" + [d[k], d[k + 1], d[k + 2]].map((v) => v.toString(16).padStart(2, "0")).join("").toUpperCase();
  const pal = [], pidx = new Map();
  const layer = (canvas) => {
    const d = canvas.data, rows = [];
    for (let y = 0; y < canvas.height; y++) {
      let row = "";
      for (let x = 0; x < canvas.width; x++) {
        const k = (y * canvas.width + x) * 4;
        if (d[k + 3] < 128) { row += "."; continue; }
        const c = col(d, k);
        if (!pidx.has(c)) { if (pal.length >= CHARS.length) throw new Error("pond palette too large"); pidx.set(c, CHARS[pal.length]); pal.push(c); }
        row += pidx.get(c);
      }
      rows.push(row);
    }
    return rows;
  };
  const merge = (...cs) => { const m = new Canvas(); m.width = P.PW; m.height = P.PH; const g = m.getContext("2d"); cs.forEach((c) => g.drawImage(c, 0, 0)); return m; };
  POND.SEQ.forEach(([title, , spec], i) => {
    const f = Object.assign({}, spec), fxk = typeof f.fx === "string" ? f.fx : null;
    if (fxk) f.fx = [];
    let r = P.frame(f, null);
    if (fxk) { f.fx = POND.fxFor(f, fxk); r = P.frame(f, null); }
    const L = r.L;
    // Frogg's pixels (above the water) say where his sprite sits: its box in pond space
    let x0 = P.PW, y0 = P.PH, x1 = -1, y1 = -1;
    for (let y = 0; y < P.PH; y++) for (let x = 0; x < P.PW; x++) if (L.above.data[(y * P.PW + x) * 4 + 3] >= 128) { x0 = Math.min(x0, x); x1 = Math.max(x1, x); y0 = Math.min(y0, y); y1 = Math.max(y1, y); }
    // the sprite frame: Frogg's above-water pixels, in his palette
    if (x1 >= 0) {
      const rows = [];
      for (let y = y0; y <= y1; y++) {
        let row = "";
        for (let x = x0; x <= x1; x++) {
          const k = (y * P.PW + x) * 4;
          if (L.above.data[k + 3] < 128) { row += "."; continue; }
          const c = col(L.above.data, k).toLowerCase();
          const key = [...index.keys()].find((q) => q.toLowerCase() === c) ?? c;
          if (!index.has(key)) { index.set(key, CHARS[palette.length]); palette.push(key); }
          row += index.get(key);
        }
        rows.push(row);
      }
      out[`pond_${i}`] = { w: x1 - x0 + 1, h: y1 - y0 + 1, rows };
    }
    const mask = [];
    for (let y = 0; y < P.PH; y++) { let row = ""; for (let x = 0; x < P.PW; x++) row += L.mask.data[(y * P.PW + x) * 4] > 128 ? "#" : "."; mask.push(row); }
    pondData.frames.push({ title, ms: POND_MS[i], behind: layer(merge(L.back, L.under, L.ring)), over: layer(merge(L.front, L.fx)),
                           mask, sprite: x1 >= 0 ? { frame: `pond_${i}`, x: x0, y: y0 } : null, bank: !!spec.bank });
  });
  Object.assign(pondData, { source: "design/explorations/c3/pond.js (C14), rendered by scripts/render-pixls.mjs",
    w: P.PW, h: P.PH, anchor: [P.AX, P.AY], loop: POND_LOOP, transparent: ".", chars: CHARS.slice(0, pal.length), palette: pal });
  return { sprites: out, data: pondData };
}

/// Pond layers are mostly empty: runs of 4+ of one char become "~<char><count>|" (the pond
/// palette never uses "~" or "|"). The app expands them.
function rlePond(d) {
  const rle = (row) => row.replace(/(.)\1{3,}/g, (m, c) => `~${c}${m.length}|`);
  return Object.assign({}, d, { encoding: "rle", frames: d.frames.map((f) => Object.assign({}, f,
    { behind: f.behind.map(rle), over: f.over.map(rle), mask: f.mask.map(rle) })) });
}

/// Alternate skins (C15): Default plus two per Pixl. Each is the base Pixl's builder with its own
/// palette, part tweaks and pixel pass (design/explorations/c3/skins.js). A skin that only
/// recolours becomes a palette (same frames, same chars); one that changes shape gets its own
/// frames file. Boo's two are combinations of the design's explorations, as chosen:
/// Veil = the lace veil pattern + the lantern and its glow; Glitch = the Starry night body + the glitch pass.
const byKey = (pet, key) => (X.skins[pet] || []).find((k) => k.key === key) || (() => { throw new Error(`no skin ${key}`); })();
function compose(pet, key, o) {
  const b = X.pets[pet];
  X.pets[key] = Object.assign({}, b, { name: b.name + " · " + o.name, pal: Object.assign({}, b.pal, o.pal || {}), rim: o.rim || b.rim,
    build: (q) => { const sp = b.build(q); if (!sp || !sp.parts) return sp; if (o.mod) o.mod(sp, q); if (o.post) sp.post = o.post; return sp; } });
  return Object.assign({ key }, o);
}
{
  const lace = byKey("ghost", "ghost_lace"), lantern = byKey("ghost", "ghost_lantern"), stars = byKey("ghost", "ghost_stars"), glitch = byKey("ghost", "ghost_glitch");
  X.skins.ghost.push(compose("ghost", "ghost_veil", { name: "Veil", acc: lantern.acc, rim: lace.rim, pal: Object.assign({}, lace.pal, lantern.pal), mod: lantern.mod, post: lace.post }));
  X.skins.ghost.push(compose("ghost", "ghost_glitchstars", { name: "Glitch", acc: glitch.acc, rim: glitch.rim, pal: Object.assign({}, stars.pal),
    post: (r, pal) => { stars.post(r, pal); glitch.post(r, pal); } }));
}
export const FINAL_SKINS = {
  frogg: ["frogg_toad", "frogg_dart"], cat: ["cat_tabby", "cat_siamese", "cat_sphynx"], shiba: ["shiba_wolf", "shiba_bt"],
  ghost: ["ghost_veil", "ghost_glitchstars"], widow: ["widow_tarantula", "widow_jumper"], slugg: ["slugg_dapper", "slugg_racer"],
};
const skinID = (pet, key) => ({ ghost_glitchstars: "glitch" }[key] || key.slice(pet.length + 1));
function renderSkins(pet, base) {
  const out = [];
  for (const key of FINAL_SKINS[pet]) {
    const sk = byKey(pet, key), id = skinID(pet, key);
    const v = renderPet(pet, key);
    // same shapes, recoloured: every base colour maps to exactly one skin colour
    const map = new Map();
    const same = Object.keys(base.frames).every((n) => {
      const a = base.frames[n], b = v.frames[n];
      if (!b || a.w !== b.w || a.h !== b.h) return false;
      for (let y = 0; y < a.h; y++) for (let x = 0; x < a.w; x++) {
        const ca = a.rows[y][x], cb = b.rows[y][x];
        if ((ca === ".") !== (cb === ".")) return false;
        if (ca === ".") continue;
        if (map.has(ca) && map.get(ca) !== cb) return false;
        map.set(ca, cb);
      }
      return true;
    });
    const entry = { id, name: sk.name.replace(/ · rare$/, ""), accent: sk.acc };
    if (same) entry.palette = [...base.chars].map((c, i) => (map.has(c) ? v.palette[v.chars.indexOf(map.get(c))] : base.palette[i]));
    else { entry.frames = `sprites_${id}.json`; writeFileSync(`${repo}assets/${pet}/sprites_${id}.json`, JSON.stringify(v, null, 1) + "\n"); }
    if (pet === "frogg") writeFileSync(`${repo}assets/frogg/pond_${id}.json`, JSON.stringify(rlePond(ponds[key])) + "\n");
    out.push(entry);
  }
  return out;
}

/// Writes the skins into the pet's pixl.json (ui.skins): Default first, then the alternates.
function writeSkins(pet, skins) {
  const f = `${repo}assets/${pet}/pixl.json`, m = JSON.parse(readFileSync(f, "utf8"));
  m.ui.skins = [{ id: "default", name: "Default", accent: m.ui.accent }, ...skins];
  writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
}

const all = {};
for (const pet of PETS) {
  const data = renderPet(pet);
  all[pet] = data;
  mkdirSync(`${repo}assets/${pet}`, { recursive: true });
  writeFileSync(`${repo}assets/${pet}/sprites.json`, JSON.stringify(data, null, 1) + "\n");
  if (pet === "frogg") writeFileSync(`${repo}assets/frogg/pond.json`, JSON.stringify(rlePond(ponds.frogg)) + "\n");
  const skins = renderSkins(pet, data);
  writeSkins(pet, skins);
  console.error(`${pet} skins: ` + skins.map((k) => `${k.id} (${k.palette ? "palette" : "frames"})`).join(", "));
  const ws = Object.values(data.frames).map((f) => f.w), hs = Object.values(data.frames).map((f) => f.h);
  console.error(`${pet}: ${Object.keys(data.frames).length} frames, ${data.palette.length} colours, max ${Math.max(...ws)}×${Math.max(...hs)}`);
}

if (process.argv.includes("--swift")) {
  let swift = "// Generated by scripts/render-pixls.mjs from the Claude Design pixel engine. Do not edit.\n" +
    "// Indexed-colour frames as JSON text (no PNGs: the repo keeps PNGs in Git LFS), and each\n" +
    "// Pixl's assets/<pet>/pixl.json.\n\n";
  // frames are raw-deflated and base64'd (2.3 MB of JSON → ~0.4 MB); PixlSprites.inflate reads them
  const packed = (json) => deflateRawSync(json, { level: 9 }).toString("base64");
  swift += "/// Each Pixl's frames: sprites.json, raw-deflated, base64.\nlet pixlSpriteJSON: [String: String] = [\n";
  for (const pet of PETS) swift += `    "${pet}": "${packed(JSON.stringify(all[pet]))}",\n`;
  swift += "]\n\nlet pixlManifestJSON: [String: String] = [\n";
  for (const pet of PETS) {
    const m = readFileSync(`${repo}assets/${pet}/pixl.json`, "utf8").trim();
    if (m.includes('"##')) throw new Error("pixl.json would end the Swift raw string");
    swift += `    "${pet}": ##"""\n${m}\n"""##,\n`;
  }
  swift += "]\n\n/// Alternate skins' frames (sprites_<skin>.json) by \"<pet>_<skin>\", raw-deflated, base64.\nlet pixlSkinSpriteJSON: [String: String] = [\n";
  for (const pet of PETS) {
    for (const key of FINAL_SKINS[pet]) {
      const k = skinID(pet, key), f = `${repo}assets/${pet}/sprites_${k}.json`;
      let json; try { json = JSON.stringify(JSON.parse(readFileSync(f, "utf8"))); } catch { continue; }   // a palette skin has no file
      swift += `    "${pet}_${k}": "${packed(json)}",\n`;
    }
  }
  swift += "]\n\n/// Frogg's pond (C14) for each of his skins (\"default\", \"toad\", …): layers, masks and timing,\n" +
    "/// run-length encoded, raw-deflated, base64.\nlet pixlPondJSON: [String: String] = [\n";
  swift += `    "default": "${packed(readFileSync(`${repo}assets/frogg/pond.json`, "utf8").trim())}",\n`;
  for (const key of FINAL_SKINS.frogg) { const k = skinID("frogg", key); swift += `    "${k}": "${packed(readFileSync(`${repo}assets/frogg/pond_${k}.json`, "utf8").trim())}",\n`; }
  swift += "]\n";
  swift += "\n/// The order the skin picker shows them in.\nlet pixlOrder = " + JSON.stringify(PETS) + "\n";
  writeFileSync(`${repo}macos/PixlMemory/Sources/PixlMemoryKit/PixlSpriteData.swift`, swift);
  console.error("wrote PixlSpriteData.swift");
}
