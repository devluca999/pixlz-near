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

static void tap(app_game_handle_t g, int x, int y)
{
    app_game_set_pointer(g, x, y, true);
    run(g, 2);
    app_game_set_pointer(g, x, y, false);
}

int main(void)
{
    app_game_config_t bad = {480, 480, 0, 68, 48, 1};
    app_game_handle_t h = NULL;
    CHECK(app_game_create(&bad, &h) == APP_GAME_INVALID_ARGUMENT && !h);

    app_game_handle_t g = make();
    CHECK(app_game_read(g).phase == APP_GAME_PET_ABSENT);

    // Drop-in: starts above the screen, lands on the floor with a squash, then idles.
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

    // Idle cycles its three frames and blinks within a few seconds.
    bool seen[8] = {0};
    for (int i = 0; i < 200; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_IDLE) seen[s.pose] = true;
    }
    CHECK(seen[APP_GAME_POSE_IDLE_0] && seen[APP_GAME_POSE_IDLE_1] && seen[APP_GAME_POSE_IDLE_2]);
    CHECK(seen[APP_GAME_POSE_BLINK]);
    app_game_reset(g);
    app_game_pet_arrive(g);
    run(g, 60);

    // A tap off the Pixl does nothing.
    tap(g, 20, 20);
    run(g, 20);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // A single tap on the Pixl sends him home, but only after the double-tap window.
    s = app_game_read(g);
    tap(g, s.pet_x, s.pet_y - 40);
    run(g, 5);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);
    run(g, 6);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_SEND_HOME);
    CHECK(app_game_read(g).waiting);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // The trip fails: shrug, then idle again; waiting clears.
    app_game_pet_shrug(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_SHRUGGING && !app_game_read(g).waiting);
    run(g, 40);
    CHECK(app_game_read(g).phase == APP_GAME_PET_IDLE);

    // A double-tap never sends.
    s = app_game_read(g);
    tap(g, s.pet_x, s.pet_y - 40);
    run(g, 3);
    tap(g, s.pet_x, s.pet_y - 40);
    run(g, 30);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // A long press isn't a tap.
    app_game_set_pointer(g, s.pet_x, s.pet_y - 40, true);
    run(g, 20);
    app_game_set_pointer(g, s.pet_x, s.pet_y - 40, false);
    run(g, 20);
    CHECK(app_game_take_request(g) == APP_GAME_REQUEST_NONE);

    // Committed: hop out off a side, then absent.
    app_game_pet_leave(g);
    CHECK(app_game_read(g).phase == APP_GAME_PET_EXITING);
    run(g, 120);
    s = app_game_read(g);
    CHECK(s.phase == APP_GAME_PET_ABSENT);
    CHECK(s.pet_x < 0 || s.pet_x > 480 || s.pet_y > 480);

    // Left alone, it wanders: hops stay inside the walls.
    app_game_reset(g);
    app_game_pet_arrive(g);
    bool hopped = false;
    for (int i = 0; i < 30 * 60; i++) {
        app_game_update(g);
        s = app_game_read(g);
        if (s.phase == APP_GAME_PET_HOPPING) hopped = true;
        CHECK(s.pet_x >= 68 - 1 && s.pet_x <= 480 - 68 + 1);
        if (failures) break;
    }
    CHECK(hopped);

    app_game_destroy(&g);
    CHECK(!g);
    printf("%d checks, %d failed\n", checks, failures);
    return failures ? 1 : 0;
}
