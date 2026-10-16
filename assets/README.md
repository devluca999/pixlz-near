# Runtime assets

One folder per Pixl (D6):

```
assets/<pixl>/
  pixl.json              species, canvas size, fps per slot, foot anchor, hitbox, aura, movement type
  <slot>.png             3 frames side by side: anticipation → action → reaction
  emotions/<emotion>.png front view
```

Slots: `idle, move, rest, poke, grab, file_ride, perch, signature, mischief`.
Emotions: `happy, annoyed, sleepy, startled, curious, proud`.

Frames face right; the engine mirrors them for left. Whole-number scaling only, nearest-neighbor.
PNGs are stored with Git LFS. Sprites are rendered from the design source in `design/explorations/c3/` (P6).
