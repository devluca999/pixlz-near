# app_game

The pure model: a Pixl's life on the Mosaico and touch. No drawing, network or hardware. Fixed
30 Hz updates; physics in art pixels times the whole-number `scale` (SPEC §4.5, §12.2). Poses are
in the order of `mosaico/tools/export_pets.py`'s frames, so a pose is also a frame index.

## Movement (pixl.json `movement`)

- **hop** (Frogg, Kiti, Mochi, Silky): hops along the floor, falls with gravity.
- **walk** (Slugg): crawls along the floor at `walk_speed` with its move frames.
- **float** (Boo): no gravity; hovers above the floor, bobs, glides anywhere; a throw coasts and
  stops where it slows down.

## Its own life

- Idle loop with a blink; now and then a short hop/crawl/glide (keeps the AMOLED from burning in).
- **Sleep:** 3 min without a touch → winds down, dozes, sleeps (Zz) until poked; naps of 2–4 min
  every 45–90 min. A poke wakes it startled.
- **Trick** (its signature) every 8–16 min, or from the menu; then proud.
- **Mischief** every 20–40 min, once nobody has touched it for a minute.
- **Voice:** greet on arrival, curious when picked up, annoyed after three quick pokes, sleepy
  when dozing off, sad when a trip fails, idle chatter every 1½–4 min (`app_game_take_say`).

## Touch

Tap = poke (at once); double-tap anywhere = `APP_GAME_REQUEST_MENU`; drag = pick up; release =
throw (walls and ceiling bounce); a fast throw across a side edge = clings there and
`APP_GAME_REQUEST_SEND_HOME`.

## Contracts

- One owner loop; no concurrent or ISR access. Requests and voice events are taken once.
- `pet_arrive`, `pet_leave`, `pet_shrug` follow the dock; `trick`, `nap`, `set_look` the menu.
- Host tests: `make -C tests` from the project root.
