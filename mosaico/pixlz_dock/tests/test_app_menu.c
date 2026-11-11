// Host tests for the app_menu state: `make -C tests`.
#include <stdio.h>
#include <string.h>
#include "../components/app_menu/include/app_menu.h"

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static void run(app_menu_handle_t m, int ticks) { for (int i = 0; i < ticks; i++) app_menu_update(m); }

static void tap(app_menu_handle_t m, int x, int y)
{
    CHECK(app_menu_pointer(m, x, y, true));
    app_menu_update(m);
    CHECK(app_menu_pointer(m, x, y, false));
}

static void swipe(app_menu_handle_t m, int x0, int x1)
{
    app_menu_pointer(m, x0, 240, true);
    for (int i = 1; i <= 4; i++) {
        app_menu_update(m);
        app_menu_pointer(m, x0 + (x1 - x0) * i / 4, 240, true);
    }
    app_menu_pointer(m, x1, 240, false);
}

static const app_menu_context_t CTX = {
    .can_send = true, .has_pet = true, .pet_index = 0, .pet_count = 6, .answers_count = 2, .memory_count = 3,
    .agents_connected = true, .can_swap = true,
};

// Six sessions; s0 and s5 wait on you (requests r0 and r5).
static app_menu_agent_row_t ROWS[6] = {
    {"s0", "r0"}, {"s1", ""}, {"s2", ""}, {"s3", ""}, {"s4", ""}, {"s5", "r5"},
};

static void test_pages(void)
{
    app_menu_handle_t m = app_menu_create(480, 480);
    CHECK(m && !app_menu_is_open(m));
    CHECK(!app_menu_pointer(m, 240, 240, true));   // closed: touches go to the Pixl
    app_menu_pointer(m, 240, 240, false);

    app_menu_open(m, &CTX);
    app_menu_snapshot_t s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_PAGE_1 && s.radius >= 55);
    CHECK(s.slots[0].bubble == APP_MENU_BUBBLE_SEND && s.slots[1].bubble == APP_MENU_BUBBLE_AGENTS);
    CHECK(s.slots[2].bubble == APP_MENU_BUBBLE_SWAP && s.slots[3].bubble == APP_MENU_BUBBLE_MORE);
    // Slots sit at the middle of each edge, fully on screen.
    CHECK(s.slots[0].x == 240 && s.slots[0].y - s.radius >= 0);
    CHECK(s.slots[1].y == 240 && s.slots[1].x + s.radius <= 480);
    CHECK(s.slots[2].x == 240 && s.slots[2].y + s.radius <= 480);
    CHECK(s.slots[3].y == 240 && s.slots[3].x - s.radius >= 0);
    // They pop in one after another.
    CHECK(s.slots[0].scale == 200 && s.slots[3].scale == 0);
    run(m, 20);
    s = app_menu_read(m);
    for (int i = 0; i < 4; i++) CHECK(s.slots[i].scale == 1000);

    // Page 1: Home · Agents · Swap · More. More → page 2 (Answers · Memory · Trick · More).
    CHECK(s.slots[1].bubble == APP_MENU_BUBBLE_AGENTS && s.slots[1].enabled);
    tap(m, s.slots[3].x, s.slots[3].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_2);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_ANSWERS && app_menu_read(m).slots[1].bubble == APP_MENU_BUBBLE_MEMORY);
    CHECK(app_menu_read(m).slots[2].bubble == APP_MENU_BUBBLE_TRICK && app_menu_read(m).slots[3].bubble == APP_MENU_BUBBLE_MORE);

    // Trick: an action, and the menu closes.
    tap(m, 240, s.slots[2].y);
    app_menu_action_t a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_TRICK && !app_menu_is_open(m));
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);

    // Send home; and Lock (Unlock when locked) on page 3 (More, More).
    app_menu_open(m, &CTX);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_SEND_HOME);
    app_menu_context_t locked = CTX;
    locked.locked = true;
    app_menu_open(m, &locked);
    tap(m, s.slots[3].x, s.slots[3].y);
    tap(m, s.slots[3].x, s.slots[3].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_3);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_UNLOCK);
    CHECK(app_menu_read(m).slots[1].bubble == APP_MENU_BUBBLE_EXIT && app_menu_read(m).slots[2].bubble == APP_MENU_BUBBLE_NONE);
    // Back from page 3 is page 2.
    tap(m, s.slots[3].x, s.slots[3].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_2);
    tap(m, s.slots[3].x, s.slots[3].y);
    tap(m, 240, s.slots[0].y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_LOCK && a.arg == 0);

    // Exit asks first: red stays (back to page 3), green leaves.
    app_menu_open(m, &CTX);
    tap(m, s.slots[3].x, s.slots[3].y);
    tap(m, s.slots[3].x, s.slots[3].y);
    tap(m, s.slots[1].x, s.slots[1].y);
    app_menu_snapshot_t e = app_menu_read(m);
    CHECK(e.mode == APP_MENU_EXIT);
    tap(m, 240, 240);   // not a button: nothing
    CHECK(app_menu_read(m).mode == APP_MENU_EXIT && app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);
    tap(m, e.cancel_x, e.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_3 && app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);
    tap(m, s.slots[1].x, s.slots[1].y);
    tap(m, e.confirm_x, e.buttons_y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_EXIT && !app_menu_is_open(m));

    // Greyed out (no Mac): a tap does nothing and the menu stays.
    app_menu_context_t no_mac = CTX;
    no_mac.can_send = false;
    app_menu_open(m, &no_mac);
    CHECK(!app_menu_read(m).slots[0].enabled);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE && app_menu_is_open(m));

    // The Pixl is away: Call takes Home's place (greyed when no Mac can hear it).
    app_menu_context_t away = CTX;
    away.has_pet = false;
    away.can_send = false;
    away.can_call = true;
    app_menu_open(m, &away);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_CALL && app_menu_read(m).slots[0].enabled);
    CHECK(app_menu_read(m).slots[1].enabled);   // Agents works without a Pixl here
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_CALL);
    away.can_call = false;
    app_menu_open(m, &away);
    CHECK(!app_menu_read(m).slots[0].enabled);
    // Its Mac is off but a copy is kept here: Bring takes Call's place.
    away.can_bring = true;
    app_menu_open(m, &away);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_BRING && app_menu_read(m).slots[0].enabled);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_BRING);
    away.can_call = true;   // a Mac is there to ask: Call wins
    app_menu_open(m, &away);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_CALL);
    app_menu_open(m, &no_mac);

    // A tap anywhere else closes it; so does 8 s without a touch.
    tap(m, 240, 240);
    CHECK(!app_menu_is_open(m));
    app_menu_open(m, &CTX);
    run(m, 8 * 30 - 5);
    CHECK(app_menu_is_open(m));
    run(m, 10);
    CHECK(!app_menu_is_open(m));
    app_menu_destroy(&m);
    CHECK(!m);
}

static void test_swap(void)
{
    app_menu_handle_t m = app_menu_create(480, 480);
    app_menu_context_t ctx = CTX;
    ctx.pet_index = 2;
    app_menu_open(m, &ctx);
    app_menu_snapshot_t s = app_menu_read(m);
    tap(m, s.slots[2].x, s.slots[2].y);
    s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_SWAP && s.pet_index == 2 && s.pet_count == 6);
    CHECK(s.cancel_x < 240 && s.confirm_x > 240 && s.button_radius >= 55);

    // Swipe left: the next Pixl slides in from the right and settles.
    swipe(m, 360, 200);
    s = app_menu_read(m);
    CHECK(s.pet_index == 3 && s.offset_x > 0);
    run(m, 30);
    CHECK(app_menu_read(m).offset_x == 0);
    // Swipe right: back. Wraps around past the first.
    swipe(m, 120, 300);
    CHECK(app_menu_read(m).pet_index == 2);
    swipe(m, 120, 300); swipe(m, 120, 300); swipe(m, 120, 300);
    CHECK(app_menu_read(m).pet_index == 5);
    // A short drag springs back; the carousel followed the finger meanwhile.
    app_menu_pointer(m, 240, 240, true);
    app_menu_update(m);
    app_menu_pointer(m, 270, 240, true);
    CHECK(app_menu_read(m).offset_x == 30);
    app_menu_pointer(m, 270, 240, false);
    CHECK(app_menu_read(m).pet_index == 5);
    run(m, 30);
    CHECK(app_menu_read(m).offset_x == 0);
    // Side arrows.
    tap(m, 30, 240);
    CHECK(app_menu_read(m).pet_index == 4);
    tap(m, 450, 240);
    CHECK(app_menu_read(m).pet_index == 5);

    // Green confirms the shown Pixl.
    s = app_menu_read(m);
    app_menu_pointer(m, s.confirm_x, s.buttons_y, true);
    CHECK(app_menu_read(m).pressed == 1);
    app_menu_pointer(m, s.confirm_x, s.buttons_y, false);
    app_menu_action_t a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_SWAP && a.arg == 5 && !app_menu_is_open(m));

    // Red cancels: no action.
    app_menu_open(m, &ctx);
    tap(m, s.slots[2].x, s.slots[2].y);
    swipe(m, 360, 200);
    app_menu_pointer(m, s.cancel_x, s.buttons_y, true);
    CHECK(app_menu_read(m).pressed == -1);
    app_menu_pointer(m, s.cancel_x, s.buttons_y, false);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE && !app_menu_is_open(m));

    // Sliding off a button cancels the press.
    app_menu_open(m, &ctx);
    tap(m, s.slots[2].x, s.slots[2].y);
    app_menu_pointer(m, s.confirm_x, s.buttons_y, true);
    app_menu_pointer(m, s.confirm_x, s.buttons_y - 150, true);
    app_menu_pointer(m, s.confirm_x, s.buttons_y - 150, false);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE && app_menu_is_open(m));
    app_menu_destroy(&m);

    // Only one Pixl: Swap is greyed out.
    m = app_menu_create(480, 480);
    app_menu_context_t one = CTX;
    one.pet_count = 1;
    app_menu_open(m, &one);
    CHECK(!app_menu_read(m).slots[2].enabled);
    app_menu_context_t away = CTX;
    away.can_swap = false;
    app_menu_open(m, &away);
    CHECK(!app_menu_read(m).slots[2].enabled);
    tap(m, app_menu_read(m).slots[2].x, app_menu_read(m).slots[2].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_1);
    app_menu_destroy(&m);
}

static void test_readers(void)
{
    app_menu_handle_t m = app_menu_create(480, 480);
    app_menu_open(m, &CTX);
    app_menu_snapshot_t s = app_menu_read(m);
    tap(m, s.slots[3].x, s.slots[3].y);      // More
    tap(m, 240, s.slots[0].y);               // Answers
    s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_ANSWERS && s.read_index == 0 && s.read_count == 2 && s.scroll == 0);
    // Drag up to scroll, as far as the text goes and no further.
    app_menu_set_read_extent(m, 600, 300);
    app_menu_pointer(m, 240, 400, true);
    app_menu_update(m);
    app_menu_pointer(m, 240, 250, true);
    CHECK(app_menu_read(m).scroll == 150);
    app_menu_pointer(m, 240, -200, true);
    CHECK(app_menu_read(m).scroll == 300);
    app_menu_pointer(m, 240, -200, false);
    CHECK(app_menu_read(m).mode == APP_MENU_ANSWERS);
    // Swipe for the next one (wraps); scroll starts over.
    swipe(m, 360, 200);
    s = app_menu_read(m);
    CHECK(s.read_index == 1 && s.scroll == 0);
    swipe(m, 360, 200);
    CHECK(app_menu_read(m).read_index == 0);
    // New counts while reading keep the index in range.
    swipe(m, 360, 200);
    app_menu_set_counts(m, 1, 3);
    CHECK(app_menu_read(m).read_index == 0 && app_menu_read(m).read_count == 1);
    // A tap goes back to page 2; Memory reads its own list.
    tap(m, 240, 240);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_2);
    tap(m, s.slots[1].x, s.slots[1].y);
    CHECK(app_menu_read(m).mode == APP_MENU_MEMORY && app_menu_read(m).read_count == 3);
    // Readers stay open longer than the bubbles, then close.
    run(m, 20 * 30);
    CHECK(app_menu_is_open(m));
    run(m, 11 * 30);
    CHECK(!app_menu_is_open(m));
    // Empty: still opens (the screen says how to fill it).
    app_menu_context_t empty = CTX;
    empty.answers_count = 0;
    app_menu_open(m, &empty);
    tap(m, s.slots[3].x, s.slots[3].y);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_read(m).mode == APP_MENU_ANSWERS && app_menu_read(m).read_count == 0);
    swipe(m, 360, 200);
    CHECK(app_menu_read(m).read_index == 0);
    app_menu_destroy(&m);
}

static void test_agents(void)
{
    app_menu_handle_t m = app_menu_create(480, 480);
    app_menu_context_t ctx = CTX;
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    app_menu_snapshot_t s = app_menu_read(m);
    tap(m, s.slots[1].x, s.slots[1].y);
    s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_AGENTS && s.agent_first == 0 && s.agent_count == 6);
    const int row = s.rows_y + s.row_h / 2;
    // A session that isn't waiting opens its chat; a tap there comes back.
    tap(m, 240, row + s.row_h);
    CHECK(app_menu_read(m).mode == APP_MENU_CHAT);
    (void)app_menu_take_action(m);
    tap(m, 240, 200);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    // Swipe for the next four; row 5 is the second there.
    swipe(m, 360, 200);
    CHECK(app_menu_read(m).agent_first == 4);
    swipe(m, 360, 200);   // no more: stays
    CHECK(app_menu_read(m).agent_first == 4);
    tap(m, 240, row + s.row_h);
    s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_AGENT && s.agent_first == 5);
    CHECK(strcmp(s.agent_id, "s5") == 0 && strcmp(s.agent_req, "r5") == 0);
    // Allow is greyed until pairing: nothing happens.
    tap(m, s.confirm_x, s.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENT && app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);
    // A tap elsewhere goes back to the list, on the same screen.
    tap(m, 240, 200);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS && app_menu_read(m).agent_first == 4);
    tap(m, 240, row + s.row_h);
    // Deny: an action naming the row.
    tap(m, s.cancel_x, s.buttons_y);
    app_menu_action_t a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_AGENT_DENY && a.arg == 5 && !app_menu_is_open(m));
    CHECK(strcmp(a.id, "s5") == 0 && strcmp(a.req, "r5") == 0);   // by id, not row
    // Answered elsewhere while open: back to the list.
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, s.slots[1].x, app_menu_read(m).slots[1].y);
    tap(m, 240, row);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENT);
    app_menu_agent_row_t moved[6];
    memcpy(moved, ROWS, sizeof moved);
    moved[0].req[0] = 0;
    app_menu_set_agents(m, moved, 6);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    // Rows move while a request is open: it follows its session.
    tap(m, 240, row);   // row 0 isn't waiting now: its chat
    (void)app_menu_take_action(m);
    tap(m, 240, 200);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, 240, row);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENT && strcmp(app_menu_read(m).agent_id, "s0") == 0);
    for (int i = 0; i < 6; i++) moved[i] = ROWS[5 - i];   // s0 is now the last row
    app_menu_set_agents(m, moved, 6);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENT && app_menu_read(m).agent_first == 5);
    CHECK(strcmp(app_menu_read(m).agent_id, "s0") == 0);
    // The same session with a new request: the one opened is gone, back to the list.
    snprintf(moved[5].req, sizeof moved[5].req, "r9");
    app_menu_set_agents(m, moved, 6);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    // The session gone altogether: also back.
    app_menu_set_agents(m, ROWS, 6);
    tap(m, 240, row);
    app_menu_set_agents(m, ROWS + 1, 5);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    app_menu_set_agents(m, ROWS, 6);
    // Tapping above the rows goes back to page 1.
    tap(m, 240, 20);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_1);
    // Paired with that Mac: Allow works.
    ctx.agents_paired = true;
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, s.slots[1].x, app_menu_read(m).slots[1].y);
    tap(m, 240, row);
    tap(m, s.confirm_x, s.buttons_y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_AGENT_ALLOW && a.arg == 0 && strcmp(a.id, "s0") == 0 && strcmp(a.req, "r0") == 0);
    ctx.agents_paired = false;

    // Pairing: the code screen stays until answered; red is no, green is yes.
    app_menu_open_pair(m);
    CHECK(app_menu_read(m).mode == APP_MENU_PAIR);
    for (int i = 0; i < 60 * 30; i++) app_menu_update(m);
    tap(m, 240, 240);
    CHECK(app_menu_read(m).mode == APP_MENU_PAIR && app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);
    tap(m, s.cancel_x, s.buttons_y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_PAIR && a.arg == 0 && !app_menu_is_open(m));
    app_menu_open_pair(m);
    tap(m, s.confirm_x, s.buttons_y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_PAIR && a.arg == 1);
    // Paired: Unpair on page 3.
    ctx.paired = true;
    app_menu_open(m, &ctx);
    tap(m, app_menu_read(m).slots[3].x, app_menu_read(m).slots[3].y);
    tap(m, app_menu_read(m).slots[3].x, app_menu_read(m).slots[3].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_3 && app_menu_read(m).slots[2].bubble == APP_MENU_BUBBLE_UNPAIR);
    tap(m, 240, app_menu_read(m).slots[2].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_UNPAIR);
    ctx.paired = false;

    // A session that isn't waiting opens its chat (asking the Mac for it, menu still open).
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, s.slots[1].x, app_menu_read(m).slots[1].y);
    tap(m, 240, row + s.row_h);   // row 1: not waiting
    app_menu_snapshot_t c = app_menu_read(m);
    CHECK(c.mode == APP_MENU_CHAT && c.agent_first == 1);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_AGENT_CHAT && a.arg == 1 && app_menu_is_open(m) && strcmp(a.id, "s1") == 0);
    CHECK(strcmp(c.agent_id, "s1") == 0);
    // No reply allowed: the green spot does nothing special, a tap goes back to the list.
    tap(m, c.confirm_x, c.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    tap(m, 240, row + s.row_h);
    (void)app_menu_take_action(m);
    app_menu_set_chat(m, true);
    tap(m, c.confirm_x, c.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_QUICK && app_menu_read(m).slots[3].bubble == APP_MENU_BUBBLE_Q3);
    tap(m, 240, 240);   // not a bubble: back to the chat
    CHECK(app_menu_read(m).mode == APP_MENU_CHAT && app_menu_read(m).agent_first == 1);
    tap(m, c.confirm_x, c.buttons_y);
    tap(m, app_menu_read(m).slots[3].x, app_menu_read(m).slots[3].y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_AGENT_REPLY && a.arg == 1 * 16 + 3 && !app_menu_is_open(m));
    CHECK(strcmp(a.id, "s1") == 0);
    // Quick replies only while the session still takes one: otherwise back to its chat.
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, s.slots[1].x, app_menu_read(m).slots[1].y);
    tap(m, 240, row + s.row_h);
    (void)app_menu_take_action(m);
    tap(m, c.confirm_x, c.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_QUICK);
    app_menu_set_chat(m, false);
    CHECK(app_menu_read(m).mode == APP_MENU_CHAT);
    // The Mac couldn't be asked: back to the list.
    app_menu_back_to_agents(m);
    CHECK(app_menu_read(m).mode == APP_MENU_AGENTS);
    // Dictation: hold the mic (bottom left) in a chat that takes replies, let go to send.
    app_menu_open(m, &ctx);
    app_menu_set_agents(m, ROWS, 6);
    tap(m, s.slots[1].x, app_menu_read(m).slots[1].y);
    tap(m, 240, row + s.row_h);
    (void)app_menu_take_action(m);
    app_menu_set_chat(m, true);
    CHECK(app_menu_pointer(m, c.cancel_x, c.buttons_y, true));
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_DICTATE_START && a.arg == 1);
    app_menu_pointer(m, c.cancel_x, c.buttons_y - 150, true);   // dragging while holding: no scroll
    CHECK(app_menu_read(m).mode == APP_MENU_CHAT);
    app_menu_pointer(m, c.cancel_x, c.buttons_y - 150, false);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_DICTATE_STOP && app_menu_is_open(m));
    // The transcript arrives: red goes back to the chat, green sends.
    app_menu_open_heard(m);
    CHECK(app_menu_read(m).mode == APP_MENU_HEARD && app_menu_read(m).agent_first == 1);
    tap(m, c.cancel_x, c.buttons_y);
    CHECK(app_menu_read(m).mode == APP_MENU_CHAT);
    app_menu_open_heard(m);
    tap(m, c.confirm_x, c.buttons_y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_DICTATE_SEND && !app_menu_is_open(m));
    app_menu_open_heard(m);   // not in a chat: ignored
    CHECK(!app_menu_is_open(m));
    app_menu_set_chat(m, false);

    // No Mac: Agents is greyed.
    ctx.agents_connected = false;
    app_menu_open(m, &ctx);
    CHECK(!app_menu_read(m).slots[1].enabled);
    app_menu_destroy(&m);
}

int main(void)
{
    test_agents();
    test_pages();
    test_swap();
    test_readers();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
