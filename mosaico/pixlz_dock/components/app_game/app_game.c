// SPDX-License-Identifier: Apache-2.0
#include <math.h>
#include <stdlib.h>
#include "include/app_game.h"

/* Fixed 30 Hz update. Art timing is 12 fps "ticks" (SPEC §4.4): one art tick = 2.5 updates. */
enum { TICK_HZ = 30 };
#define ART_HOLD(n) (((n) * 5 + 1) / 2)
static const float DT = 1.0f / (float)TICK_HZ;

/* Physics in art pixels (apx), scaled by config.scale on screen (SPEC §4.5, §12.2). */
static const float GRAVITY_APX = 900.0f;
static const float HOP_APEX_MIN = 18.0f, HOP_APEX_MAX = 30.0f;
static const float HOP_DIST_MIN = 40.0f, HOP_DIST_MAX = 90.0f;
static const float EXIT_APEX = 60.0f, EXIT_SPEED = 320.0f;
static const float HAPPY_APEX = 26.0f;
/* Throws (SPEC §4.5, §11.1): release speed capped; walls and ceiling bounce at 0.4. */
static const float THROW_CAP_APX = 1500.0f;
static const float RESTITUTION = 0.4f;
/* Faster than this (apx/s) across a side edge is a fling: the Pixl goes home (SPEC §11.1). */
static const float FLING_APX = 350.0f;
/* Below this landing speed (apx/s) the Pixl stops instead of bouncing. */
static const float SETTLE_APX = 120.0f;

/* Touch (SPEC §11.1): a tap is short and still; a second tap inside the window is a double-tap. */
enum { TAP_MAX_TICKS = 8, TAP_SLOP_PX = 12, DOUBLE_TAP_TICKS = 9 };
enum { CROUCH_TICKS = ART_HOLD(3), LAND_TICKS = ART_HOLD(3), SHRUG_TICKS = 36, GRAB_CATCH_TICKS = 4 };
enum { BLINK_TICKS = 5, BLINK_GAP_MIN = 60, BLINK_GAP_MAX = 150, WANDER_MIN = 300, WANDER_MAX = 600 };
/* poke holds [2, 4, 6] art ticks (pixl.json); three pokes inside 4 s annoy it (SPEC §11.1). */
enum { POKE_ANNOY_COUNT = 3, POKE_ANNOY_TICKS = 4 * TICK_HZ };
enum { SAMPLES = 4 };

typedef enum { HOP_NONE, HOP_CROUCH, HOP_AIR, HOP_LAND } hop_stage_t;

struct app_game {
    app_game_config_t config;
    app_game_snapshot_t state;
    uint32_t rng;

    /* Pet motion, in screen pixels and pixels per second. */
    float x, y, vx, vy;
    hop_stage_t hop;
    uint32_t stage_tick;
    uint32_t idle_tick;
    uint32_t next_blink, blink_until, next_wander;
    bool shrug_after_landing;

    /* Touch */
    bool was_down, down_on_pet;
    uint32_t down_tick, last_tap_tick;
    int32_t down_x, down_y;
    float grab_dx, grab_dy;  /* feet relative to the finger while held */
    struct { float x, y; uint32_t tick; } samples[SAMPLES];
    int sample_count;
    uint32_t poke_ticks[POKE_ANNOY_COUNT];
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

static float pet_height(app_game_handle_t g)
{
    return px(g, g->config.pet_h);
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

/* Touchable: on screen, not leaving, not mid-trip at an edge. */
static bool touchable(app_game_handle_t g)
{
    switch (g->state.phase) {
    case APP_GAME_PET_ABSENT:
    case APP_GAME_PET_EXITING:
    case APP_GAME_PET_CLINGING:
        return false;
    default:
        return true;
    }
}

static bool hits_pet(app_game_handle_t g, int32_t x, int32_t y)
{
    float hw = half_width(g), h = pet_height(g);
    return touchable(g) && (float)x >= g->x - hw && (float)x <= g->x + hw && (float)y >= g->y - h &&
           (float)y <= g->y;
}

static void add_sample(app_game_handle_t g, float x, float y)
{
    if (g->sample_count == SAMPLES) {
        for (int i = 1; i < SAMPLES; i++) {
            g->samples[i - 1] = g->samples[i];
        }
        g->sample_count--;
    }
    g->samples[g->sample_count].x = x;
    g->samples[g->sample_count].y = y;
    g->samples[g->sample_count].tick = g->state.tick;
    g->sample_count++;
}

static float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* Feet position for a finger at (fx, fy) while held, kept on the screen. */
static void follow_finger(app_game_handle_t g, float fx, float fy)
{
    float hw = half_width(g);
    g->x = clampf(fx + g->grab_dx, hw, (float)g->config.width - hw);
    g->y = clampf(fy + g->grab_dy, pet_height(g), floor_y(g));
}

static void begin_hold(app_game_handle_t g)
{
    set_phase(g, APP_GAME_PET_HELD);
    g->hop = HOP_NONE;
    g->vx = g->vy = 0;
    g->grab_dx = g->x - (float)g->down_x;
    g->grab_dy = g->y - (float)g->down_y;
    g->sample_count = 0;
    add_sample(g, (float)g->down_x, (float)g->down_y);
}

/* Release: the finger's speed over the last few samples becomes the throw. */
static void release_hold(app_game_handle_t g)
{
    float vx = 0, vy = 0;
    if (g->sample_count >= 2) {
        const int last = g->sample_count - 1;
        uint32_t ticks = g->samples[last].tick - g->samples[0].tick;
        float dt = (float)(ticks ? ticks : 1) * DT;
        vx = (g->samples[last].x - g->samples[0].x) / dt;
        vy = (g->samples[last].y - g->samples[0].y) / dt;
    }
    float cap = px(g, THROW_CAP_APX);
    float speed = sqrtf(vx * vx + vy * vy);
    if (speed > cap) {
        vx *= cap / speed;
        vy *= cap / speed;
    }
    set_phase(g, APP_GAME_PET_AIRBORNE);
    g->vx = vx;
    g->vy = vy;
    if (vx != 0) {
        g->state.facing = vx > 0 ? 1 : -1;
    }
}

static void poke(app_game_handle_t g)
{
    for (int i = 1; i < POKE_ANNOY_COUNT; i++) {
        g->poke_ticks[i - 1] = g->poke_ticks[i];
    }
    g->poke_ticks[POKE_ANNOY_COUNT - 1] = g->state.tick;
    bool annoyed = g->poke_ticks[0] && g->state.tick - g->poke_ticks[0] <= POKE_ANNOY_TICKS;
    g->hop = HOP_NONE;
    g->y = floor_y(g);
    g->vx = g->vy = 0;
    if (annoyed) {
        g->poke_ticks[0] = 0;
        set_phase(g, APP_GAME_PET_SHRUGGING);
    } else {
        set_phase(g, APP_GAME_PET_POKED);
    }
}

static void happy_jump(app_game_handle_t g)
{
    set_phase(g, APP_GAME_PET_HAPPY);
    g->hop = HOP_NONE;
    g->y = floor_y(g);
    g->vx = 0;
    g->vy = -sqrtf(2.0f * px(g, GRAVITY_APX) * px(g, HAPPY_APEX));
}

void app_game_set_pointer(app_game_handle_t game, int32_t x, int32_t y, bool pressed)
{
    if (!game) {
        return;
    }
    app_game_handle_t g = game;
    g->state.pointer_x = x < 0 ? 0 : (x >= g->config.width ? g->config.width - 1 : x);
    g->state.pointer_y = y < 0 ? 0 : (y >= g->config.height ? g->config.height - 1 : y);
    g->state.pointer_down = pressed;
    x = g->state.pointer_x;
    y = g->state.pointer_y;

    if (pressed && !g->was_down) {
        g->down_tick = g->state.tick;
        g->down_x = x;
        g->down_y = y;
        g->down_on_pet = hits_pet(g, x, y);
    } else if (pressed && g->down_on_pet) {
        int32_t dx = x - g->down_x, dy = y - g->down_y;
        if (g->state.phase != APP_GAME_PET_HELD && dx * dx + dy * dy > TAP_SLOP_PX * TAP_SLOP_PX) {
            begin_hold(g);
        }
        if (g->state.phase == APP_GAME_PET_HELD) {
            follow_finger(g, (float)x, (float)y);
            add_sample(g, (float)x, (float)y);
        }
    } else if (!pressed && g->was_down && g->down_on_pet) {
        if (g->state.phase == APP_GAME_PET_HELD) {
            add_sample(g, (float)x, (float)y);
            release_hold(g);
        } else if (g->state.tick - g->down_tick <= TAP_MAX_TICKS) {
            /* The poke shows at once; a second tap inside the window turns it into a double-tap. */
            bool second = g->last_tap_tick && g->state.tick - g->last_tap_tick <= DOUBLE_TAP_TICKS;
            g->last_tap_tick = second ? 0 : (g->state.tick ? g->state.tick : 1);
            if (second) {
                happy_jump(g);
            } else {
                poke(g);
            }
        }
        g->down_on_pet = false;
    }
    g->was_down = pressed;
}

/* Landing squash: 0.75 → 1.1 → 0.97 → 1.0 over about 0.35 s (SPEC §7.3). */
static uint16_t squash_at(uint32_t t)
{
    static const uint16_t keys[] = {750, 880, 1010, 1100, 1060, 1010, 970, 980, 990, 1000};
    return t < sizeof keys / sizeof keys[0] ? keys[t] : 1000;
}

/* A hop to `target_x` with the given apex (apx): v0 = sqrt(2 g h); flight time = 2 v0 / g. */
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
    set_phase(g, APP_GAME_PET_HOPPING);
    begin_hop(g, clampf(target, lo, hi), random_between(g, HOP_APEX_MIN, HOP_APEX_MAX));
}

/* Gravity and motion for one tick; true when the feet reach the floor. */
static bool fall_step(app_game_handle_t g)
{
    g->vy += px(g, GRAVITY_APX) * DT;
    g->x += g->vx * DT;
    g->y += g->vy * DT;
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

/* A thrown Pixl: walls and ceiling bounce; a fast crossing of a side edge is a fling home. */
static void airborne_step(app_game_handle_t g)
{
    float hw = half_width(g), w = (float)g->config.width, h = pet_height(g);
    g->vy += px(g, GRAVITY_APX) * DT;
    g->x += g->vx * DT;
    g->y += g->vy * DT;

    int edge = g->x - hw < 0 ? -1 : (g->x + hw > w ? 1 : 0);
    if (edge && fabsf(g->vx) >= px(g, FLING_APX) && (g->vx > 0) == (edge > 0)) {
        /* Clings half off that edge until the trip settles (SPEC §11.1). */
        set_phase(g, APP_GAME_PET_CLINGING);
        g->state.edge = (int8_t)edge;
        g->state.facing = (int8_t)-edge;
        g->x = edge < 0 ? 0.0f : w;
        g->y = clampf(g->y, h, floor_y(g));
        g->vx = g->vy = 0;
        g->request = APP_GAME_REQUEST_SEND_HOME;
        g->state.waiting = true;
        return;
    }
    if (edge) {
        g->x = edge < 0 ? hw : w - hw;
        g->vx = -g->vx * RESTITUTION;
    }
    if (g->y - h < 0 && g->vy < 0) {
        g->y = h;
        g->vy = -g->vy * RESTITUTION;
    }
    if (g->y >= floor_y(g) && g->vy > 0) {
        g->y = floor_y(g);
        if (g->vy > px(g, SETTLE_APX)) {
            g->vy = -g->vy * RESTITUTION;
            g->vx *= 0.6f;
        } else {
            /* Settled: the landing squash, then idle (or the shrug a failed trip owes). */
            g->vx = g->vy = 0;
            set_phase(g, APP_GAME_PET_HOPPING);
            g->hop = HOP_LAND;
        }
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

static void exiting_step(app_game_handle_t g)
{
    if (g->hop == HOP_CROUCH) {
        g->state.pose = APP_GAME_POSE_CROUCH;
        if (g->state.tick - g->stage_tick >= CROUCH_TICKS) {
            g->hop = HOP_AIR;
        }
        return;
    }
    g->vy += px(g, GRAVITY_APX) * DT;
    g->x += g->vx * DT;
    g->y += g->vy * DT;
    g->state.pose = APP_GAME_POSE_AIR;
    float hw = half_width(g);
    if (g->x < -hw || g->x > (float)g->config.width + hw || g->y > floor_y(g) + pet_height(g)) {
        set_phase(g, APP_GAME_PET_ABSENT);
        g->state.waiting = false;
        g->state.edge = 0;
    }
}

void app_game_update(app_game_handle_t game)
{
    if (!game || game->state.paused) {
        return;
    }
    app_game_handle_t g = game;
    ++g->state.tick;
    uint32_t now = g->state.tick;
    uint32_t t = now - g->stage_tick;
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
        if (now >= g->next_wander && !g->was_down) {
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
            if (g->shrug_after_landing) {
                g->shrug_after_landing = false;
                set_phase(g, APP_GAME_PET_SHRUGGING);
                g->state.pose = APP_GAME_POSE_ANNOYED;
            } else {
                start_idle(g);
                g->state.pose = idle_pose(g);
            }
        }
        break;
    case APP_GAME_PET_EXITING:
        exiting_step(g);
        break;
    case APP_GAME_PET_SHRUGGING:
        g->state.pose = APP_GAME_POSE_ANNOYED;
        if (t >= SHRUG_TICKS) {
            start_idle(g);
        }
        break;
    case APP_GAME_PET_POKED:
        /* poke holds [2, 4, 6]: squashed on the hit, then look up, then recover. */
        if (t < ART_HOLD(2)) {
            g->state.pose = APP_GAME_POSE_POKE_0;
            squash = 820;
        } else if (t < ART_HOLD(2) + ART_HOLD(4)) {
            g->state.pose = APP_GAME_POSE_POKE_1;
        } else if (t < ART_HOLD(2) + ART_HOLD(4) + ART_HOLD(6)) {
            g->state.pose = APP_GAME_POSE_POKE_2;
        } else {
            start_idle(g);
            g->state.pose = idle_pose(g);
        }
        break;
    case APP_GAME_PET_HAPPY:
        g->state.pose = APP_GAME_POSE_HAPPY;
        if (g->vy != 0 && fall_step(g)) {
            g->stage_tick = now;
        }
        if (g->vy == 0 && now - g->stage_tick >= 18 && g->y >= floor_y(g)) {
            start_idle(g);
        }
        break;
    case APP_GAME_PET_HELD:
        g->state.pose = t < GRAB_CATCH_TICKS ? APP_GAME_POSE_GRAB_0 : APP_GAME_POSE_GRAB_1;
        break;
    case APP_GAME_PET_AIRBORNE:
        airborne_step(g);
        g->state.pose = APP_GAME_POSE_AIR;
        if (g->state.phase == APP_GAME_PET_CLINGING) {
            g->state.pose = APP_GAME_POSE_GRAB_1;
        }
        break;
    case APP_GAME_PET_CLINGING:
        g->state.pose = APP_GAME_POSE_GRAB_1;
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
    g->state.edge = 0;
    g->down_on_pet = false;
}

void app_game_pet_leave(app_game_handle_t g)
{
    if (!g || g->state.phase == APP_GAME_PET_ABSENT) {
        return;
    }
    float dir;
    if (g->state.phase == APP_GAME_PET_CLINGING) {
        dir = (float)g->state.edge;  /* out through the edge it holds */
    } else {
        dir = g->x < (float)g->config.width / 2.0f ? -1.0f : 1.0f;  /* off the nearer side */
        g->y = floor_y(g);
    }
    set_phase(g, APP_GAME_PET_EXITING);
    g->vy = -sqrtf(2.0f * px(g, GRAVITY_APX) * px(g, EXIT_APEX));
    g->vx = dir * px(g, EXIT_SPEED);
    g->state.facing = (int8_t)dir;
    g->hop = HOP_CROUCH;
    g->down_on_pet = false;
}

void app_game_pet_shrug(app_game_handle_t g)
{
    if (!g) {
        return;
    }
    g->state.waiting = false;
    if (g->state.phase == APP_GAME_PET_CLINGING) {
        /* Bounce back in from the edge, land, then shrug. */
        float inward = (float)-g->state.edge;
        g->state.edge = 0;
        set_phase(g, APP_GAME_PET_AIRBORNE);
        g->x += inward * half_width(g);
        g->vx = inward * px(g, 200.0f);
        g->vy = -px(g, 150.0f);
        g->state.facing = (int8_t)inward;
        g->shrug_after_landing = true;
    } else if (touchable(g) && g->state.phase != APP_GAME_PET_HELD && g->state.phase != APP_GAME_PET_AIRBORNE) {
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
