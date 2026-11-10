// SPDX-License-Identifier: Apache-2.0
#include <math.h>
#include <stdlib.h>
#include "include/app_game.h"

/* Fixed 30 Hz update. Art timing is 12 fps "ticks" (SPEC §4.4): one art tick = 2.5 updates. */
enum { TICK_HZ = 30 };
#define ART_HOLD(n) (((n) * 5 + 1) / 2)

/* Physics in art pixels (apx), scaled by config.scale on screen (SPEC §4.5, §12.2). */
static const float GRAVITY_APX = 900.0f;
static const float HOP_APEX_MIN = 18.0f, HOP_APEX_MAX = 30.0f;
static const float HOP_DIST_MIN = 40.0f, HOP_DIST_MAX = 90.0f;
static const float EXIT_APEX = 60.0f, EXIT_SPEED = 320.0f;

/* Input timing (SPEC §11.1): a tap is short and still; a second press inside the
 * double-tap window cancels the pending single tap. */
enum { TAP_MAX_TICKS = 8, TAP_SLOP_PX = 12, DOUBLE_TAP_TICKS = 9 };
enum { CROUCH_TICKS = ART_HOLD(3), LAND_TICKS = ART_HOLD(3), SHRUG_TICKS = 36 };
enum { BLINK_TICKS = 5, BLINK_GAP_MIN = 60, BLINK_GAP_MAX = 150, WANDER_MIN = 300, WANDER_MAX = 600 };

typedef enum { HOP_NONE, HOP_CROUCH, HOP_AIR, HOP_LAND } hop_stage_t;

struct app_game {
    app_game_config_t config;
    app_game_snapshot_t state;
    uint32_t rng;

    /* Pet motion, in screen pixels (floats; the snapshot rounds). */
    float x, y, vx, vy;
    hop_stage_t hop;
    uint32_t stage_tick;      /* tick when the current stage began */
    uint32_t idle_tick;       /* idle loop start */
    uint32_t next_blink, blink_until, next_wander;

    /* Touch */
    bool was_down;
    uint32_t down_tick;
    int32_t down_x, down_y;
    bool down_on_pet;
    bool tap_pending;
    uint32_t tap_deadline;
    app_game_request_t request;
};

static uint32_t next_random(app_game_handle_t g)
{
    g->rng ^= g->rng << 13;
    g->rng ^= g->rng >> 17;
    g->rng ^= g->rng << 5;
    return g->rng;
}

static float random_between(app_game_handle_t g, float lo, float hi)
{
    return lo + (hi - lo) * (float)(next_random(g) % 10001u) / 10000.0f;
}

static uint32_t random_ticks(app_game_handle_t g, uint32_t lo, uint32_t hi)
{
    return lo + next_random(g) % (hi - lo + 1u);
}

static float px(app_game_handle_t g, float apx)
{
    return apx * (float)g->config.scale;
}

static float half_width(app_game_handle_t g)
{
    return px(g, g->config.pet_w) / 2.0f;
}

static float floor_y(app_game_handle_t g)
{
    return (float)g->config.height;
}

static void set_phase(app_game_handle_t g, app_game_pet_phase_t phase)
{
    g->state.phase = phase;
    g->stage_tick = g->state.tick;
}

static void start_idle(app_game_handle_t g)
{
    set_phase(g, APP_GAME_PET_IDLE);
    g->hop = HOP_NONE;
    g->idle_tick = g->state.tick;
    g->y = floor_y(g);
    g->vx = g->vy = 0;
    g->next_blink = g->state.tick + random_ticks(g, BLINK_GAP_MIN, BLINK_GAP_MAX);
    g->next_wander = g->state.tick + random_ticks(g, WANDER_MIN, WANDER_MAX);
}

app_game_err_t app_game_create(const app_game_config_t *config, app_game_handle_t *ret_handle)
{
    if (!ret_handle) {
        return APP_GAME_INVALID_ARGUMENT;
    }
    *ret_handle = NULL;
    if (!config || !config->width || !config->height || !config->scale || config->scale > 16 ||
            !config->pet_w || !config->pet_h) {
        return APP_GAME_INVALID_ARGUMENT;
    }
    app_game_handle_t game = calloc(1, sizeof(*game));
    if (!game) {
        return APP_GAME_NO_MEMORY;
    }
    game->config = *config;
    app_game_reset(game);
    *ret_handle = game;
    return APP_GAME_OK;
}

void app_game_destroy(app_game_handle_t *handle)
{
    if (handle) {
        free(*handle);
        *handle = NULL;
    }
}

void app_game_reset(app_game_handle_t game)
{
    if (!game) {
        return;
    }
    app_game_config_t config = game->config;
    *game = (struct app_game) {
        0
    };
    game->config = config;
    game->rng = config.seed ? config.seed : 0x9E3779B9u;
    game->x = (float)config.width / 2.0f;
    game->y = floor_y(game);
    game->state.phase = APP_GAME_PET_ABSENT;
    game->state.facing = 1;
}

void app_game_set_paused(app_game_handle_t game, bool paused)
{
    if (game) {
        game->state.paused = paused;
    }
}

static bool pet_present(app_game_handle_t g)
{
    return g->state.phase != APP_GAME_PET_ABSENT && g->state.phase != APP_GAME_PET_EXITING;
}

static bool hits_pet(app_game_handle_t g, int32_t x, int32_t y)
{
    float hw = half_width(g), h = px(g, g->config.pet_h);
    return pet_present(g) && (float)x >= g->x - hw && (float)x <= g->x + hw && (float)y >= g->y - h &&
           (float)y <= g->y;
}

void app_game_set_pointer(app_game_handle_t game, int32_t x, int32_t y, bool pressed)
{
    if (!game) {
        return;
    }
    game->state.pointer_x = x < 0 ? 0 : (x >= game->config.width ? game->config.width - 1 : x);
    game->state.pointer_y = y < 0 ? 0 : (y >= game->config.height ? game->config.height - 1 : y);
    game->state.pointer_down = pressed;
    x = game->state.pointer_x;
    y = game->state.pointer_y;

    if (pressed && !game->was_down) {
        game->down_tick = game->state.tick;
        game->down_x = x;
        game->down_y = y;
        game->down_on_pet = hits_pet(game, x, y);
        if (game->tap_pending) {
            /* Second press inside the window: a double-tap, never a send (SPEC §11.1). */
            game->tap_pending = false;
            game->down_on_pet = false;
        }
    } else if (!pressed && game->was_down) {
        int32_t dx = x - game->down_x, dy = y - game->down_y;
        bool still = dx * dx + dy * dy <= TAP_SLOP_PX * TAP_SLOP_PX;
        if (game->down_on_pet && still && game->state.tick - game->down_tick <= TAP_MAX_TICKS) {
            game->tap_pending = true;
            game->tap_deadline = game->state.tick + DOUBLE_TAP_TICKS;
        }
        game->down_on_pet = false;
    }
    game->was_down = pressed;
}

/* Landing squash: 0.75 → 1.1 → 0.97 → 1.0 over about 0.35 s (SPEC §7.3). */
static uint16_t squash_at(uint32_t t)
{
    static const uint16_t keys[] = {750, 880, 1010, 1100, 1060, 1010, 970, 980, 990, 1000};
    return t < sizeof keys / sizeof keys[0] ? keys[t] : 1000;
}

/* A hop to `target_x` with the given apex (apx): crouch, parabola, land and squash.
 * v0 = sqrt(2 g h) up; flight time = 2 v0 / g, so vx = distance / time. */
static void begin_hop(app_game_handle_t g, float target_x, float apex_apx)
{
    float gravity = px(g, GRAVITY_APX);
    g->vy = -sqrtf(2.0f * gravity * px(g, apex_apx));
    float flight = 2.0f * -g->vy / gravity;
    g->vx = (target_x - g->x) / flight;
    if (g->vx != 0) {
        g->state.facing = g->vx > 0 ? 1 : -1;
    }
    g->hop = HOP_CROUCH;
    g->stage_tick = g->state.tick;
}

static void begin_wander(app_game_handle_t g)
{
    float hw = half_width(g), lo = hw, hi = (float)g->config.width - hw;
    float dist = px(g, random_between(g, HOP_DIST_MIN, HOP_DIST_MAX));
    float dir = (next_random(g) & 1u) ? 1.0f : -1.0f;
    float target = g->x + dir * dist;
    if (target < lo || target > hi) {
        target = g->x - dir * dist;  /* turn around at a wall */
    }
    target = target < lo ? lo : (target > hi ? hi : target);
    set_phase(g, APP_GAME_PET_HOPPING);
    begin_hop(g, target, random_between(g, HOP_APEX_MIN, HOP_APEX_MAX));
}

/* Gravity and motion for one tick; true when the feet reach the floor. */
static bool fall_step(app_game_handle_t g)
{
    const float dt = 1.0f / (float)TICK_HZ;
    g->vy += px(g, GRAVITY_APX) * dt;
    g->x += g->vx * dt;
    g->y += g->vy * dt;
    if (g->y >= floor_y(g) && g->vy > 0) {
        g->y = floor_y(g);
        g->vx = g->vy = 0;
        return true;
    }
    return false;
}

/* Runs the hop stages; true when the hop (landing included) is over. */
static bool hop_step(app_game_handle_t g)
{
    uint32_t t = g->state.tick - g->stage_tick;
    switch (g->hop) {
    case HOP_CROUCH:
        if (t >= CROUCH_TICKS) {
            g->hop = HOP_AIR;
            g->stage_tick = g->state.tick;
        }
        return false;
    case HOP_AIR:
        if (fall_step(g)) {
            g->hop = HOP_LAND;
            g->stage_tick = g->state.tick;
        }
        return false;
    case HOP_LAND:
        return t >= LAND_TICKS && t >= 10;
    case HOP_NONE:
    default:
        return true;
    }
}

static app_game_pose_t idle_pose(app_game_handle_t g)
{
    if (g->state.tick < g->blink_until) {
        return APP_GAME_POSE_BLINK;
    }
    /* idle holds [6, 2, 8] art ticks, looping all three (pixl.json). */
    uint32_t loop = ART_HOLD(6) + ART_HOLD(2) + ART_HOLD(8);
    uint32_t t = (g->state.tick - g->idle_tick) % loop;
    return t < ART_HOLD(6) ? APP_GAME_POSE_IDLE_0 : (t < ART_HOLD(6) + ART_HOLD(2) ? APP_GAME_POSE_IDLE_1 : APP_GAME_POSE_IDLE_2);
}

static app_game_pose_t hop_pose(app_game_handle_t g)
{
    return g->hop == HOP_CROUCH ? APP_GAME_POSE_CROUCH : g->hop == HOP_AIR ? APP_GAME_POSE_AIR : APP_GAME_POSE_LAND;
}

void app_game_update(app_game_handle_t game)
{
    if (!game || game->state.paused) {
        return;
    }
    app_game_handle_t g = game;
    ++g->state.tick;
    uint32_t now = g->state.tick;

    if (g->tap_pending && now > g->tap_deadline) {
        g->tap_pending = false;
        if (pet_present(g) && !g->state.waiting) {
            g->request = APP_GAME_REQUEST_SEND_HOME;
            g->state.waiting = true;
        }
    }

    uint16_t squash = 1000;
    switch (g->state.phase) {
    case APP_GAME_PET_ABSENT:
        break;
    case APP_GAME_PET_ENTERING:
        if (g->hop == HOP_AIR) {
            if (fall_step(g)) {
                g->hop = HOP_LAND;
                g->stage_tick = now;
            }
            g->state.pose = APP_GAME_POSE_AIR;
        } else {
            uint32_t t = now - g->stage_tick;
            squash = squash_at(t);
            g->state.pose = APP_GAME_POSE_LAND;
            if (t >= 12) {
                start_idle(g);
            }
        }
        break;
    case APP_GAME_PET_IDLE:
        if (now >= g->next_blink) {
            g->blink_until = now + BLINK_TICKS;
            g->next_blink = now + random_ticks(g, BLINK_GAP_MIN, BLINK_GAP_MAX);
        }
        if (now >= g->next_wander && !g->state.waiting && !g->was_down) {
            begin_wander(g);
            g->state.pose = APP_GAME_POSE_CROUCH;
            break;
        }
        g->state.pose = idle_pose(g);
        break;
    case APP_GAME_PET_HOPPING:
        if (g->hop == HOP_LAND) {
            squash = squash_at(now - g->stage_tick);
        }
        g->state.pose = hop_pose(g);
        if (hop_step(g)) {
            start_idle(g);
            g->state.pose = idle_pose(g);
        }
        break;
    case APP_GAME_PET_EXITING:
        if (g->hop == HOP_CROUCH) {
            g->state.pose = APP_GAME_POSE_CROUCH;
            if (now - g->stage_tick >= CROUCH_TICKS) {
                g->hop = HOP_AIR;
            }
        } else {
            const float dt = 1.0f / (float)TICK_HZ;
            g->vy += px(g, GRAVITY_APX) * dt;
            g->x += g->vx * dt;
            g->y += g->vy * dt;
            g->state.pose = APP_GAME_POSE_AIR;
            float hw = half_width(g);
            if (g->x < -hw || g->x > (float)g->config.width + hw || g->y > floor_y(g) + px(g, g->config.pet_h)) {
                set_phase(g, APP_GAME_PET_ABSENT);
                g->state.waiting = false;
            }
        }
        break;
    case APP_GAME_PET_SHRUGGING:
        g->state.pose = APP_GAME_POSE_ANNOYED;
        if (now - g->stage_tick >= SHRUG_TICKS) {
            start_idle(g);
        }
        break;
    }
    /* Squash keeps the feet planted: narrower when taller, wider when flatter. */
    g->state.squash_y = squash;
    g->state.squash_x = (uint16_t)(2000 - squash);
}

app_game_snapshot_t app_game_read(app_game_handle_t game)
{
    if (!game) {
        return (app_game_snapshot_t) {
            0
        };
    }
    app_game_snapshot_t s = game->state;
    s.pet_x = (int32_t)lroundf(game->x);
    s.pet_y = (int32_t)lroundf(game->y);
    if (!s.squash_x) {
        s.squash_x = s.squash_y = 1000;
    }
    return s;
}

void app_game_pet_arrive(app_game_handle_t g)
{
    if (!g) {
        return;
    }
    set_phase(g, APP_GAME_PET_ENTERING);
    g->x = (float)g->config.width / 2.0f;
    g->y = 0.0f;  /* feet at the top edge: the whole body starts above the screen */
    g->vx = g->vy = 0;
    g->hop = HOP_AIR;
    g->state.pose = APP_GAME_POSE_AIR;
    g->state.waiting = false;
    g->tap_pending = false;
}

void app_game_pet_leave(app_game_handle_t g)
{
    if (!g || g->state.phase == APP_GAME_PET_ABSENT) {
        return;
    }
    set_phase(g, APP_GAME_PET_EXITING);
    g->y = floor_y(g);
    float gravity = px(g, GRAVITY_APX);
    g->vy = -sqrtf(2.0f * gravity * px(g, EXIT_APEX));
    /* Off the nearer side edge. */
    float dir = g->x < (float)g->config.width / 2.0f ? -1.0f : 1.0f;
    g->vx = dir * px(g, EXIT_SPEED);
    g->state.facing = (int8_t)dir;
    g->hop = HOP_CROUCH;
    g->tap_pending = false;
}

void app_game_pet_shrug(app_game_handle_t g)
{
    if (!g) {
        return;
    }
    g->state.waiting = false;
    if (pet_present(g)) {
        g->y = floor_y(g);
        g->hop = HOP_NONE;
        set_phase(g, APP_GAME_PET_SHRUGGING);
    }
}

app_game_request_t app_game_take_request(app_game_handle_t g)
{
    if (!g) {
        return APP_GAME_REQUEST_NONE;
    }
    app_game_request_t r = g->request;
    g->request = APP_GAME_REQUEST_NONE;
    return r;
}
