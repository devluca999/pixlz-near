# app_game

The pure model: Frogg's presence and motion on the Mosaico, and touch. No drawing, network or
hardware. Fixed 30 Hz updates; physics in art pixels times the whole-number `scale` (SPEC §4.5, §12.2).

## Phases

absent → **entering** (drops from above the top edge, lands with a squash) → **idle** (idle loop
with a blink every 2–5 s; a short hop along the floor every 10–20 s so nothing sits still on the
AMOLED) → **exiting** (crouch, big hop off the nearer side) → absent. **shrugging** after a failed trip.

## Touch

A tap is a press and release on the Pixl within ~270 ms and 12 px. It becomes
`APP_GAME_REQUEST_SEND_HOME` only after the 300 ms double-tap window passes with no second press
(spike behaviour, D17). A double-tap or a long press never sends.

## Contracts

- One owner loop; no concurrent or ISR access. `app_game_take_request` returns each request once.
- `pet_arrive`, `pet_leave` and `pet_shrug` are driven by the dock's events.
- Host tests: `make -C tests` from the project root.
