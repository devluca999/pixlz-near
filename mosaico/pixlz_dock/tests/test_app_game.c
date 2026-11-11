// Host tests for the app_game model (no engine, no drawing): `make -C tests`.
#include <stdio.h>
#include "../components/app_game/include/app_game.h"

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

enum { HZ = 30 };
#define MIN(m) ((m) * 60 * HZ)

static app_game_handle_t make_with(app_game_movement_t movement)
{
    app_game_config_t cfg = {480, 480, 2, 68, 48, 42, movement, 18.0f};
    app_game_handle_t g = NULL;
    CHECK(app_game_create(&cfg, &g) == APP_GAME_OK);
    return g;
}

static app_game_handle_t make(void)
{
    return make_with(APP_GAME_MOVE_HOP);
}

static void run(app_game_handle_t g, int ticks)
{
    for (int i = 0; i < ticks; i++) app_game_update(g);
}

/* Runs until the phase is `want` (or `limit` ticks); true if reached. */
static bool run_until(app_game_handle_t g, app_game_pet_phase_t want, int limit)
{
    for (int i = 0; i < limit; i++) {
        if (app_game_read(g).phase == want) return true;
        app_game_update(g);
    }
    return app_game_read(g).phase == want;
}

/* A Pixl that has landed, said hello and is idling. */
static app_game_handle_t idle_pet_with(app_game_movement_t movement)
{
    app_game_handle_t g = make_with(movement);
    app_game_pet_arrive(g);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 300));
    (void)app_game_take_say(g);
    return g;
}

static app_game_handle_t idle_pet(void)
{
    return idle_pet_with(APP_GAME_MOVE_HOP);
}

static void tap(app_game_handle_t g, int x, int y)
{
    app_game_set_pointer(g, x, y, true);
    run(g, 2);
    app_game_set_pointer(g, x, y, false);
}

/* Press on the Pixl, drag `steps` ticks by (dx, dy) each, release. */
static void drag(app_game_handle_t g, int x, int y, int dx, int dy, int steps)
{
    app_game_set_pointer(g, x, y, true);
    for (int i = 1; i <= steps; i++) {
        app_game_update(g);
        app_game_set_pointer(g, x + dx * i, y + dy * i, true);
    }
    app_game_set_pointer(g, x + dx * steps, y + dy * steps, false);
}

static void test_create_and_arrive(void)
{
    app_game_config_t bad = {480, 480, 0, 68, 48, 1, APP_GAME_MOVE_HOP, 0};
    app_game_handle_t h = NULL;
    CHECK(app_game_create(&bad, &h) == APP_GAME_INVALID_ARGUMENT && !h);

    app_game_handle_t g = make();
    CHECK(app_game_read(g).phase == APP_GAME_PET_ABSENT);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_NONE);
    app_game_pet_arrive(g);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_ENTERING && s.pet_y == 0 && s.pose == APP_GAME_POSE_AIR);
    bool squashed = false;
    for (int i = 0; i < 60 && app_game_read(g).phase == APP_GAME_PET_ENTERING; i++) {
        app_game_update(g);
        if (app_game_read(g).squash_y < 1000) squashed = true;
    }
    CHECK(squashed);
    // Landed: a happy hello.
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_EMOTING && s.pose == APP_GAME_POSE_HAPPY && s.pet_y == 480 && s.pet_x == 240);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_GREET);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_NONE);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 120));

    bool seen[APP_GAME_POSE_COUNT] = {0};
    for (int i = 0; i < 200; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_IDLE) seen[s.pose] = true;
    }
    CHECK(seen[APP_GAME_POSE_IDLE_0] && seen[APP_GAME_POSE_IDLE_1] && seen[APP_GAME_POSE_IDLE_2]);
    CHECK(seen[APP_GAME_POSE_BLINK]);
    app_game_destroy(&g);
    CHECK(!g);
}

static void test_poke_and_menu(void)
{
    app_game_handle_t g = idle_pet();
    // Off the Pixl: nothing.
    tap(g, 20, 20);
    run(g, 20);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // A tap pokes at once, squashed on the hit, and never sends.
    tap(g, 240, 440);
    app_game_update(g);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_POKED && s.pose == APP_GAME_POSE_POKE_0 && s.squash_y < 1000);
    bool saw_look_up = false;
    for (int i = 0; i < 40; i++) {
        app_game_update(g);
        if (app_game_read(g).pose == APP_GAME_POSE_POKE_1) saw_look_up = true;
    }
    CHECK(saw_look_up);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // A double-tap anywhere opens the menu; on the Pixl, the first tap still pokes.
    tap(g, 240, 440);
    run(g, 3);
    tap(g, 240, 440);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_MENU);
    run(g, 40);
    tap(g, 30, 30);
    run(g, 3);
    tap(g, 40, 30);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_MENU);
    // Two taps too far apart are two single taps.
    tap(g, 30, 30);
    run(g, 20);
    tap(g, 30, 30);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // Three pokes inside 4 s: annoyed, and it says so.
    run(g, 40);
    for (int i = 0; i < 3; i++) {
        tap(g, 240, 440);
        run(g, 15);
    }
    CHECK(app_game_read(g).phase == APP_GAME_PET_SHRUGGING);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_ANNOYED);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 80));

    // A long press isn't a tap.
    app_game_set_pointer(g, 240, 440, true);
    run(g, 20);
    app_game_set_pointer(g, 240, 440, false);
    run(g, 2);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);
    app_game_destroy(&g);
}

static void test_drag_and_gentle_toss(void)
{
    app_game_handle_t g = idle_pet();
    // Picked up: follows the finger, grab poses, curious.
    app_game_set_pointer(g, 240, 440, true);
    app_game_update(g);
    app_game_set_pointer(g, 240, 380, true);
    app_game_update(g);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_HELD && s.pose == APP_GAME_POSE_GRAB_0);
    CHECK(s.pet_y == 420);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_CURIOUS);
    run(g, 6);
    CHECK(app_game_read(g).pose == APP_GAME_POSE_GRAB_1);
    app_game_set_pointer(g, 300, 300, true);
    app_game_update(g);
    s = app_game_read(g);
    CHECK(s.pet_x == 300 && s.pet_y == 340);
    // Let go without moving: falls, settles on the floor, idles.
    for (int i = 0; i < 6; i++) {
        app_game_set_pointer(g, 300, 300, true);
        app_game_update(g);
    }
    app_game_set_pointer(g, 300, 300, false);
    CHECK(app_game_read(g).phase == APP_GAME_PET_AIRBORNE);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 150));
    s = app_game_read(g);
    CHECK(s.pet_y == 480);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // A slow toss into the wall bounces off it instead of leaving.
    drag(g, s.pet_x, 440, -6, -3, 6);
    for (int i = 0; i < 150; i++) {
        app_game_update(g);
        s = app_game_read(g);
        CHECK(s.pet_x >= 68 - 1 && s.pet_x <= 480 - 68 + 1);
        if (s.pet_x < 0 || s.pet_x > 480) break;
    }
    CHECK(s.phase == APP_GAME_PET_IDLE);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);
    app_game_destroy(&g);
}

static void test_fling_home(void)
{
    // A fast fling off the right edge: clings half off it and asks to go home.
    app_game_handle_t g = idle_pet();
    drag(g, 240, 440, 40, -6, 3);
    CHECK(run_until(g, APP_GAME_PET_CLINGING, 30));
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.edge == 1 && s.pet_x == 480 && s.waiting && s.facing == -1);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_SEND_HOME);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);
    // It can't be touched while the trip runs.
    tap(g, 470, s.pet_y - 20);
    app_game_update(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_CLINGING);

    // Committed: out through that edge.
    app_game_pet_leave(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_EXITING);
    CHECK(run_until(g, APP_GAME_PET_ABSENT, 60));
    s = app_game_read(g);
    CHECK(s.pet_x > 480 && !s.waiting && s.edge == 0);
    app_game_destroy(&g);

    // The trip fails: bounces back in, lands, shrugs (sadly), idles.
    g = idle_pet();
    drag(g, 240, 440, -40, -6, 3);
    CHECK(run_until(g, APP_GAME_PET_CLINGING, 30));
    s = app_game_read(g);
    CHECK(s.edge == -1 && s.pet_x == 0);
    app_game_pet_shrug(g);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_AIRBORNE && !s.waiting && s.edge == 0);
    CHECK(run_until(g, APP_GAME_PET_SHRUGGING, 150));
    CHECK(app_game_take_say(g) == APP_GAME_SAY_SAD);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 80));
    s = app_game_read(g);
    CHECK(s.pet_y == 480 && s.pet_x >= 0 && s.pet_x <= 480);
    app_game_destroy(&g);
}

static void test_sleep_and_wake(void)
{
    // Nobody touches it for 3 minutes: it winds down, dozes off (Zz), says it's sleepy.
    app_game_handle_t g = idle_pet();
    CHECK(run_until(g, APP_GAME_PET_RESTING, MIN(3) + 30));
    CHECK(app_game_take_say(g) == APP_GAME_SAY_SLEEPY);
    CHECK(app_game_read(g).pose == APP_GAME_POSE_REST_0 && !app_game_read(g).asleep);
    run(g, 60);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.pose == APP_GAME_POSE_REST_2 && s.asleep);
    // Still asleep much later: no wake-up on its own when it fell asleep for want of company.
    run(g, MIN(10));
    CHECK(app_game_read(g).phase == APP_GAME_PET_RESTING);
    // A poke wakes it: startled, then back to normal.
    s = app_game_read(g);
    tap(g, s.pet_x, s.pet_y - 20);
    app_game_update(g);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_EMOTING && s.pose == APP_GAME_POSE_STARTLED && !s.asleep);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_STARTLED);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 90));
    app_game_destroy(&g);

    // The menu's Nap: a few minutes of sleep, then it stretches and gets up by itself.
    g = idle_pet();
    app_game_nap(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_RESTING);
    bool stretched = false;
    for (int i = 0; i < MIN(5) && app_game_read(g).phase == APP_GAME_PET_RESTING; i++) {
        // keep it company so it doesn't fall back asleep for want of a touch
        if (i % MIN(1) == 0) app_game_set_pointer(g, 10, 10, false);
        app_game_update(g);
        if (app_game_read(g).pose == APP_GAME_POSE_CROUCH) stretched = true;
    }
    CHECK(stretched);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);
    app_game_destroy(&g);
}

static void test_trick_and_mischief(void)
{
    // The menu's trick: signature frames, then proud and happy.
    app_game_handle_t g = idle_pet();
    app_game_trick(g);
    bool seen[APP_GAME_POSE_COUNT] = {0};
    for (int i = 0; i < 60 && app_game_read(g).phase == APP_GAME_PET_TRICK; i++) {
        app_game_update(g);
        seen[app_game_read(g).pose] = true;
    }
    CHECK(seen[APP_GAME_POSE_TRICK_1] && seen[APP_GAME_POSE_TRICK_2]);
    CHECK(app_game_read(g).phase == APP_GAME_PET_EMOTING && app_game_read(g).pose == APP_GAME_POSE_PROUD);
    CHECK(app_game_take_say(g) == APP_GAME_SAY_HAPPY);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 120));
    app_game_destroy(&g);

    // Left mostly alone (a touch now and then keeps it awake), it plays its trick, gets up to
    // mischief once nobody's touched it for a minute, and chats.
    g = idle_pet();
    bool trick = false, mischief = false, chat = false;
    for (int i = 0; i < MIN(45); i++) {
        app_game_update(g);
        app_game_pet_phase_t p = app_game_read(g).phase;
        trick |= p == APP_GAME_PET_TRICK;
        mischief |= p == APP_GAME_PET_MISCHIEF;
        chat |= app_game_take_say(g) == APP_GAME_SAY_IDLE;
        if (p == APP_GAME_PET_RESTING) tap(g, 240, 440);       // wake it
        else if (i % (MIN(1) + MIN(1) / 2) == 0) app_game_set_pointer(g, 5, 5, true), app_game_set_pointer(g, 5, 5, false);
        if (trick && mischief && chat) break;
    }
    CHECK(trick);
    CHECK(mischief);
    CHECK(chat);
    app_game_destroy(&g);
}

static void test_walker_and_floater(void)
{
    // A walker crawls along the floor with its move frames, inside the walls.
    app_game_handle_t g = idle_pet_with(APP_GAME_MOVE_WALK);
    CHECK(run_until(g, APP_GAME_PET_MOVING, 700));
    bool crawled = false;
    for (int i = 0; i < 400 && app_game_read(g).phase == APP_GAME_PET_MOVING; i++) {
        app_game_update(g);
        app_game_snapshot_t s = app_game_read(g);
        CHECK(s.pet_y == 480 && s.pet_x >= 67 && s.pet_x <= 413);
        crawled |= s.pose == APP_GAME_POSE_AIR;  // move_1 in the crawl cycle
        if (s.pet_y != 480) break;
    }
    CHECK(crawled);
    app_game_destroy(&g);

    // A floater drifts down to hover above the floor, bobs, and stays in the air when thrown.
    g = make_with(APP_GAME_MOVE_FLOAT);
    app_game_pet_arrive(g);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 200));
    int lo = 1000, hi = -1000;
    for (int i = 0; i < 60; i++) {
        app_game_update(g);
        int y = app_game_read(g).pet_y;
        if (y < lo) lo = y;
        if (y > hi) hi = y;
    }
    CHECK(hi < 480 && hi - lo >= 4);   // hovering, bobbing
    app_game_snapshot_t s = app_game_read(g);
    drag(g, s.pet_x, s.pet_y - 20, 4, -8, 4);
    CHECK(app_game_read(g).phase == APP_GAME_PET_AIRBORNE);
    CHECK(run_until(g, APP_GAME_PET_IDLE, 300));
    CHECK(app_game_read(g).pet_y < 440);   // no gravity: it stops where it coasts to
    app_game_destroy(&g);
}

static void test_swap_look(void)
{
    app_game_handle_t g = idle_pet();
    app_game_config_t kiti = {480, 480, 3, 45, 40, 1, APP_GAME_MOVE_HOP, 0};
    app_game_set_look(g, &kiti);
    CHECK(app_game_read(g).phase == APP_GAME_PET_ENTERING);   // the new look drops in
    CHECK(run_until(g, APP_GAME_PET_IDLE, 300));
    // The hit area follows the new size: 3 x 45 wide around the middle.
    tap(g, 240 + 60, 470);
    app_game_update(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_POKED);
    app_game_destroy(&g);

    // Swapping while away just changes the look for next time.
    g = make();
    app_game_set_look(g, &kiti);
    CHECK(app_game_read(g).phase == APP_GAME_PET_ABSENT);
    app_game_destroy(&g);
}

static void test_leave_and_wander(void)
{
    // Committed from idle: hop out off the nearer side.
    app_game_handle_t g = idle_pet();
    app_game_pet_leave(g);
    CHECK(run_until(g, APP_GAME_PET_ABSENT, 120));
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.pet_x < 0 || s.pet_x > 480 || s.pet_y > 480);
    app_game_destroy(&g);

    // Left alone, it wanders: hops stay inside the walls.
    g = idle_pet();
    bool hopped = false;
    for (int i = 0; i < 60 * 60; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_MOVING) hopped = true;
        CHECK(s.pet_x >= 68 - 1 && s.pet_x <= 480 - 68 + 1);
        if (s.pet_x < 0 || s.pet_x > 480) break;
    }
    CHECK(hopped);
    app_game_destroy(&g);
}

int main(void)
{
    test_create_and_arrive();
    test_poke_and_menu();
    test_drag_and_gentle_toss();
    test_fling_home();
    test_sleep_and_wake();
    test_trick_and_mischief();
    test_walker_and_floater();
    test_swap_look();
    test_leave_and_wander();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
