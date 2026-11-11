# app_menu

The small-screen menu (SPEC §11.2) and the Pixl swap carousel, as pure state: no drawing, no
hardware. One owner loop, 30 Hz `app_menu_update`.

## Behaviour

- **Open:** the runtime opens it on the model's `APP_GAME_REQUEST_MENU` (a double-tap anywhere).
- **Page 1** (top, right, bottom, left): Send home · Trick · Swap · More.
  **Page 2:** Lock/Unlock · Nap · (empty) · Back.
- Bubbles are 116 px circles (radius 58, so ≥ 110 px targets) at the middle of each edge,
  popping in one after another. Greyed bubbles (no Mac connected, no Pixl here, only one Pixl to
  swap to) ignore taps.
- A tap on a bubble acts (and closes the menu, except More/Back); a tap anywhere else closes it;
  so do 8 s without a touch.
- **Swap:** swipe left/right (≥ 60 px) or tap the side arrows to step through the Pixls (wraps);
  the new one slides in. Red ✕ cancels, green ✓ confirms (`APP_MENU_ACTION_SWAP`, arg = index).
  A press that slides off a button doesn't count. 30 s without a touch cancels.

## Contracts

- `app_menu_pointer` returns true when the menu used the touch; the runtime then keeps it from
  the Pixl.
- `app_menu_take_action` returns each action once.
- Host tests: `make -C tests` from the project root.
