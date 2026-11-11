// Host tests for the app_game model (no engine, no drawing): `make -C tests`.
#include <stdio.h>
#include "../components/app_game/include/app_game.h"

static int failures, checks;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static app_game_handle_t make(void)
{
    app_game_config_t cfg = {480, 480, 2, 68, 48, 42};
    app_game_handle_t g = NULL;
    CHECK(app_game_create(&cfg, &g) == APP_GAME_OK);
    return g;
}

static void run(app_game_handle_t g, int ticks)
{
    for (int i = 0; i < ticks; i++) app_game_update(g);
}

/* A Pixl that has landed and is idling in the middle. */
static app_game_handle_t idle_pet(void)
{
    app_game_handle_t g = make();
    app_game_pet_arrive(g);
    run(g, 60);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);
    return g;
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
    app_game_config_t bad = {480, 480, 0, 68, 48, 1};
    app_game_handle_t h = NULL;
    CHECK(app_game_create(&bad, &h) == APP_GAME_INVALID_ARGUMENT && !h);

    app_game_handle_t g = make();
    CHECK(app_game_read(g).phase == APP_GAME_PET_ABSENT);
    app_game_pet_arrive(g);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_ENTERING && s.pet_y == 0 && s.pose == APP_GAME_POSE_AIR);
    bool squashed = false;
    for (int i = 0; i < 60; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.squash_y < 1000) squashed = true;
    }
    CHECK(squashed);
    CHECK(s.phase == APP_GAME_PET_IDLE && s.pet_y == 480 && s.pet_x == 240);

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

static void test_poke_and_double_tap(void)
{
    app_game_handle_t g = idle_pet();
    // Off the Pixl: nothing.
    tap(g, 20, 20);
    run(g, 2);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);

    // A tap pokes at once (no waiting), squashed on the hit, and never sends.
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

    // A double-tap: a happy jump that leaves the floor and comes back.
    tap(g, 240, 440);
    run(g, 3);
    tap(g, 240, 440);
    app_game_update(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_HAPPY);
    run(g, 5);
    CHECK(app_game_read(g).pet_y < 480);
    run(g, 60);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE && app_game_read(g).pet_y == 480);

    // Three pokes inside 4 s: annoyed.
    for (int i = 0; i < 3; i++) {
        tap(g, 240, 440);
        run(g, 15);
    }
    CHECK(app_game_read(g).phase == APP_GAME_PET_SHRUGGING);
    run(g, 60);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);

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
    // Picked up: follows the finger, grab poses.
    app_game_set_pointer(g, 240, 440, true);
    app_game_update(g);
    app_game_set_pointer(g, 240, 380, true);
    app_game_update(g);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_HELD && s.pose == APP_GAME_POSE_GRAB_0);
    CHECK(s.pet_y == 420);
    run(g, 6);
    CHECK(app_game_read(g).pose == APP_GAME_POSE_GRAB_1);
    app_game_set_pointer(g, 300, 300, true);
    app_game_update(g);
    s = app_game_read(g);
    CHECK(s.pet_x == 300 && s.pet_y == 340);
    // Let go without moving: falls, bounces gently, settles on the floor, idles.
    for (int i = 0; i < 6; i++) {
        app_game_set_pointer(g, 300, 300, true);
        app_game_update(g);
    }
    app_game_set_pointer(g, 300, 300, false);
    CHECK(app_game_read(g).phase == APP_GAME_PET_AIRBORNE);
    run(g, 120);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_IDLE && s.pet_y == 480);
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
    bool clung = false;
    for (int i = 0; i < 30 && !clung; i++) {
        app_game_update(g);
        clung = app_game_read(g).phase == APP_GAME_PET_CLINGING;
    }
    app_game_snapshot_t s = app_game_read(g);
    CHECK(clung && s.edge == 1 && s.pet_x == 480 && s.waiting && s.facing == -1);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_SEND_HOME);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);
    // It can't be touched while the trip runs.
    tap(g, 470, s.pet_y - 20);
    app_game_update(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_CLINGING);

    // Committed: out through that edge.
    app_game_pet_leave(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_EXITING);
    run(g, 60);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_ABSENT && s.pet_x > 480 && !s.waiting && s.edge == 0);
    app_game_destroy(&g);

    // The trip fails: bounces back in, lands, shrugs, idles.
    g = idle_pet();
    drag(g, 240, 440, -40, -6, 3);
    for (int i = 0; i < 30 && app_game_read(g).phase != APP_GAME_PET_CLINGING; i++) app_game_update(g);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_CLINGING && s.edge == -1 && s.pet_x == 0);
    app_game_pet_shrug(g);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_AIRBORNE && !s.waiting && s.edge == 0);
    bool shrugged = false;
    for (int i = 0; i < 150; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_SHRUGGING) shrugged = true;
        CHECK(s.pet_x >= 0 && s.pet_x <= 480);
        if (s.pet_x < 0 || s.pet_x > 480) break;
    }
    CHECK(shrugged && s.phase == APP_GAME_PET_IDLE && s.pet_y == 480);
    app_game_destroy(&g);
}

static void test_leave_and_wander(void)
{
    // Committed from idle: hop out off the nearer side.
    app_game_handle_t g = idle_pet();
    app_game_pet_leave(g);
    run(g, 120);
    app_game_snapshot_t s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_ABSENT);
    CHECK(s.pet_x < 0 || s.pet_x > 480 || s.pet_y > 480);
    app_game_destroy(&g);

    // Left alone, it wanders: hops stay inside the walls.
    g = idle_pet();
    bool hopped = false;
    for (int i = 0; i < 30 * 60; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_HOPPING) hopped = true;
        CHECK(s.pet_x >= 68 - 1 && s.pet_x <= 480 - 68 + 1);
        if (s.pet_x < 0 || s.pet_x > 480) break;
    }
    CHECK(hopped);
    app_game_destroy(&g);
}

int main(void)
{
    test_create_and_arrive();
    test_poke_and_double_tap();
    test_drag_and_gentle_toss();
    test_fling_home();
    test_leave_and_wander();
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
