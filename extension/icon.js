// Frogg, 16×16, drawn in code: the repo stores PNGs in Git LFS, and a clone
// without LFS would get a pointer file Chrome can't load as an icon.
// Colors from design/tokens: ink #1B2A1A, accent #7CD93A.

export const FROGG = [
  "................",
  "..RRR......RRR..",
  ".RRKRR....RRKRR.",
  ".RRRRGGGGGGRRRR.",
  "..GGGGGGGGGGGG..",
  ".GGGGGGGGGGGGGG.",
  "GGGGGGGGGGGGGGGG",
  "GGKKKKKKKKKKKKGG",
  "GGGGLLLLLLLLGGGG",
  ".GGLLLLLLLLLLGG.",
  ".GGLLLLLLLLLLGG.",
  "..GGGLLLLLLGGG..",
  ".OOGGGGGGGGGGOO.",
  "OOO..........OOO",
  "................",
  "................",
];

export const PALETTE = {
  R: [224, 49, 49],
  K: [27, 42, 26],
  G: [124, 217, 58],
  L: [214, 244, 186],
  O: [253, 126, 20],
};

/** RGBA pixels at an integer scale (nearest neighbour, as the pets are drawn). */
export function froggPixels(scale) {
  const n = 16 * scale;
  const data = new Uint8ClampedArray(n * n * 4);
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const c = PALETTE[FROGG[Math.floor(y / scale)][Math.floor(x / scale)]];
      if (!c) continue;
      const i = (y * n + x) * 4;
      data.set([...c, 255], i);
    }
  }
  return { width: n, height: n, data };
}

export function froggImageData(scale) {
  const { width, height, data } = froggPixels(scale);
  return new ImageData(data, width, height);
}
