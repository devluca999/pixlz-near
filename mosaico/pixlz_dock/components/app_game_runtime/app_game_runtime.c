// SPDX-License-Identifier: Apache-2.0
#include <stdio.h>
#include <string.h>
#include "include/app_game_runtime.h"
/* Engine Host accepts source lists, not component include paths. Reference only
 * public headers by relative path so these translation units work on both targets. */
#include "../app_game/include/app_game.h"
#include "../app_dock/include/app_dock.h"
#include "../app_menu/include/app_menu.h"
#include "private/game_config.h"
#include "private/pixl_font.h"
#include "private/pixl_pets.h"
#include "raylib_lite_raylib.h"

/* Screen dims when nobody touches it (SPEC §12.1): 50% after 2 min, 10% after 10 min. */
enum { DIM_HALF_TICKS = 2 * 60 * GAME_TICK_HZ, DIM_LOW_TICKS = 10 * 60 * GAME_TICK_HZ };
/* Low battery (on battery only): warn at 25% and below, red and blinking at 10% and below. */
enum { BATTERY_WARN = 25, BATTERY_CRITICAL = 10 };
enum { MAX_EVENTS = 4, SPEECH_TICKS = 75, SPEECH_MAX = 40 };

typedef struct {
    app_game_handle_t game;
    app_dock_handle_t dock;
    app_menu_handle_t menu;
    int look;                 /* index into pixl_pets */
    uint8_t scale;
    uint32_t last_touch_tick;
    bool sending;             /* a menu "Send home" is waiting on the trip */
    char speech[SPEECH_MAX];
    uint32_t speech_until;
    int last_line;
    app_dock_event_t events[MAX_EVENTS];
} host_state_t;

static const char *s_species[PIXL_PET_COUNT];

/* ---------------------------------------------------------------------------------------- */
/* Looks */

/* Pet scale (SPEC §12.2): pixl.json scale.mosaico, else ~4 pet-widths across the screen. */
static uint8_t scale_for(const pixl_pet_t *pet)
{
    if (pet->scale_mosaico > 0) {
        return pet->scale_mosaico;
    }
    unsigned w = pet->frames[PIXL_F_IDLE_0].w;
    unsigned s = (2u * GAME_WIDTH + 4u * w) / (8u * w); /* round(width / (4 w)) */
    return (uint8_t)(s < 1 ? 1 : s);
}

static int look_index(const char *id)
{
    for (int i = 0; i < PIXL_PET_COUNT; i++) {
        if (id && strcmp(id, pixl_pets[i].id) == 0) {
            return i;
        }
    }
    return -1;
}

static app_game_config_t config_for(int look, uint32_t seed)
{
    const pixl_pet_t *pet = &pixl_pets[look];
    app_game_config_t c = {
        GAME_WIDTH, GAME_HEIGHT, scale_for(pet),
        pet->frames[PIXL_F_IDLE_0].w, pet->frames[PIXL_F_IDLE_0].h, seed,
        pet->movement == PIXL_MOVE_FLOAT ? APP_GAME_MOVE_FLOAT :
        pet->movement == PIXL_MOVE_WALK ? APP_GAME_MOVE_WALK : APP_GAME_MOVE_HOP,
        pet->walk_speed,
    };
    return c;
}

/* The saved swap choice, else the visiting Pixl's own species, else Frogg. */
static int initial_look(host_state_t *state)
{
    char id[24] = "";
    app_dock_load_look(id, sizeof id);
    int i = look_index(id);
    if (i < 0 && app_dock_pet_species(state->dock, id, sizeof id)) {
        i = look_index(id);
    }
    return i < 0 ? 0 : i;
}

/* ---------------------------------------------------------------------------------------- */
/* Lifecycle */

static int initialize(void *value, const char *asset_root)
{
    (void)asset_root;
    host_state_t *state = value;
    state->dock = app_dock_create();
    state->menu = app_menu_create(GAME_WIDTH, GAME_HEIGHT);
    if (!state->dock || !state->menu) {
        app_dock_destroy(&state->dock);
        app_menu_destroy(&state->menu);
        return -1;
    }
    for (int i = 0; i < PIXL_PET_COUNT; i++) {
        s_species[i] = pixl_pets[i].id;
    }
    app_dock_set_known_species(state->dock, s_species, PIXL_PET_COUNT);
    state->look = initial_look(state);
    const app_game_config_t config = config_for(state->look, 0x5EEDF0u);
    state->scale = config.scale;
    state->last_line = -1;
    if (app_game_create(&config, &state->game) != APP_GAME_OK) {
        app_dock_destroy(&state->dock);
        app_menu_destroy(&state->menu);
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
    app_menu_destroy(&state->menu);
    app_game_destroy(&state->game);
}

static void input(void *value, const raylib_lite_game_input_v1_t *event)
{
    host_state_t *state = value;
    if (!event) {
        return;
    }
    if (event->type == RAYLIB_LITE_GAME_INPUT_POINTER && event->track_id == 0) {
        state->last_touch_tick = app_game_read(state->game).tick;
        /* The menu sees touches first while it's open; the Pixl never sees those. */
        if (!app_menu_pointer(state->menu, event->x, event->y, event->pressed)) {
            app_game_set_pointer(state->game, event->x, event->y, event->pressed);
        }
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

/* A voice line for the event, never the same one twice in a row (Mac: VoicePicker). */
static void speak(host_state_t *state, app_game_say_t event, uint32_t tick)
{
    const int index = (int)event;
    if (index < 0 || index >= (int)PIXL_SOUND_COUNT) {
        return;
    }
    const char *const *lines = pixl_pets[state->look].sounds[index];
    int count = 0;
    while (count < PIXL_SOUND_LINES && lines[count]) {
        count++;
    }
    if (!count) {
        return;
    }
    int pick = (int)(tick % (uint32_t)count);
    if (count > 1 && pick == state->last_line) {
        pick = (pick + 1) % count;
    }
    state->last_line = pick;
    snprintf(state->speech, sizeof state->speech, "%s", lines[pick]);
    state->speech_until = tick + SPEECH_TICKS;
}

static void open_menu(host_state_t *state)
{
    const app_dock_status_t d = app_dock_status(state->dock);
    const app_game_snapshot_t s = app_game_read(state->game);
    const bool here = s.phase != APP_GAME_PET_ABSENT && s.phase != APP_GAME_PET_EXITING;
    const app_menu_context_t ctx = {
        d.macs > 0 && d.owns_pet && !d.locked && !d.in_trip && here,
        d.locked, d.owns_pet && here, state->look, PIXL_PET_COUNT,
    };
    app_menu_open(state->menu, &ctx);
}

static void apply_menu(host_state_t *state, app_menu_action_t a)
{
    switch (a.kind) {
    case APP_MENU_ACTION_SEND_HOME:
        state->sending = true;
        app_dock_send_home(state->dock);
        break;
    case APP_MENU_ACTION_TRICK: app_game_trick(state->game); break;
    case APP_MENU_ACTION_NAP: app_game_nap(state->game); break;
    case APP_MENU_ACTION_LOCK: (void)app_dock_set_locked(state->dock, a.arg != 0); break;
    case APP_MENU_ACTION_SWAP:
        if (a.arg >= 0 && a.arg < PIXL_PET_COUNT && a.arg != state->look) {
            state->look = a.arg;
            app_dock_save_look(pixl_pets[a.arg].id);
            const app_game_config_t c = config_for(a.arg, 0);
            state->scale = c.scale;
            state->last_line = -1;
            app_game_set_look(state->game, &c);
        }
        break;
    case APP_MENU_ACTION_NONE: break;
    }
}

static void update(void *value)
{
    host_state_t *state = value;
    app_game_update(state->game);
    app_menu_update(state->menu);
    switch (app_game_take_request(state->game)) {
    case APP_GAME_REQUEST_SEND_HOME: app_dock_send_home(state->dock); break;
    case APP_GAME_REQUEST_MENU: open_menu(state); break;
    case APP_GAME_REQUEST_NONE: break;
    }
    apply_menu(state, app_menu_take_action(state->menu));
    const uint32_t tick = app_game_read(state->game).tick;
    speak(state, app_game_take_say(state->game), tick);
    int n = app_dock_poll(state->dock, state->events, MAX_EVENTS);
    for (int i = 0; i < n; i++) {
        switch (state->events[i].kind) {
        case APP_DOCK_EVENT_ARRIVED: {
            /* A visitor of another species shows as itself unless this device chose a look. */
            char id[24] = "", saved[24] = "";
            app_dock_load_look(saved, sizeof saved);
            if (!saved[0] && app_dock_pet_species(state->dock, id, sizeof id) && look_index(id) >= 0 &&
                    look_index(id) != state->look) {
                state->look = look_index(id);
                const app_game_config_t c = config_for(state->look, 0);
                state->scale = c.scale;
                app_game_set_look(state->game, &c);
            }
            app_game_pet_arrive(state->game);
            break;
        }
        case APP_DOCK_EVENT_LEFT: state->sending = false; app_game_pet_leave(state->game); break;
        case APP_DOCK_EVENT_SHRUG: state->sending = false; app_game_pet_shrug(state->game); break;
        }
    }
}

/* ---------------------------------------------------------------------------------------- */
/* Drawing */

static Color shade(uint8_t r, uint8_t g, uint8_t b, unsigned brightness)
{
    Color c = {(unsigned char)(r * brightness / 100), (unsigned char)(g * brightness / 100),
               (unsigned char)(b * brightness / 100), 255};
    return c;
}

static const pixl_glyph_t *glyph(char c)
{
    if (c < PIXL_FONT_FIRST || c > PIXL_FONT_LAST) {
        c = '?';
    }
    return &pixl_font[c - PIXL_FONT_FIRST];
}

static int text_width(const char *text, int scale)
{
    int w = 0;
    for (const char *p = text; *p; p++) {
        w += (glyph(*p)->width + 1) * scale;
    }
    return w > 0 ? w - scale : 0;
}

/* raylib's pixel font, whole-pixel scaled. */
static void draw_text(const char *text, int x, int y, int scale, Color colour)
{
    for (const char *p = text; *p; p++) {
        const pixl_glyph_t *g = glyph(*p);
        for (int row = 0; row < PIXL_FONT_HEIGHT; row++) {
            uint16_t bits = g->rows[row];
            for (int col = 0; bits; col++, bits >>= 1) {
                if (bits & 1) {
                    DrawRectangle(x + col * scale, y + row * scale, scale, scale, colour);
                }
            }
        }
        x += (g->width + 1) * scale;
    }
}

static void draw_text_centred(const char *text, int cx, int y, int scale, Color colour)
{
    draw_text(text, cx - text_width(text, scale) / 2, y, scale, colour);
}

/* Floor division that rounds toward -inf, so runs tile exactly with no gaps or overlaps. */
static int fdiv(long a, long b)
{
    return (int)(a >= 0 ? a / b : -((-a + b - 1) / b));
}

/* One frame bottom-centred on the feet, mirrored when facing left, at a whole-number scale;
 * squash stretches pixel edges on whole pixels, so nothing is ever blurred. */
static void draw_frame(const pixl_pet_t *pet, int frame, int fx, int fy, int facing, uint8_t scale,
                       uint16_t squash_x, uint16_t squash_y, unsigned brightness)
{
    const pixl_frame_t *f = &pet->frames[frame];
    long sx = (long)scale * squash_x; /* pixels per art pixel, in 1/1000 */
    long sy = (long)scale * squash_y;
    long left = (long)fx * 1000 - (long)f->w * sx / 2;
    long bottom = (long)fy * 1000;
    for (uint16_t i = 0; i < f->count; i++) {
        const pixl_run_t *r = &f->runs[i];
        int ax = facing < 0 ? f->w - r->x - r->len : r->x;
        int x0 = fdiv(left + ax * sx, 1000), x1 = fdiv(left + (ax + r->len) * sx, 1000);
        int y0 = fdiv(bottom - (long)(f->h - r->y) * sy, 1000);
        int y1 = fdiv(bottom - (long)(f->h - r->y - 1) * sy, 1000);
        if (x1 <= x0 || y1 <= y0) {
            continue;
        }
        const uint8_t *c = pet->palette[r->colour];
        DrawRectangle(x0, y0, x1 - x0, y1 - y0, shade(c[0], c[1], c[2], brightness));
    }
}

static int head_y(const host_state_t *state, const app_game_snapshot_t *s)
{
    return s->pet_y - pixl_pets[state->look].frames[PIXL_F_IDLE_0].h * state->scale;
}

/* "…" above the head while a trip is pending; at an edge, on the inside. */
static void draw_waiting(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    const int scale = state->scale;
    int top = head_y(state, s) - 6 * scale;
    Color colour = shade(230, 230, 230, brightness);
    int dot = 2 * scale, phase = (int)(s->tick / 8 % 3);
    int cx = s->edge < 0 ? s->pet_x + 10 * dot : (s->edge > 0 ? s->pet_x - 10 * dot : s->pet_x);
    for (int i = 0; i < 3; i++) {
        int lift = i == phase ? scale : 0;
        DrawRectangle(cx - 4 * dot + i * 3 * dot, top - lift, dot, dot, colour);
    }
}

/* Zz drifting up from the head while asleep. */
static void draw_zz(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    static const char *const letters[3] = {"z", "z", "Z"};
    int base = head_y(state, s);
    for (int i = 0; i < 3; i++) {
        uint32_t t = (s->tick + (uint32_t)i * 30) % 90;
        int y = base - (int)t / 2 - 4;
        int x = s->pet_x + s->facing * 18 + i * 10;
        unsigned fade = t < 60 ? brightness : brightness * (90 - t) / 30;
        draw_text(letters[i], x, y, 2 + (i == 2), shade(160, 200, 255, fade));
    }
}

/* The species' own sound, in a paper bubble above the head (SPEC §11.6, voice). */
static void draw_speech(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    const int scale = 2, pad = 8;
    int w = text_width(state->speech, scale) + 2 * pad, h = PIXL_FONT_HEIGHT * scale + 2 * pad - 4;
    int cx = s->pet_x, bottom = head_y(state, s) - 10;
    int x = cx - w / 2;
    if (x < 8) x = 8;
    if (x + w > GAME_WIDTH - 8) x = GAME_WIDTH - 8 - w;
    int y = bottom - h;
    if (y < 8) y = 8;
    Color ink = shade(27, 42, 26, brightness), paper = shade(255, 251, 242, brightness);
    DrawRectangle(x - 2, y - 2, w + 4, h + 4, ink);
    DrawRectangle(x, y, w, h, paper);
    int tail = cx < x + 16 ? x + 16 : (cx > x + w - 16 ? x + w - 16 : cx);
    for (int i = 0; i < 4; i++) {
        DrawRectangle(tail - 4 + i, y + h + i * 2, 8 - 2 * i, 2, i == 0 ? paper : ink);
    }
    draw_text(state->speech, x + pad, y + pad - 2, scale, ink);
}

/* 3x5 digits and '%' for the battery. */
static const uint8_t DIGITS[11][5] = {
    {7, 5, 5, 5, 7}, {2, 6, 2, 2, 7}, {7, 1, 7, 4, 7}, {7, 1, 3, 1, 7}, {5, 5, 7, 1, 1},
    {7, 4, 7, 1, 7}, {7, 4, 7, 5, 7}, {7, 1, 1, 2, 2}, {7, 5, 7, 5, 7}, {7, 5, 7, 1, 7},
    {5, 1, 2, 4, 5},
};

static void draw_digit(int index, int x, int y, int px, Color colour)
{
    for (int row = 0; row < 5; row++) {
        for (int col = 0; col < 3; col++) {
            if (DIGITS[index][row] & (4 >> col)) {
                DrawRectangle(x + col * px, y + row * px, px, px, colour);
            }
        }
    }
}

/* A small battery with its level and the percentage, at the top; drifts a few pixels each
 * minute so it never burns into the AMOLED (SPEC §12.1). */
static void draw_battery(int percent, uint32_t tick, unsigned brightness)
{
    bool critical = percent <= BATTERY_CRITICAL;
    if (critical && (tick / 15) % 2) {
        return; /* blink at 1 Hz */
    }
    Color colour = critical ? shade(230, 70, 60, brightness) : shade(245, 180, 40, brightness);
    const int px = 3, w = 36, h = 18;
    int x = GAME_WIDTH / 2 - 44 + (int)((tick / (60 * GAME_TICK_HZ)) % 5) * 4 - 8, y = 24;
    DrawRectangleLines(x, y, w, h, colour);
    DrawRectangle(x + w, y + 5, 3, h - 10, colour);
    int fill = (w - 6) * (percent < 0 ? 0 : percent) / 100;
    DrawRectangle(x + 3, y + 3, fill > 1 ? fill : 1, h - 6, colour);
    int tx = x + w + 10;
    if (percent >= 10) {
        draw_digit(percent / 10 % 10, tx, y + 2, px, colour);
        tx += 4 * px;
    }
    draw_digit(percent % 10, tx, y + 2, px, colour);
    draw_digit(10, tx + 4 * px, y + 2, px, colour);
}

static const char *bubble_label(app_menu_bubble_t b)
{
    switch (b) {
    case APP_MENU_BUBBLE_SEND: return "Home";
    case APP_MENU_BUBBLE_TRICK: return "Trick";
    case APP_MENU_BUBBLE_SWAP: return "Swap";
    case APP_MENU_BUBBLE_MORE: return "More";
    case APP_MENU_BUBBLE_LOCK: return "Lock";
    case APP_MENU_BUBBLE_UNLOCK: return "Unlock";
    case APP_MENU_BUBBLE_NAP: return "Nap";
    case APP_MENU_BUBBLE_BACK: return "Back";
    default: return "";
    }
}

/* Four bubbles in the Pixl's accent colour; greyed when they can't be used. */
static void draw_menu(const host_state_t *state, const app_menu_snapshot_t *m)
{
    const uint8_t *accent = pixl_pets[state->look].accent;
    for (int i = 0; i < APP_MENU_SLOTS; i++) {
        const app_menu_slot_t *slot = &m->slots[i];
        if (slot->bubble == APP_MENU_BUBBLE_NONE || !slot->scale) {
            continue;
        }
        float r = (float)m->radius * (float)slot->scale / 1000.0f;
        Color fill = slot->enabled ? shade(accent[0], accent[1], accent[2], 100) : shade(70, 70, 70, 100);
        DrawCircle(slot->x, slot->y, r + 3, shade(27, 42, 26, 100));
        DrawCircle(slot->x, slot->y, r, fill);
        if (slot->scale >= 900) {
            Color ink = slot->enabled ? shade(20, 24, 20, 100) : shade(150, 150, 150, 100);
            const char *label = bubble_label(slot->bubble);
            draw_text_centred(label, slot->x, slot->y - PIXL_FONT_HEIGHT, 2, ink);
            if (slot->bubble == APP_MENU_BUBBLE_SEND && !slot->enabled) {
                draw_text_centred("no Mac", slot->x, slot->y + 14, 1, ink);
            }
        }
    }
}

/* The swap carousel: name, the Pixl idling large, dots, arrows, red cancel, green confirm. */
static void draw_swap(const app_menu_snapshot_t *m, uint32_t tick)
{
    const pixl_pet_t *pet = &pixl_pets[m->pet_index];
    const int cx = GAME_WIDTH / 2 + m->offset_x;
    draw_text_centred(pet->name, cx, 40, 4, shade(255, 255, 255, 100));
    draw_text_centred(pet->signature, cx, 86, 2, shade(pet->accent[0], pet->accent[1], pet->accent[2], 100));

    /* Large enough to admire, small enough to fit between the name and the buttons. */
    const pixl_frame_t *idle = &pet->frames[PIXL_F_IDLE_0];
    int scale = 1;
    while ((scale + 1) * idle->w <= 300 && (scale + 1) * idle->h <= 190) {
        scale++;
    }
    static const int loop[] = {PIXL_F_IDLE_0, PIXL_F_IDLE_0, PIXL_F_IDLE_1, PIXL_F_IDLE_2, PIXL_F_IDLE_2, PIXL_F_BLINK};
    int frame = loop[(tick / 10) % (sizeof loop / sizeof loop[0])];
    draw_frame(pet, frame, cx, 310, 1, (uint8_t)scale, 1000, 1000, 100);

    Color grey = shade(120, 120, 120, 100);
    draw_text("<", 18, 200, 4, grey);
    draw_text(">", GAME_WIDTH - 34, 200, 4, grey);
    const int gap = 18, x0 = GAME_WIDTH / 2 - (m->pet_count - 1) * gap / 2;
    for (int i = 0; i < m->pet_count; i++) {
        Color dot = i == m->pet_index ? shade(pet->accent[0], pet->accent[1], pet->accent[2], 100) : grey;
        DrawCircle(x0 + i * gap, 336, i == m->pet_index ? 6.0f : 4.0f, dot);
    }

    /* Red ✕ cancel, green ✓ confirm; a held button grows a little. */
    const int y = m->buttons_y;
    float rc = (float)m->button_radius + (m->pressed < 0 ? 4.0f : 0.0f);
    float rk = (float)m->button_radius + (m->pressed > 0 ? 4.0f : 0.0f);
    DrawCircle(m->cancel_x, y, rc, shade(205, 52, 52, 100));
    DrawCircle(m->confirm_x, y, rk, shade(58, 170, 82, 100));
    Color white = shade(255, 255, 255, 100);
    const float k = 18.0f;
    Vector2 a = {(float)m->cancel_x - k, (float)y - k}, b = {(float)m->cancel_x + k, (float)y + k};
    Vector2 c = {(float)m->cancel_x + k, (float)y - k}, d = {(float)m->cancel_x - k, (float)y + k};
    DrawLineEx(a, b, 8.0f, white);
    DrawLineEx(c, d, 8.0f, white);
    Vector2 p = {(float)m->confirm_x - 20, (float)y + 2}, q = {(float)m->confirm_x - 6, (float)y + 16};
    Vector2 r2 = {(float)m->confirm_x + 22, (float)y - 16};
    DrawLineEx(p, q, 8.0f, white);
    DrawLineEx(q, r2, 8.0f, white);
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
    const app_menu_snapshot_t m = app_menu_read(state->menu);
    if (m.mode != APP_MENU_CLOSED) {
        state->last_touch_tick = s.tick;   /* an open menu counts as someone using it */
    }
    uint32_t idle = s.tick - state->last_touch_tick;
    unsigned brightness = idle >= DIM_LOW_TICKS ? 10 : (idle >= DIM_HALF_TICKS ? 50 : 100);

    if (m.mode == APP_MENU_SWAP) {
        draw_swap(&m, s.tick);
    } else {
        if (s.phase != APP_GAME_PET_ABSENT) {
            /* Behind an open menu the Pixl is dimmed so the bubbles stand out. */
            unsigned b = m.mode == APP_MENU_CLOSED ? brightness : 45;
            draw_frame(&pixl_pets[state->look], (int)s.pose, s.pet_x, s.pet_y, s.facing, state->scale,
                       s.squash_x, s.squash_y, b);
            if (s.asleep) {
                draw_zz(state, &s, b);
            }
            if (s.waiting || state->sending) {
                draw_waiting(state, &s, b);
            }
            if (s.tick < state->speech_until && m.mode == APP_MENU_CLOSED) {
                draw_speech(state, &s, b);
            }
        }
        if (m.mode != APP_MENU_CLOSED) {
            draw_menu(state, &m);
        }
    }
    const app_dock_status_t dock = app_dock_status(state->dock);
    if (dock.on_battery && dock.battery_percent >= 0 && dock.battery_percent <= BATTERY_WARN) {
        draw_battery(dock.battery_percent, s.tick, brightness < 50 ? 50 : brightness);
    }
    EndDrawing();
    return 0;
}

/* ---------------------------------------------------------------------------------------- */
/* Host state for replays and tests */

static const char *phase_name(app_game_pet_phase_t p)
{
    static const char *const names[] = {"absent", "entering", "idle", "moving", "exiting", "shrugging", "poked",
                                        "held", "airborne", "clinging", "resting", "trick", "mischief", "emoting"};
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
    const app_menu_snapshot_t m = app_menu_read(state->menu);
    int size = snprintf(output, capacity,
                        "{\"phase\":\"%s\",\"tick\":%lu,\"pointer_x\":%ld,\"pointer_y\":%ld,"
                        "\"pointer_down\":%s,\"pet\":\"%s\",\"pose\":%d,\"pet_x\":%ld,\"pet_y\":%ld,"
                        "\"look\":\"%s\",\"scale\":%u,\"asleep\":%s,\"menu\":%d,\"swap_index\":%d,"
                        "\"speech\":\"%s\",\"waiting\":%s,\"macs\":%d,\"owns_pet\":%s,\"in_trip\":%s,"
                        "\"locked\":%s,\"battery\":%d,\"on_battery\":%s,\"state_hash\":\"%08lx\"}",
                        s.paused ? "paused" : "running", (unsigned long)s.tick, (long)s.pointer_x,
                        (long)s.pointer_y, s.pointer_down ? "true" : "false", phase_name(s.phase), (int)s.pose,
                        (long)s.pet_x, (long)s.pet_y, pixl_pets[state->look].id, (unsigned)state->scale,
                        s.asleep ? "true" : "false", (int)m.mode, m.pet_index,
                        s.tick < state->speech_until ? state->speech : "",
                        (s.waiting || state->sending) ? "true" : "false", d.macs, d.owns_pet ? "true" : "false",
                        d.in_trip ? "true" : "false", d.locked ? "true" : "false", d.battery_percent,
                        d.on_battery ? "true" : "false", (unsigned long)state_hash(value));
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
