# Captions and narration spec (Pixlz demo video)

From research into demo/launch-video practice (sources at the end). Tags: [DOC] a platform or
broadcaster spec; [3P] third-party tool measurements (they disagree); [OPINION] an editorial call.

## Narration captions (9:16, 1080×1920)

- **One phrase at a time, not word-by-word karaoke.** Show the whole sentence or clause; only the
  1–2 key words switch to the accent colour as they're spoken (`Frogg`, `flies`, `wallet`,
  `private AI on NEAR`, `The Pixlz`, …). Word-by-word reads as creator content, not a launch. [OPINION]
- 2–6 words, at most 2 lines, ≤ ~24 characters per line.
- **Inter SemiBold/Bold (600–700)**, sentence case, 64–72 px (~3.5 % of height), line height 1.15,
  tracking −1 %. (SF Pro's licence only covers Apple UI mockups, so not in a public video.) [DOC]
- White text; one accent for emphasis all video long (Pixlz green `#7CD93A`, or `#FFD84D`).
- **Pill, not stroke:** fill `rgba(12,12,14,0.72)`, radius 22 px, padding 18 × 30 px. ≥ 4.5:1.
- **As built (9:16):** the brief for the final cut asked for the reel look instead: 3 to 5 words
  at a time, bold white with a thin dark edge and a soft shadow, no pill, key words in green.
  Where a caption lies on a white page or on small print (M1, W1) it gets a dark patch behind it.
  Phrase starts come from `times` in `plan.json` (measured on the narration), not from guesses.
  The judges' cut keeps the pills.
- In: scale 0.94 → 1 and fade over 140 ms, ease-out `cubic-bezier(.2,.8,.2,1)`; out: 100 ms fade;
  keyword colour snaps over 80 ms at its onset.

## Placement (the pets must stay visible)

- Safe box for X / Reels / Shorts: x 90–890, y 300–1250. [3P] Caption ≤ 720 px wide, centred at
  x ≈ 500 (clears the right action rail).
- Two slots: **LOW** (centred at y ≈ 1180) by default, **HIGH** (y ≈ 400).
- Per scene: box the pet plus any card/bubble it pops (+80 px). The caption takes the slot that
  doesn't touch it. Pets low on the screen → HIGH; pets on title bars in the upper half → LOW.
- Switch slots only at cuts, never mid-phrase; never put a caption between a pet and its card;
  avoid flipping slots three beats in a row. (BBC/Ofcom: bottom by default, move only to avoid
  covering vital action.) [DOC]
- Zoom so a pet is 250–400 px tall in the 1080×1920 frame (crop ~540×960 Retina px, 2×).

## 16:9 judges' cut (1920×1080)

- Burned-in (README players have no caption track; many judges watch muted).
- Inter SemiBold 44 px, same pill (radius 16), bottom-centred, baseline 90 px above the bottom,
  ≤ 1300 px wide, ≤ 42 characters per line.
- GitHub attachments: 10 MB on free plans → 1080p at ~1 Mbps or 720p, or link out. [DOC]

## Narration and timing

- 140–160 words per minute; 40–60 s ≈ 70–110 words; one 5–9 word sentence per 4–6 s scene.
- **Silence for payoffs:** 0.8–1.5 s after each payoff (fly caught, card pops), SFX only, no caption.
- Captions verbatim with the VO: in 0–2 frames before the voice, out 150–250 ms after,
  ≥ 0.83 s on screen, 2-frame gaps, never across a cut.
- **Feature labels** are a separate layer: a small pixel-font chip (Silkscreen 32–36 px in 9:16,
  28 px in 16:9), top-left of the safe box (y ≈ 300) or pinned by the pet. They name the feature
  ("Highlights", "Agent watch"); they never repeat the VO. One per beat at most.

## Structure

- Every beat must work muted (X autoplays muted). One feature per 4–7 s beat: line → action →
  payoff (SFX + a beat of silence). 1.5–2.5× zooms over ~400 ms, still while reading.
- Music bed −24 to −28 LUFS under VO at ~−16 LUFS; soft SFX on payoffs only. (As built, 9:16: the
  track is the driver after the drop, so it sits 18 dB under the voice only while a line is spoken.)
- End card 2.5–3 s, static ≥ 2 s (it's the thumbnail).

## Sources

Safe zones: upload-post.com/tools/safe-zone-checker · reap.video/blog/short-form-video-safe-zones ·
bundle.social/tools/safe-zone-checker · revid.ai/tiktok-safe-zone. X vertical:
kapwing.com/resources/how-to-post-videos-on-x-in-2025-vertical-video-tab. Caption style:
opus.pro/blog/video-caption-design-placement · opus.pro/blog/tiktok-caption-subtitle-best-practices ·
blitzcutai.com/blog/best-caption-style-youtube-shorts-2026. BBC/Ofcom: clevercast.com/bbc-subtitling-guidelines ·
Ofcom access-services guideline (PDF). Netflix timed text (secondary): 3playmedia.com. Launch videos:
speedrun.substack.com/p/how-to-make-a-viral-launch-video · descript.com/blog/article/product-launch-videos.
GitHub limits: docs.github.com (attaching files). Pixel positions are picks inside the published
ranges: check with a test post on a phone before the final cut.
