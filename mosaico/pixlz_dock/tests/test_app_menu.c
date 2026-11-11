// Host tests for the app_menu state: `make -C tests`.
#include <stdio.h>
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

static const app_menu_context_t CTX = {true, false, true, 0, 6};

static void test_pages(void)
{
    app_menu_handle_t m = app_menu_create(480, 480);
    CHECK(m && !app_menu_is_open(m));
    CHECK(!app_menu_pointer(m, 240, 240, true));   // closed: touches go to the Pixl
    app_menu_pointer(m, 240, 240, false);

    app_menu_open(m, &CTX);
    app_menu_snapshot_t s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_PAGE_1 && s.radius >= 55);
    CHECK(s.slots[0].bubble == APP_MENU_BUBBLE_SEND && s.slots[1].bubble == APP_MENU_BUBBLE_TRICK);
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

    // More → page 2 → Back → page 1.
    tap(m, s.slots[3].x, s.slots[3].y);
    s = app_menu_read(m);
    CHECK(s.mode == APP_MENU_PAGE_2 && s.slots[0].bubble == APP_MENU_BUBBLE_LOCK);
    CHECK(s.slots[1].bubble == APP_MENU_BUBBLE_NAP && s.slots[2].bubble == APP_MENU_BUBBLE_NONE);
    CHECK(s.slots[3].bubble == APP_MENU_BUBBLE_BACK);
    tap(m, s.slots[3].x, s.slots[3].y);
    CHECK(app_menu_read(m).mode == APP_MENU_PAGE_1);

    // Trick: an action, and the menu closes.
    tap(m, s.slots[1].x, s.slots[1].y);
    app_menu_action_t a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_TRICK && !app_menu_is_open(m));
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE);

    // Send home; and Lock (Unlock when locked) on page 2.
    app_menu_open(m, &CTX);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_SEND_HOME);
    app_menu_context_t locked = CTX;
    locked.locked = true;
    app_menu_open(m, &locked);
    tap(m, s.slots[3].x, s.slots[3].y);
    CHECK(app_menu_read(m).slots[0].bubble == APP_MENU_BUBBLE_UNLOCK);
    tap(m, 240, s.slots[0].y);
    a = app_menu_take_action(m);
    CHECK(a.kind == APP_MENU_ACTION_LOCK && a.arg == 0);

    // Greyed out (no Mac): a tap does nothing and the menu stays.
    app_menu_context_t no_mac = CTX;
    no_mac.can_send = false;
    app_menu_open(m, &no_mac);
    CHECK(!app_menu_read(m).slots[0].enabled);
    tap(m, 240, s.slots[0].y);
    CHECK(app_menu_take_action(m).kind == APP_MENU_ACTION_NONE && app_menu_is_open(m));

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
    app_menu_destroy(&m);
}

int main(void)
{
    test_pages();
    test_swap();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
