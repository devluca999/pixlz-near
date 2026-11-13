// SPDX-License-Identifier: Apache-2.0
#include <math.h>
#include <stdlib.h>
#include "include/app_game.h"

/* Fixed 30 Hz update. Art timing is 12 fps "ticks" (SPEC §4.4): one art tick = 2.5 updates. */
enum { TICK_HZ = 30 };
#define ART_HOLD(n) (((n) * 5 + 1) / 2)
#define SECONDS(s) ((uint32_t)((s) * TICK_HZ))
#define MINUTES(m) ((uint32_t)((m) * 60 * TICK_HZ))
static const float DT = 1.0f / (float)TICK_HZ;

/* Physics in art pixels (apx), scaled by config.scale on screen (SPEC §4.5, §12.2). */
static const float GRAVITY_APX = 900.0f;
static const float HOP_APEX_MIN = 18.0f, HOP_APEX_MAX = 30.0f;
static const float HOP_DIST_MIN = 40.0f, HOP_DIST_MAX = 90.0f;
static const float EXIT_APEX = 60.0f, EXIT_SPEED = 320.0f;
static const float DEFAULT_WALK_SPEED = 18.0f;
/* Throws (SPEC §4.5, §11.1): release speed capped; walls and ceiling bounce at 0.4. */
static const float THROW_CAP_APX = 1500.0f;
static const float RESTITUTION = 0.4f;
/* Faster than this (apx/s) across a side edge is a fling: the Pixl goes home (SPEC §11.1). */
static const float FLING_APX = 350.0f;
/* Below this landing speed (apx/s) the Pixl stops instead of bouncing. */
static const float SETTLE_APX = 120.0f;
/* Floaters: drag per tick on a throw; hover height above the floor (in pet heights); bob. */
static const float FLOAT_DRAG = 0.94f, FLOAT_SETTLE_APX = 20.0f, HOVER = 0.3f, BOB_PX = 3.0f;

/* Touch (SPEC §11.1): a tap is short and still; a second tap inside the window is a double-tap. */
enum { TAP_MAX_TICKS = 8, TAP_SLOP_PX = 12, DOUBLE_TAP_TICKS = 9 };
enum { CROUCH_TICKS = ART_HOLD(3), LAND_TICKS = ART_HOLD(3), SHRUG_TICKS = 36, GRAB_CATCH_TICKS = 4 };
enum { BLINK_TICKS = 5, BLINK_GAP_MIN = 60, BLINK_GAP_MAX = 150, WANDER_MIN = 300, WANDER_MAX = 600 };
/* poke holds [2, 4, 6] art ticks (pixl.json); three pokes inside 4 s annoy it (SPEC §11.1). */
enum { POKE_ANNOY_COUNT = 3, POKE_ANNOY_TICKS = 4 * TICK_HZ };
enum { SAMPLES = 4, WALK_FRAME_TICKS = 8 };

/* The Pixl's own life (SPEC §4.3, §6.2, the Mac app's sleep and roam): */
#define SLEEP_AFTER MINUTES(3)           /* no touch for this long: wind down and sleep */
#define NAP_EVERY_MIN MINUTES(45)        /* short naps while people are around */
#define NAP_EVERY_MAX MINUTES(90)
#define NAP_LENGTH_MIN MINUTES(2)
#define NAP_LENGTH_MAX MINUTES(4)
#define TRICK_EVERY_MIN MINUTES(8)       /* its signature, now and then */
#define TRICK_EVERY_MAX MINUTES(16)
#define MISCHIEF_EVERY_MIN MINUTES(20)   /* mischief only when nobody has touched it lately */
#define MISCHIEF_EVERY_MAX MINUTES(40)
#define MISCHIEF_QUIET MINUTES(1)
#define CHAT_EVERY_MIN SECONDS(90)       /* an idle voice line */
#define CHAT_EVERY_MAX SECONDS(240)
/* rest holds [6, 6, 12]; signature [4, 2, 8]; mischief [6, 12, 4] (pixl.json). */
enum { REST_0_TICKS = ART_HOLD(6), REST_1_TICKS = ART_HOLD(6) };
enum { TRICK_0 = ART_HOLD(4), TRICK_1 = ART_HOLD(2), TRICK_2 = ART_HOLD(8) };
enum { MISCHIEF_0 = ART_HOLD(6), MISCHIEF_1 = ART_HOLD(12), MISCHIEF_2 = ART_HOLD(4) };
enum { WAKE_STRETCH_TICKS = 12 };

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
    /* Walks and glides: start, target and length (ticks). */
    float from_x, from_y, to_x, to_y;
    uint32_t move_ticks;
    /* Edge crawlers: distance along the screen's edge (SPEC §12.3), and a crawl's start/end. */
    float perim, from_perim, to_perim;

    /* Its own life. */
    uint32_t last_touch, next_nap, next_trick, next_mischief, next_chat;
    uint32_t nap_until;         /* 0 = sleeping until woken */
    bool waking;                /* the stretch after a nap */
    app_game_pose_t emotion;
    uint32_t emotion_ticks;
    app_game_say_t say;

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

static bool floats(app_game_handle_t g)
{
    return g->config.movement == APP_GAME_MOVE_FLOAT;
}

/* Where a Pixl rests: on the floor, or hovering a little above it. */
static float rest_y(app_game_handle_t g)
{
    return floats(g) ? floor_y(g) - HOVER * pet_height(g) : floor_y(g);
}

static float clampf(float v, float lo, float hi)
{
    return v < lo ? lo : (v > hi ? hi : v);
}

/* ---- Edge crawling (a sticky walker: Slugg) ------------------------------------------------
 * The feet follow the screen's edge counterclockwise as the distance grows: along the floor to
 * the right, up the right wall, along the ceiling to the left (upside down), down the left wall.
 * Each straight part keeps half a body clear of the corners. */
static bool perimeter(app_game_handle_t g)
{
    return g->config.movement == APP_GAME_MOVE_WALK && g->config.sticky;
}

static void edge_lengths(app_game_handle_t g, float *across, float *up)
{
    float hw = half_width(g);
    *across = (float)g->config.width - 2.0f * hw;
    *up = (float)g->config.height - 2.0f * hw;
}

static void place_on_edge(app_game_handle_t g, float p)
{
    float across, up, hw = half_width(g), w = (float)g->config.width, h = (float)g->config.height;
    edge_lengths(g, &across, &up);
    float total = 2.0f * (across + up);
    p = fmodf(p, total);
    if (p < 0) {
        p += total;
    }
    g->perim = p;
    if (p < across) {
        g->state.surface = APP_GAME_SURFACE_FLOOR, g->x = hw + p, g->y = h;
    } else if (p < across + up) {
        g->state.surface = APP_GAME_SURFACE_RIGHT_WALL, g->x = w, g->y = h - hw - (p - across);
    } else if (p < 2.0f * across + up) {
        g->state.surface = APP_GAME_SURFACE_CEILING, g->x = w - hw - (p - across - up), g->y = 0;
    } else {
        g->state.surface = APP_GAME_SURFACE_LEFT_WALL, g->x = 0, g->y = hw + (p - 2.0f * across - up);
    }
}

/* Back on whatever it stands on: the floor, or (a crawler) its spot on the edge; floaters stay. */
static void ground(app_game_handle_t g)
{
    if (floats(g)) {
        return;
    }
    if (perimeter(g) && g->state.surface != APP_GAME_SURFACE_FLOOR) {
        place_on_edge(g, g->perim);
        return;
    }
    g->state.surface = APP_GAME_SURFACE_FLOOR;
    g->y = floor_y(g);
    if (perimeter(g)) {
        g->perim = clampf(g->x - half_width(g), 0, (float)g->config.width - 2.0f * half_width(g));
    }
}

static void say(app_game_handle_t g, app_game_say_t what)
{
    g->say = what;
}

static void set_phase(app_game_handle_t g, app_game_pet_phase_t phase)
{
    g->state.phase = phase;
    g->stage_tick = g->state.tick;
    g->state.asleep = false;
}

static void schedule_life(app_game_handle_t g)
{
    uint32_t now = g->state.tick;
    g->next_nap = now + random_ticks(g, NAP_EVERY_MIN, NAP_EVERY_MAX);
    g->next_trick = now + random_ticks(g, TRICK_EVERY_MIN, TRICK_EVERY_MAX);
    g->next_mischief = now + random_ticks(g, MISCHIEF_EVERY_MIN, MISCHIEF_EVERY_MAX);
    g->next_chat = now + random_ticks(g, CHAT_EVERY_MIN, CHAT_EVERY_MAX);
}

static void start_idle(app_game_handle_t g)
{
    set_phase(g, APP_GAME_PET_IDLE);
    g->hop = HOP_NONE;
    g->idle_tick = g->state.tick;
    ground(g);
    g->vx = g->vy = 0;
    g->next_blink = g->state.tick + random_ticks(g, BLINK_GAP_MIN, BLINK_GAP_MAX);
    g->next_wander = g->state.tick + random_ticks(g, WANDER_MIN, WANDER_MAX);
}

static void emote(app_game_handle_t g, app_game_pose_t pose, uint32_t ticks)
{
    set_phase(g, APP_GAME_PET_EMOTING);
    g->emotion = pose;
    g->emotion_ticks = ticks;
    g->vx = g->vy = 0;
    g->state.pose = pose;
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
    game->say = APP_GAME_SAY_NONE;
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
    float hw = half_width(g), h = pet_height(g), fx = (float)x, fy = (float)y;
    if (!touchable(g)) {
        return false;
    }
    switch (g->state.surface) {   /* the body sticks out from the edge it stands on */
    case APP_GAME_SURFACE_RIGHT_WALL:
        return fx >= g->x - h && fx <= g->x && fy >= g->y - hw && fy <= g->y + hw;
    case APP_GAME_SURFACE_CEILING:
        return fx >= g->x - hw && fx <= g->x + hw && fy >= g->y && fy <= g->y + h;
    case APP_GAME_SURFACE_LEFT_WALL:
        return fx >= g->x && fx <= g->x + h && fy >= g->y - hw && fy <= g->y + hw;
    case APP_GAME_SURFACE_FLOOR:
    default:
        return fx >= g->x - hw && fx <= g->x + hw && fy >= g->y - h && fy <= g->y;
    }
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

/* Feet position for a finger at (fx, fy) while held, kept on the screen. */
static void follow_finger(app_game_handle_t g, float fx, float fy)
{
    float hw = half_width(g);
    g->x = clampf(fx + g->grab_dx, hw, (float)g->config.width - hw);
    g->y = clampf(fy + g->grab_dy, pet_height(g), floor_y(g));
}

static void begin_hold(app_game_handle_t g)
{
    if (g->state.surface != APP_GAME_SURFACE_FLOOR) {
        /* Peeled off the wall or ceiling: held upright, feet where the finger's below. */
        g->state.surface = APP_GAME_SURFACE_FLOOR;
        g->x = clampf((float)g->down_x, half_width(g), (float)g->config.width - half_width(g));
        g->y = clampf((float)g->down_y + pet_height(g) / 2.0f, pet_height(g), floor_y(g));
    }
    set_phase(g, APP_GAME_PET_HELD);
    g->hop = HOP_NONE;
    g->vx = g->vy = 0;
    g->grab_dx = g->x - (float)g->down_x;
    g->grab_dy = g->y - (float)g->down_y;
    g->sample_count = 0;
    add_sample(g, (float)g->down_x, (float)g->down_y);
    say(g, APP_GAME_SAY_CURIOUS);
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

static bool resting(app_game_handle_t g)
{
    return g->state.phase == APP_GAME_PET_RESTING;
}

static void poke(app_game_handle_t g)
{
    if (resting(g)) {
        /* Woken by a poke: startled, then grumpy (SPEC §6.2). */
        emote(g, APP_GAME_POSE_STARTLED, SECONDS(2));
        say(g, APP_GAME_SAY_STARTLED);
        return;
    }
    for (int i = 1; i < POKE_ANNOY_COUNT; i++) {
        g->poke_ticks[i - 1] = g->poke_ticks[i];
    }
    g->poke_ticks[POKE_ANNOY_COUNT - 1] = g->state.tick;
    bool annoyed = g->poke_ticks[0] && g->state.tick - g->poke_ticks[0] <= POKE_ANNOY_TICKS;
    g->hop = HOP_NONE;
    ground(g);
    g->vx = g->vy = 0;
    if (annoyed) {
        g->poke_ticks[0] = 0;
        set_phase(g, APP_GAME_PET_SHRUGGING);
        say(g, APP_GAME_SAY_ANNOYED);
    } else {
        set_phase(g, APP_GAME_PET_POKED);
    }
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
    if (pressed) {
        g->last_touch = g->state.tick;
    }

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
    } else if (!pressed && g->was_down) {
        int32_t dx = x - g->down_x, dy = y - g->down_y;
        bool tap = dx * dx + dy * dy <= TAP_SLOP_PX * TAP_SLOP_PX && g->state.tick - g->down_tick <= TAP_MAX_TICKS;
        if (g->down_on_pet && g->state.phase == APP_GAME_PET_HELD) {
            add_sample(g, (float)x, (float)y);
            release_hold(g);
        } else if (tap) {
            /* A tap on the Pixl pokes at once; a second tap anywhere inside the window opens
             * the menu (SPEC §11.1, §11.2). */
            bool second = g->last_tap_tick && g->state.tick - g->last_tap_tick <= DOUBLE_TAP_TICKS;
            g->last_tap_tick = second ? 0 : (g->state.tick ? g->state.tick : 1);
            if (second) {
                g->request = APP_GAME_REQUEST_MENU;
            } else if (g->down_on_pet) {
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

/* A crawl or glide from here to (x, y) over `ticks`. */
static void begin_travel(app_game_handle_t g, float x, float y, uint32_t ticks)
{
    g->from_x = g->x;
    g->from_y = g->y;
    g->to_x = x;
    g->to_y = y;
    g->move_ticks = ticks ? ticks : 1;
    if (x != g->x) {
        g->state.facing = x > g->x ? 1 : -1;
    }
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
    target = clampf(target, lo, hi);
    set_phase(g, APP_GAME_PET_MOVING);
    switch (g->config.movement) {
    case APP_GAME_MOVE_HOP:
        begin_hop(g, target, random_between(g, HOP_APEX_MIN, HOP_APEX_MAX));
        break;
    case APP_GAME_MOVE_WALK: {
        float speed = px(g, g->config.walk_speed > 0 ? g->config.walk_speed : DEFAULT_WALK_SPEED);
        if (perimeter(g)) {
            /* On along the edge, usually the way it was already going (4 times in 5), so it does
             * make it round corners, up the walls and across the ceiling. */
            dir = (next_random(g) % 5u) ? (float)g->state.facing : -(float)g->state.facing;
            float along = random_between(g, 100.0f, 360.0f) * dir;
            g->from_perim = g->perim;
            g->to_perim = g->perim + along;
            g->move_ticks = (uint32_t)(fabsf(along) / speed * (float)TICK_HZ);
            g->state.facing = (int8_t)dir;
            break;
        }
        begin_travel(g, target, floor_y(g), (uint32_t)(fabsf(target - g->x) / speed * (float)TICK_HZ));
        break;
    }
    case APP_GAME_MOVE_FLOAT: {
        /* Anywhere in the air: its own head stays below the top edge. */
        float y = random_between(g, pet_height(g) * 1.3f, rest_y(g));
        begin_travel(g, target, y, random_ticks(g, SECONDS(2), SECONDS(3)));
        break;
    }
    }
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

/* Crawls and glides: eased for floaters, steady for walkers. True when there. */
static bool travel_step(app_game_handle_t g)
{
    uint32_t t = g->state.tick - g->stage_tick;
    float u = t >= g->move_ticks ? 1.0f : (float)t / (float)g->move_ticks;
    if (perimeter(g)) {
        place_on_edge(g, g->from_perim + (g->to_perim - g->from_perim) * u);
        return t >= g->move_ticks;
    }
    if (floats(g)) {
        u = u * u * (3.0f - 2.0f * u);
    }
    g->x = g->from_x + (g->to_x - g->from_x) * u;
    g->y = g->from_y + (g->to_y - g->from_y) * u;
    return t >= g->move_ticks;
}

static void begin_fling(app_game_handle_t g, int edge)
{
    /* Clings half off that edge until the trip settles (SPEC §11.1). */
    set_phase(g, APP_GAME_PET_CLINGING);
    g->state.edge = (int8_t)edge;
    g->state.facing = (int8_t)-edge;
    g->x = edge < 0 ? 0.0f : (float)g->config.width;
    g->y = clampf(g->y, pet_height(g), floor_y(g));
    g->vx = g->vy = 0;
    g->request = APP_GAME_REQUEST_SEND_HOME;
    g->state.waiting = true;
}

/* A thrown Pixl: walls and ceiling bounce; a fast crossing of a side edge is a fling home.
 * Floaters have no gravity: they coast, slow down and stay where they stop. */
static void airborne_step(app_game_handle_t g)
{
    float hw = half_width(g), w = (float)g->config.width, h = pet_height(g);
    if (floats(g)) {
        g->vx *= FLOAT_DRAG;
        g->vy *= FLOAT_DRAG;
    } else {
        g->vy += px(g, GRAVITY_APX) * DT;
    }
    g->x += g->vx * DT;
    g->y += g->vy * DT;

    int edge = g->x - hw < 0 ? -1 : (g->x + hw > w ? 1 : 0);
    if (edge && fabsf(g->vx) >= px(g, FLING_APX) && (g->vx > 0) == (edge > 0)) {
        begin_fling(g, edge);
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
    if (floats(g)) {
        if (g->y > floor_y(g)) {
            g->y = floor_y(g);
            g->vy = -g->vy * RESTITUTION;
        }
        if (sqrtf(g->vx * g->vx + g->vy * g->vy) < px(g, FLOAT_SETTLE_APX)) {
            g->vx = g->vy = 0;
            if (g->shrug_after_landing) {
                g->shrug_after_landing = false;
                set_phase(g, APP_GAME_PET_SHRUGGING);
                say(g, APP_GAME_SAY_SAD);
            } else {
                start_idle(g);
            }
        }
        return;
    }
    if (g->y >= floor_y(g) && g->vy > 0) {
        g->y = floor_y(g);
        if (g->vy > px(g, SETTLE_APX)) {
            g->vy = -g->vy * RESTITUTION;
            g->vx *= 0.6f;
        } else {
            /* Settled: the landing squash, then idle (or the shrug a failed trip owes). */
            g->vx = g->vy = 0;
            set_phase(g, APP_GAME_PET_MOVING);
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
    float hw = half_width(g);
    if (g->config.movement == APP_GAME_MOVE_HOP || g->state.edge) {
        if (g->hop == HOP_CROUCH) {
            g->state.pose = APP_GAME_POSE_CROUCH;
            if (g->state.tick - g->stage_tick >= CROUCH_TICKS) {
                g->hop = HOP_AIR;
            }
            return;
        }
        if (!floats(g)) {
            g->vy += px(g, GRAVITY_APX) * DT;
        }
        g->x += g->vx * DT;
        g->y += g->vy * DT;
        g->state.pose = APP_GAME_POSE_AIR;
    } else {
        /* Walkers crawl off and floaters glide off, at the exit speed. */
        g->x += g->vx * DT;
        g->state.pose = floats(g) ? APP_GAME_POSE_IDLE_0
                        : (app_game_pose_t)(APP_GAME_POSE_CROUCH + (g->state.tick / WALK_FRAME_TICKS) % 3);
    }
    if (g->x < -hw || g->x > (float)g->config.width + hw || g->y > floor_y(g) + pet_height(g)) {
        set_phase(g, APP_GAME_PET_ABSENT);
        g->state.waiting = false;
        g->state.edge = 0;
    }
}

static void begin_rest(app_game_handle_t g, uint32_t length)
{
    set_phase(g, APP_GAME_PET_RESTING);
    g->hop = HOP_NONE;
    g->vx = g->vy = 0;
    g->nap_until = length ? g->state.tick + length : 0;
    g->waking = false;
    say(g, APP_GAME_SAY_SLEEPY);
}

static void begin_trick(app_game_handle_t g)
{
    set_phase(g, APP_GAME_PET_TRICK);
    g->hop = HOP_NONE;
    g->vx = g->vy = 0;
    g->next_trick = g->state.tick + random_ticks(g, TRICK_EVERY_MIN, TRICK_EVERY_MAX);
}

/* Idle: blink, chat, and now and then wander, play a trick, get up to mischief or doze off. */
static void idle_step(app_game_handle_t g)
{
    uint32_t now = g->state.tick;
    if (now >= g->next_blink) {
        g->blink_until = now + BLINK_TICKS;
        g->next_blink = now + random_ticks(g, BLINK_GAP_MIN, BLINK_GAP_MAX);
    }
    if (g->was_down) {
        g->state.pose = idle_pose(g);
        return;
    }
    uint32_t quiet = now - g->last_touch;
    if (quiet >= SLEEP_AFTER || now >= g->next_nap) {
        bool nap = quiet < SLEEP_AFTER;
        g->next_nap = now + random_ticks(g, NAP_EVERY_MIN, NAP_EVERY_MAX);
        begin_rest(g, nap ? random_ticks(g, NAP_LENGTH_MIN, NAP_LENGTH_MAX) : 0);
        g->state.pose = APP_GAME_POSE_REST_0;
        return;
    }
    if (now >= g->next_trick) {
        begin_trick(g);
        g->state.pose = APP_GAME_POSE_TRICK_0;
        return;
    }
    if (now >= g->next_mischief && quiet >= MISCHIEF_QUIET) {
        /* Due, and nobody has touched it for a minute (before it would doze off). */
        g->next_mischief = now + random_ticks(g, MISCHIEF_EVERY_MIN, MISCHIEF_EVERY_MAX);
        set_phase(g, APP_GAME_PET_MISCHIEF);
        g->state.pose = APP_GAME_POSE_MISCHIEF_0;
        return;
    }
    if (now >= g->next_chat) {
        g->next_chat = now + random_ticks(g, CHAT_EVERY_MIN, CHAT_EVERY_MAX);
        say(g, APP_GAME_SAY_IDLE);
    }
    if (now >= g->next_wander) {
        begin_wander(g);
        g->state.pose = g->config.movement == APP_GAME_MOVE_HOP ? APP_GAME_POSE_CROUCH : idle_pose(g);
        return;
    }
    g->state.pose = idle_pose(g);
}

static void rest_step(app_game_handle_t g)
{
    uint32_t t = g->state.tick - g->stage_tick;
    if (g->waking) {
        /* The stretch after a nap, then up. */
        g->state.pose = APP_GAME_POSE_CROUCH;
        if (t >= WAKE_STRETCH_TICKS) {
            start_idle(g);
            g->state.pose = idle_pose(g);
        }
        return;
    }
    if (g->nap_until && g->state.tick >= g->nap_until) {
        g->waking = true;
        g->stage_tick = g->state.tick;
        g->state.pose = APP_GAME_POSE_CROUCH;
        return;
    }
    g->state.pose = t < REST_0_TICKS ? APP_GAME_POSE_REST_0 :
                    t < REST_0_TICKS + REST_1_TICKS ? APP_GAME_POSE_REST_1 : APP_GAME_POSE_REST_2;
    g->state.asleep = t >= REST_0_TICKS;
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
        if (floats(g)) {
            /* Drifts down to its hover height. */
            g->state.pose = APP_GAME_POSE_IDLE_0;
            if (travel_step(g)) {
                emote(g, APP_GAME_POSE_HAPPY, SECONDS(3));
                say(g, APP_GAME_SAY_GREET);
            }
        } else if (g->hop == HOP_AIR) {
            if (fall_step(g)) {
                g->hop = HOP_LAND;
                g->stage_tick = now;
            }
            g->state.pose = APP_GAME_POSE_AIR;
        } else {
            squash = squash_at(t);
            g->state.pose = APP_GAME_POSE_LAND;
            if (t >= 12) {
                emote(g, APP_GAME_POSE_HAPPY, SECONDS(3));
                say(g, APP_GAME_SAY_GREET);
            }
        }
        break;
    case APP_GAME_PET_IDLE:
        idle_step(g);
        break;
    case APP_GAME_PET_MOVING:
        if (g->config.movement == APP_GAME_MOVE_HOP || g->hop != HOP_NONE) {
            if (g->hop == HOP_LAND) {
                squash = squash_at(now - g->stage_tick);
            }
            g->state.pose = hop_pose(g);
            if (!hop_step(g)) {
                break;
            }
        } else {
            g->state.pose = floats(g) ? idle_pose(g) :
                            (app_game_pose_t)(APP_GAME_POSE_CROUCH + (t / WALK_FRAME_TICKS) % 3);
            if (!travel_step(g)) {
                break;
            }
        }
        if (g->shrug_after_landing) {
            g->shrug_after_landing = false;
            set_phase(g, APP_GAME_PET_SHRUGGING);
            g->state.pose = APP_GAME_POSE_ANNOYED;
            say(g, APP_GAME_SAY_SAD);
        } else {
            start_idle(g);
            g->state.pose = idle_pose(g);
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
    case APP_GAME_PET_HELD:
        g->state.pose = t < GRAB_CATCH_TICKS ? APP_GAME_POSE_GRAB_0 : APP_GAME_POSE_GRAB_1;
        break;
    case APP_GAME_PET_AIRBORNE:
        airborne_step(g);
        g->state.pose = g->state.phase == APP_GAME_PET_CLINGING ? APP_GAME_POSE_GRAB_1 :
                        floats(g) ? APP_GAME_POSE_IDLE_0 : APP_GAME_POSE_AIR;
        break;
    case APP_GAME_PET_CLINGING:
        g->state.pose = APP_GAME_POSE_GRAB_1;
        break;
    case APP_GAME_PET_RESTING:
        rest_step(g);
        break;
    case APP_GAME_PET_TRICK:
        g->state.pose = t < TRICK_0 ? APP_GAME_POSE_TRICK_0 :
                        t < TRICK_0 + TRICK_1 ? APP_GAME_POSE_TRICK_1 : APP_GAME_POSE_TRICK_2;
        if (t >= TRICK_0 + TRICK_1 + TRICK_2) {
            emote(g, APP_GAME_POSE_PROUD, SECONDS(3));   /* proud after its signature (SPEC §5) */
            say(g, APP_GAME_SAY_HAPPY);
            g->state.pose = APP_GAME_POSE_PROUD;
        }
        break;
    case APP_GAME_PET_MISCHIEF:
        g->state.pose = t < MISCHIEF_0 ? APP_GAME_POSE_MISCHIEF_0 :
                        t < MISCHIEF_0 + MISCHIEF_1 ? APP_GAME_POSE_MISCHIEF_1 : APP_GAME_POSE_MISCHIEF_2;
        if (t >= MISCHIEF_0 + MISCHIEF_1 + MISCHIEF_2) {
            start_idle(g);
            g->state.pose = idle_pose(g);
        }
        break;
    case APP_GAME_PET_EMOTING:
        g->state.pose = g->emotion;
        if (t >= g->emotion_ticks) {
            start_idle(g);
            g->state.pose = idle_pose(g);
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
    float y = game->y;
    /* Floaters bob gently whenever they aren't being moved (slower while asleep). */
    if (floats(game)) {
        switch (s.phase) {
        case APP_GAME_PET_IDLE:
        case APP_GAME_PET_RESTING:
        case APP_GAME_PET_EMOTING:
        case APP_GAME_PET_POKED:
        case APP_GAME_PET_TRICK:
        case APP_GAME_PET_MISCHIEF:
        case APP_GAME_PET_SHRUGGING: {
            float period = s.phase == APP_GAME_PET_RESTING ? 120.0f : 60.0f;
            y += BOB_PX * sinf(6.2831853f * (float)s.tick / period);
            break;
        }
        default:
            break;
        }
    }
    s.pet_x = (int32_t)lroundf(game->x);
    s.pet_y = (int32_t)lroundf(y);
    if (!s.squash_x) {
        s.squash_x = s.squash_y = 1000;
    }
    return s;
}

void app_game_set_look(app_game_handle_t g, const app_game_config_t *config)
{
    if (!g || !config || !config->scale || config->scale > 16 || !config->pet_w || !config->pet_h) {
        return;
    }
    bool present = g->state.phase != APP_GAME_PET_ABSENT;
    g->config.scale = config->scale;
    g->config.pet_w = config->pet_w;
    g->config.pet_h = config->pet_h;
    g->config.movement = config->movement;
    g->config.walk_speed = config->walk_speed;
    g->config.sticky = config->sticky;
    g->state.surface = APP_GAME_SURFACE_FLOOR;
    if (present && g->state.phase != APP_GAME_PET_CLINGING && g->state.phase != APP_GAME_PET_EXITING) {
        app_game_pet_arrive(g);
    }
}

void app_game_pet_arrive(app_game_handle_t g)
{
    if (!g) {
        return;
    }
    set_phase(g, APP_GAME_PET_ENTERING);
    g->state.surface = APP_GAME_SURFACE_FLOOR;
    g->x = (float)g->config.width / 2.0f;
    g->y = 0.0f;  /* feet at the top edge: the whole body starts above the screen */
    g->vx = g->vy = 0;
    g->hop = floats(g) ? HOP_NONE : HOP_AIR;
    if (floats(g)) {
        begin_travel(g, g->x, rest_y(g), SECONDS(1.5));
    }
    g->state.pose = APP_GAME_POSE_AIR;
    g->state.waiting = false;
    g->state.edge = 0;
    g->down_on_pet = false;
    g->last_touch = g->state.tick;
    schedule_life(g);
}

void app_game_pet_leave(app_game_handle_t g)
{
    if (!g || g->state.phase == APP_GAME_PET_ABSENT) {
        return;
    }
    float dir;
    bool clinging = g->state.phase == APP_GAME_PET_CLINGING;
    if (clinging) {
        dir = (float)g->state.edge;  /* out through the edge it holds */
    } else {
        if (!floats(g)) {
            g->state.surface = APP_GAME_SURFACE_FLOOR;   /* a crawler drops off the wall first */
            g->x = clampf(g->x, half_width(g), (float)g->config.width - half_width(g));
            g->y = floor_y(g);
        }
        dir = g->x < (float)g->config.width / 2.0f ? -1.0f : 1.0f;  /* off the nearer side */
    }
    set_phase(g, APP_GAME_PET_EXITING);
    g->vx = dir * px(g, EXIT_SPEED);
    g->vy = (clinging || g->config.movement == APP_GAME_MOVE_HOP) && !floats(g)
            ? -sqrtf(2.0f * px(g, GRAVITY_APX) * px(g, EXIT_APEX)) : 0.0f;
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
        g->vx = inward * px(g, floats(g) ? 400.0f : 200.0f);
        g->vy = floats(g) ? 0.0f : -px(g, 150.0f);
        g->state.facing = (int8_t)inward;
        g->shrug_after_landing = true;
    } else if (touchable(g) && g->state.phase != APP_GAME_PET_HELD && g->state.phase != APP_GAME_PET_AIRBORNE) {
        ground(g);
        g->hop = HOP_NONE;
        set_phase(g, APP_GAME_PET_SHRUGGING);
        say(g, APP_GAME_SAY_SAD);
    }
}

/* Only a Pixl standing (or hovering) still can start something new from the menu. */
static bool settled(app_game_handle_t g)
{
    switch (g->state.phase) {
    case APP_GAME_PET_IDLE:
    case APP_GAME_PET_RESTING:
    case APP_GAME_PET_EMOTING:
    case APP_GAME_PET_POKED:
    case APP_GAME_PET_SHRUGGING:
        return true;
    default:
        return false;
    }
}

void app_game_trick(app_game_handle_t g)
{
    if (g && settled(g)) {
        g->last_touch = g->state.tick;
        begin_trick(g);
    }
}

void app_game_nap(app_game_handle_t g)
{
    if (g && settled(g) && !resting(g)) {
        begin_rest(g, random_ticks(g, NAP_LENGTH_MIN, NAP_LENGTH_MAX));
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

app_game_say_t app_game_take_say(app_game_handle_t g)
{
    if (!g) {
        return APP_GAME_SAY_NONE;
    }
    app_game_say_t s = g->say;
    g->say = APP_GAME_SAY_NONE;
    return s;
}
