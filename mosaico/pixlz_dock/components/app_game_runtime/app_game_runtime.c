// SPDX-License-Identifier: Apache-2.0
#include <stdio.h>
#include "include/app_game_runtime.h"
/* Engine Host accepts source lists, not component include paths. Reference only
 * public headers by relative path so these translation units work on both targets. */
#include "../app_game/include/app_game.h"
#include "../app_dock/include/app_dock.h"
#include "private/game_config.h"
#include "private/frogg_sprites.h"
#include "raylib_lite_raylib.h"

/* Screen dims when nobody touches it (SPEC §12.1): 50% after 2 min, 10% after 10 min. */
enum { DIM_HALF_TICKS = 2 * 60 * GAME_TICK_HZ, DIM_LOW_TICKS = 10 * 60 * GAME_TICK_HZ };
enum { MAX_EVENTS = 4 };

typedef struct {
    app_game_handle_t game;
    app_dock_handle_t dock;
    uint8_t scale;
    uint32_t last_touch_tick;
    app_dock_event_t events[MAX_EVENTS];
} host_state_t;

/* Pet scale (SPEC §12.2): pixl.json scale.mosaico, else ~4 pet-widths across the screen. */
static uint8_t pet_scale(void)
{
    if (FROGG_SCALE_MOSAICO > 0) {
        return FROGG_SCALE_MOSAICO;
    }
    unsigned w = frogg_frames[FROGG_IDLE_0].w;
    unsigned s = (2u * GAME_WIDTH + 4u * w) / (8u * w); /* round(width / (4 w)) */
    return (uint8_t)(s < 1 ? 1 : s);
}

static int initialize(void *value, const char *asset_root)
{
    (void)asset_root;
    host_state_t *state = value;
    state->scale = pet_scale();
    const app_game_config_t config = {
        GAME_WIDTH, GAME_HEIGHT, state->scale,
        frogg_frames[FROGG_IDLE_0].w, frogg_frames[FROGG_IDLE_0].h, 0x5EEDF0u
    };
    if (app_game_create(&config, &state->game) != APP_GAME_OK) {
        return -1;
    }
    state->dock = app_dock_create();
    if (!state->dock) {
        app_game_destroy(&state->game);
        return -1;
    }
    if (app_dock_status(state->dock).owns_pet) {
        app_game_pet_arrive(state->game);
    }
    InitWindow(GAME_WIDTH, GAME_HEIGHT, GAME_NAME);
    SetTargetFPS(GAME_TICK_HZ);
    return 0;
}

static void shutdown(void *value)
{
    host_state_t *state = value;
    app_dock_destroy(&state->dock);
    app_game_destroy(&state->game);
}

static void input(void *value, const raylib_lite_game_input_v1_t *event)
{
    host_state_t *state = value;
    if (!event) {
        return;
    }
    if (event->type == RAYLIB_LITE_GAME_INPUT_POINTER && event->track_id == 0) {
        app_game_set_pointer(state->game, event->x, event->y, event->pressed);
        state->last_touch_tick = app_game_read(state->game).tick;
    } else if (event->type == RAYLIB_LITE_GAME_INPUT_CONTROL) {
        switch (event->code) {
        case RAYLIB_LITE_GAME_CONTROL_PAUSE: app_game_set_paused(state->game, true); break;
        case RAYLIB_LITE_GAME_CONTROL_RESUME: app_game_set_paused(state->game, false); break;
        default: break;
        }
    } else if (event->type == RAYLIB_LITE_GAME_INPUT_ACTION && event->pressed) {
        if (event->code == GAME_ACTION_PAUSE) {
            app_game_set_paused(state->game, !app_game_read(state->game).paused);
        }
    }
}

static void update(void *value)
{
    host_state_t *state = value;
    app_game_update(state->game);
    if (app_game_take_request(state->game) == APP_GAME_REQUEST_SEND_HOME) {
        app_dock_send_home(state->dock);
    }
    int n = app_dock_poll(state->dock, state->events, MAX_EVENTS);
    for (int i = 0; i < n; i++) {
        switch (state->events[i].kind) {
        case APP_DOCK_EVENT_ARRIVED: app_game_pet_arrive(state->game); break;
        case APP_DOCK_EVENT_LEFT: app_game_pet_leave(state->game); break;
        case APP_DOCK_EVENT_SHRUG: app_game_pet_shrug(state->game); break;
        }
    }
}

static int frame_for(app_game_pose_t pose)
{
    switch (pose) {
    case APP_GAME_POSE_IDLE_1: return FROGG_IDLE_1;
    case APP_GAME_POSE_IDLE_2: return FROGG_IDLE_2;
    case APP_GAME_POSE_BLINK: return FROGG_BLINK;
    case APP_GAME_POSE_CROUCH: return FROGG_MOVE_0;
    case APP_GAME_POSE_AIR: return FROGG_MOVE_1;
    case APP_GAME_POSE_LAND: return FROGG_MOVE_2;
    case APP_GAME_POSE_ANNOYED: return FROGG_EMOTION_ANNOYED;
    case APP_GAME_POSE_POKE_0: return FROGG_POKE_0;
    case APP_GAME_POSE_POKE_1: return FROGG_POKE_1;
    case APP_GAME_POSE_POKE_2: return FROGG_POKE_2;
    case APP_GAME_POSE_GRAB_0: return FROGG_GRAB_0;
    case APP_GAME_POSE_GRAB_1: return FROGG_GRAB_1;
    case APP_GAME_POSE_HAPPY: return FROGG_EMOTION_HAPPY;
    case APP_GAME_POSE_IDLE_0:
    default: return FROGG_IDLE_0;
    }
}

/* Floor division that rounds toward -inf, so runs tile exactly with no gaps or overlaps. */
static int fdiv(long a, long b)
{
    return (int)(a >= 0 ? a / b : -((-a + b - 1) / b));
}

/* Draws one frame bottom-centred on the feet, mirrored when facing left, at a whole-number
 * scale; squash stretches pixel edges on whole pixels, so nothing is ever blurred. */
static void draw_pet(const app_game_snapshot_t *s, uint8_t scale, unsigned brightness)
{
    const pixl_frame_t *f = &frogg_frames[frame_for(s->pose)];
    long sx = (long)scale * s->squash_x; /* pixels per art pixel, in 1/1000 */
    long sy = (long)scale * s->squash_y;
    long left = (long)s->pet_x * 1000 - (long)f->w * sx / 2;
    long bottom = (long)s->pet_y * 1000;
    for (uint16_t i = 0; i < f->count; i++) {
        const pixl_run_t *r = &f->runs[i];
        int ax = s->facing < 0 ? f->w - r->x - r->len : r->x;
        int x0 = fdiv(left + ax * sx, 1000), x1 = fdiv(left + (ax + r->len) * sx, 1000);
        int y0 = fdiv(bottom - (long)(f->h - r->y) * sy, 1000);
        int y1 = fdiv(bottom - (long)(f->h - r->y - 1) * sy, 1000);
        if (x1 <= x0 || y1 <= y0) {
            continue;
        }
        const uint8_t *c = frogg_palette[r->colour];
        Color colour = {(unsigned char)(c[0] * brightness / 100), (unsigned char)(c[1] * brightness / 100),
                        (unsigned char)(c[2] * brightness / 100), 255};
        DrawRectangle(x0, y0, x1 - x0, y1 - y0, colour);
    }
}

/* Low battery (on battery only): warn at 25% and below, red and blinking at 10% and below. */
enum { BATTERY_WARN = 25, BATTERY_CRITICAL = 10 };

/* 3x5 pixel digits and '%', one bit per pixel, rows top to bottom. */
static const uint8_t DIGITS[11][5] = {
    {7, 5, 5, 5, 7}, {2, 6, 2, 2, 7}, {7, 1, 7, 4, 7}, {7, 1, 3, 1, 7}, {5, 5, 7, 1, 1},
    {7, 4, 7, 1, 7}, {7, 4, 7, 5, 7}, {7, 1, 1, 2, 2}, {7, 5, 7, 5, 7}, {7, 5, 7, 1, 7},
    {5, 1, 2, 4, 5},
};

static void draw_glyph(int index, int x, int y, int px, Color colour)
{
    for (int row = 0; row < 5; row++) {
        for (int col = 0; col < 3; col++) {
            if (DIGITS[index][row] & (4 >> col)) {
                DrawRectangle(x + col * px, y + row * px, px, px, colour);
            }
        }
    }
}

/* A small battery with its level and the percentage, at the top. It drifts a few pixels each
 * minute so it never burns into the AMOLED (SPEC §12.1). */
static void draw_battery(int percent, uint32_t tick, unsigned brightness)
{
    bool critical = percent <= BATTERY_CRITICAL;
    if (critical && (tick / 15) % 2) {
        return; /* blink at 1 Hz */
    }
    const unsigned char r = critical ? 230 : 245, g = critical ? 70 : 180, b = critical ? 60 : 40;
    Color colour = {(unsigned char)(r * brightness / 100), (unsigned char)(g * brightness / 100),
                    (unsigned char)(b * brightness / 100), 255};
    const int px = 3, w = 36, h = 18;
    int x = GAME_WIDTH / 2 - 44 + (int)((tick / (60 * GAME_TICK_HZ)) % 5) * 4 - 8, y = 24;
    DrawRectangleLines(x, y, w, h, colour);
    DrawRectangle(x + w, y + 5, 3, h - 10, colour);
    int fill = (w - 6) * (percent < 0 ? 0 : percent) / 100;
    DrawRectangle(x + 3, y + 3, fill > 1 ? fill : 1, h - 6, colour);
    int tx = x + w + 10;
    if (percent >= 10) {
        draw_glyph(percent / 10 % 10, tx, y + 2, px, colour);
        tx += 4 * px;
    }
    draw_glyph(percent % 10, tx, y + 2, px, colour);
    draw_glyph(10, tx + 4 * px, y + 2, px, colour);
}

/* "…" above the head while a trip is pending. */
static void draw_waiting(const app_game_snapshot_t *s, uint8_t scale, unsigned brightness)
{
    int top = s->pet_y - frogg_frames[FROGG_IDLE_0].h * scale - 6 * scale;
    unsigned char v = (unsigned char)(230 * brightness / 100);
    Color colour = {v, v, v, 255};
    int dot = 2 * scale, phase = (int)(s->tick / 8 % 3);
    /* At an edge the head is half off screen: put the dots on the inside. */
    int cx = s->edge < 0 ? s->pet_x + 10 * dot : (s->edge > 0 ? s->pet_x - 10 * dot : s->pet_x);
    for (int i = 0; i < 3; i++) {
        int lift = i == phase ? scale : 0;
        DrawRectangle(cx - 4 * dot + i * 3 * dot, top - lift, dot, dot, colour);
    }
}

static int render(void *value)
{
    host_state_t *state = value;
    if (!state->game) {
        return -1;
    }
    BeginDrawing();
    if (!raylib_lite_raylib_frame_available()) {
        EndDrawing();
        return -1;
    }
    ClearBackground(BLACK);
    const app_game_snapshot_t s = app_game_read(state->game);
    uint32_t idle = s.tick - state->last_touch_tick;
    unsigned brightness = idle >= DIM_LOW_TICKS ? 10 : (idle >= DIM_HALF_TICKS ? 50 : 100);
    if (s.phase != APP_GAME_PET_ABSENT) {
        draw_pet(&s, state->scale, brightness);
        if (s.waiting) {
            draw_waiting(&s, state->scale, brightness);
        }
    }
    const app_dock_status_t dock = app_dock_status(state->dock);
    if (dock.on_battery && dock.battery_percent >= 0 && dock.battery_percent <= BATTERY_WARN) {
        draw_battery(dock.battery_percent, s.tick, brightness < 50 ? 50 : brightness);
    }
    EndDrawing();
    return 0;
}

static const char *phase_name(app_game_pet_phase_t p)
{
    static const char *const names[] = {"absent", "entering", "idle", "hopping", "exiting", "shrugging",
                                        "poked", "happy", "held", "airborne", "clinging"};
    return (unsigned)p < sizeof names / sizeof names[0] ? names[p] : "?";
}

static uint32_t state_hash(const void *value)
{
    const app_game_snapshot_t s = app_game_read(((const host_state_t *)value)->game);
    /* Hash named fields, avoiding platform-dependent struct padding. */
    uint32_t hash = s.tick;
    hash = hash * 31U + (uint32_t)s.pointer_x;
    hash = hash * 31U + (uint32_t)s.pointer_y;
    hash = hash * 31U + s.pointer_down;
    hash = hash * 31U + s.paused;
    hash = hash * 31U + (uint32_t)s.phase;
    hash = hash * 31U + (uint32_t)s.pose;
    hash = hash * 31U + (uint32_t)s.pet_x;
    return hash * 31U + (uint32_t)s.pet_y;
}

static int state_json(const void *value, char *output, size_t capacity)
{
    if (!output || !capacity) {
        return -1;
    }
    const host_state_t *state = value;
    const app_game_snapshot_t s = app_game_read(state->game);
    const app_dock_status_t d = app_dock_status(state->dock);
    int size = snprintf(output, capacity,
                        "{\"phase\":\"%s\",\"tick\":%lu,\"pointer_x\":%ld,\"pointer_y\":%ld,"
                        "\"pointer_down\":%s,\"pet\":\"%s\",\"pose\":%d,\"pet_x\":%ld,\"pet_y\":%ld,"
                        "\"scale\":%u,\"waiting\":%s,\"macs\":%d,\"owns_pet\":%s,\"in_trip\":%s,"
                        "\"battery\":%d,\"on_battery\":%s,"
                        "\"state_hash\":\"%08lx\"}",
                        s.paused ? "paused" : "running", (unsigned long)s.tick, (long)s.pointer_x,
                        (long)s.pointer_y, s.pointer_down ? "true" : "false", phase_name(s.phase), (int)s.pose,
                        (long)s.pet_x, (long)s.pet_y, (unsigned)state->scale, s.waiting ? "true" : "false",
                        d.macs, d.owns_pet ? "true" : "false", d.in_trip ? "true" : "false",
                        d.battery_percent, d.on_battery ? "true" : "false",
                        (unsigned long)state_hash(value));
    return size < 0 || (size_t)size >= capacity ? -1 : size;
}

static const raylib_lite_game_module_v1_t s_module = {
    .descriptor = {
        RAYLIB_LITE_GAME_MODULE_ABI_V1, GAME_NAME, GAME_NAME,
        GAME_WIDTH, GAME_HEIGHT, GAME_TICK_HZ, 1
    },
    .state_size = sizeof(host_state_t),
    .initialize = initialize, .shutdown = shutdown, .input = input,
    .update = update, .render = render,
    .state_hash = state_hash, .state_json = state_json,
};

const raylib_lite_game_module_v1_t *app_game_runtime_module(void)
{
    return &s_module;
}
