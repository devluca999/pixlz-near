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
/* Slime trail (SPEC §12.3): a dot every few ticks while crawling, gone within 4 s (no burn-in). */
enum { TRAIL_POINTS = 48, TRAIL_EVERY = 5, TRAIL_TICKS = 4 * GAME_TICK_HZ };
/* Readers: the text area between the header and the hint. */
enum { READ_TOP = 64, READ_BOTTOM = 446, READ_LEFT = 22, READ_WIDTH = 436 };

typedef struct {
    int16_t x, y;
    uint8_t surface;
    uint32_t tick;
} trail_point_t;

typedef struct {
    app_game_handle_t game;
    app_dock_handle_t dock;
    app_menu_handle_t menu;
    int look;                 /* index into pixl_pets */
    uint8_t scale;
    uint32_t last_touch_tick;
    bool sending;             /* a menu "Send home" is waiting on the trip */
    uint32_t exit_tick;       /* Exit: when to leave for Vibe Mode (0 = not leaving) */
    bool exited;              /* the switch is scheduled: the device restarts shortly */
    char speech[SPEECH_MAX];
    uint32_t speech_until;
    int last_line;
    uint32_t speech_from;
    trail_point_t trail[TRAIL_POINTS];
    int trail_next;
    uint32_t feed_version;
    uint32_t agents_version;
    uint32_t next_alert;      /* Agent alerts: when to call again (0 = at once) */
    char banner[64];          /* a line across the top ("pixlz needs you") */
    char pair_code[8];        /* a Mac's pairing code while it's asked (D20) */
    uint32_t banner_until;
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
        pet->walk_speed, pet->sticky != 0,
    };
    return c;
}

/* The saved swap choice, else the visiting Pixl's own species, else Frogg. */
static int initial_look(host_state_t *state)
{
    char id[24] = "";
    app_dock_load_look(id, sizeof id);
    int i = look_index(id);
    /* The Pixl here travels as the one on screen: a swap made before swaps travelled. */
    if (i >= 0 && app_dock_status(state->dock).owns_pet) {
        (void)app_dock_restyle(state->dock, pixl_pets[i].id, pixl_pets[i].name);
    }
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
    state->speech_from = tick;
    state->speech_until = tick + SPEECH_TICKS;
}

static void open_menu(host_state_t *state)
{
    const app_dock_status_t d = app_dock_status(state->dock);
    const app_game_snapshot_t s = app_game_read(state->game);
    const bool here = s.phase != APP_GAME_PET_ABSENT && s.phase != APP_GAME_PET_EXITING;
    const app_dock_feed_t *feed = app_dock_feed(state->dock);
    app_menu_context_t ctx = {
        d.macs > 0 && d.owns_pet && !d.locked && !d.in_trip && here,
        d.locked, d.owns_pet && here, state->look, PIXL_PET_COUNT, d.can_call && !d.in_trip,
        feed ? feed->answers_count : 0, feed ? feed->memory_count : 0,
        d.can_bring && !here, 0, 0, d.macs > 0, false, false,
    };
    ctx.agents_paired = d.agents_paired;
    ctx.paired = d.paired;
    const app_dock_agents_t *ag = app_dock_agents(state->dock);
    if (ag) {
        ctx.agents_count = ag->count;
        for (int i = 0; i < ag->count && i < 32; i++) {
            ctx.agents_waiting |= ag->items[i].req[0] ? 1u << i : 0;
        }
    }
    app_menu_open(state->menu, &ctx);
}

static void say_banner(host_state_t *state, const char *text)
{
    snprintf(state->banner, sizeof state->banner, "%s", text);
    state->banner_until = app_game_read(state->game).tick + 4 * 30;
}

static void apply_menu(host_state_t *state, app_menu_action_t a)
{
    switch (a.kind) {
    case APP_MENU_ACTION_SEND_HOME:
        state->sending = true;
        app_dock_send_home(state->dock);
        break;
    case APP_MENU_ACTION_TRICK: app_game_trick(state->game); break;
    case APP_MENU_ACTION_CALL: (void)app_dock_call(state->dock); break;
    case APP_MENU_ACTION_BRING: (void)app_dock_bring(state->dock); break;
    case APP_MENU_ACTION_AGENT_DENY:
    case APP_MENU_ACTION_AGENT_ALLOW: {
        const bool allow = a.kind == APP_MENU_ACTION_AGENT_ALLOW;
        const app_dock_agents_t *ag = app_dock_agents(state->dock);
        if (ag && a.arg >= 0 && a.arg < ag->count && ag->items[a.arg].req[0]) {
            const bool sent = ag->items[a.arg].answerable && app_dock_agent_decide(state->dock, a.arg, allow);
            say_banner(state, sent ? (allow ? "Allowed" : "Denied") : "Answer it in the terminal");
        }
        break;
    }
    case APP_MENU_ACTION_AGENT_CHAT:
        (void)app_dock_agent_chat(state->dock, a.arg);
        break;
    case APP_MENU_ACTION_AGENT_REPLY: {
        static const char *const quick[4] = {"Continue", "Yes", "No", "Run the tests"};
        const app_dock_agents_t *ag = app_dock_agents(state->dock);
        const app_dock_chat_t *ch = app_dock_chat(state->dock);
        int row = a.arg / 16, q = a.arg % 16;
        /* The list may have moved since the chat opened: find that session by id. */
        for (int i = 0; ag && ch && i < ag->count; i++) {
            if (strcmp(ag->items[i].id, ch->id) == 0) {
                row = i;
            }
        }
        const bool sent = q >= 0 && q < 4 && app_dock_agent_reply(state->dock, row, quick[q]);
        say_banner(state, sent ? "Sent. Claude carries on." : "It isn't waiting for a reply now");
        break;
    }
    case APP_MENU_ACTION_PAIR:
        app_dock_pair_answer(state->dock, a.arg != 0);
        say_banner(state, a.arg ? "Now confirm on your Mac" : "Pairing cancelled");
        break;
    case APP_MENU_ACTION_UNPAIR:
        app_dock_unpair(state->dock);
        say_banner(state, "Unpaired. Allow is off here.");
        break;
    case APP_MENU_ACTION_EXIT: {
        /* With a Mac to go to, the Pixl hops home first, so it isn't left on a device that
         * stops running Pixlz; locked, it stays. Leave when the trip ends, or after 8 s. */
        const app_dock_status_t d = app_dock_status(state->dock);
        const app_game_snapshot_t s = app_game_read(state->game);
        const bool here = s.phase != APP_GAME_PET_ABSENT && s.phase != APP_GAME_PET_EXITING;
        if (d.owns_pet && here && d.macs > 0 && !d.locked && !d.in_trip) {
            state->sending = true;
            app_dock_send_home(state->dock);
            state->exit_tick = s.tick + 8 * 30;
        } else {
            state->exit_tick = s.tick + 30;   /* a moment to read "See you soon" */
        }
        break;
    }
    case APP_MENU_ACTION_NAP: app_game_nap(state->game); break;
    case APP_MENU_ACTION_LOCK: (void)app_dock_set_locked(state->dock, a.arg != 0); break;
    case APP_MENU_ACTION_SWAP:
        if (a.arg >= 0 && a.arg < PIXL_PET_COUNT && a.arg != state->look) {
            state->look = a.arg;
            app_dock_save_look(pixl_pets[a.arg].id);
            (void)app_dock_restyle(state->dock, pixl_pets[a.arg].id, pixl_pets[a.arg].name);   /* it travels as this one */
            const app_game_config_t c = config_for(a.arg, 0);
            state->scale = c.scale;
            state->last_line = -1;
            app_game_set_look(state->game, &c);
        }
        break;
    case APP_MENU_ACTION_NONE: break;
    }
}

/* Agent mode: new sessions reach an open list; with alerts on, the Pixl calls every 20 s
 * while one waits, a line names it, and the screen wakes from its dim. */
static void agents_update(host_state_t *state, uint32_t tick)
{
    const app_dock_agents_t *ag = app_dock_agents(state->dock);
    if (!ag) {
        return;
    }
    if (ag->version != state->agents_version) {
        state->agents_version = ag->version;
        uint32_t mask = 0;
        for (int i = 0; i < ag->count && i < 32; i++) {
            mask |= ag->items[i].req[0] ? 1u << i : 0;
        }
        app_menu_set_agents(state->menu, ag->count, mask);
        if (!ag->waiting) {
            state->next_alert = 0;
        }
    }
    if (!ag->alerts || !ag->waiting || tick < state->next_alert) {
        return;
    }
    state->next_alert = tick + 20 * 30;
    const app_dock_agent_t *first = NULL;
    for (int i = 0; i < ag->count && !first; i++) {
        first = ag->items[i].req[0] ? &ag->items[i] : NULL;
    }
    speak(state, APP_GAME_SAY_ALERT, tick);
    snprintf(state->banner, sizeof state->banner, "%s needs you", first ? first->project : "Claude Code");
    state->banner_until = tick + 5 * 30;
    state->last_touch_tick = tick;   /* wake the screen */
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
    const app_game_snapshot_t now = app_game_read(state->game);
    const uint32_t tick = now.tick;
    speak(state, app_game_take_say(state->game), tick);
    /* Slime: crawlers leave a short-lived trail where they've been. */
    if (pixl_pets[state->look].movement == PIXL_MOVE_WALK && now.phase == APP_GAME_PET_MOVING && tick % TRAIL_EVERY == 0) {
        trail_point_t *p = &state->trail[state->trail_next];
        p->x = (int16_t)now.pet_x;
        p->y = (int16_t)now.pet_y;
        p->surface = (uint8_t)now.surface;
        p->tick = tick ? tick : 1;
        state->trail_next = (state->trail_next + 1) % TRAIL_POINTS;
    }
    const app_dock_feed_t *feed = app_dock_feed(state->dock);
    if (feed && feed->version != state->feed_version) {
        state->feed_version = feed->version;
        app_menu_set_counts(state->menu, feed->answers_count, feed->memory_count);
    }
    agents_update(state, tick);
    {   /* the open chat takes a reply from here: held open on the Mac, and paired with it */
        const app_dock_agents_t *ag = app_dock_agents(state->dock);
        const app_dock_chat_t *ch = app_dock_chat(state->dock);
        bool ok = false;
        for (int i = 0; ag && ch && i < ag->count; i++) {
            ok |= strcmp(ag->items[i].id, ch->id) == 0 && ag->items[i].reply_open;
        }
        app_menu_set_chat(state->menu, ok && app_dock_status(state->dock).agents_paired);
    }
    {
        const app_dock_status_t ds = app_dock_status(state->dock);
        app_menu_set_paired(state->menu, ds.paired, ds.agents_paired);
    }
    int n = app_dock_poll(state->dock, state->events, MAX_EVENTS);
    for (int i = 0; i < n; i++) {
        switch (state->events[i].kind) {
        case APP_DOCK_EVENT_ARRIVED: {
            /* The Pixl shows as what it is (a swap on another device travels with it). */
            char id[24] = "";
            if (app_dock_pet_species(state->dock, id, sizeof id) && look_index(id) >= 0 && look_index(id) != state->look) {
                app_dock_save_look(id);
                state->look = look_index(id);
                const app_game_config_t c = config_for(state->look, 0);
                state->scale = c.scale;
                app_game_set_look(state->game, &c);
            }
            app_game_pet_arrive(state->game);
            break;
        }
        case APP_DOCK_EVENT_LEFT:
            state->sending = false;
            app_game_pet_leave(state->game);
            if (state->exit_tick) {
                state->exit_tick = tick + 45;   /* let him hop off first */
            }
            break;
        case APP_DOCK_EVENT_PAIR_CODE:
            snprintf(state->pair_code, sizeof state->pair_code, "%s", state->events[i].reason);
            app_menu_open_pair(state->menu);
            state->last_touch_tick = tick;   /* wake the screen */
            break;
        case APP_DOCK_EVENT_PAIRED: {
            char line[64];
            snprintf(line, sizeof line, "Paired with %.40s", state->events[i].reason);
            say_banner(state, line);
            if (app_menu_read(state->menu).mode == APP_MENU_PAIR) {
                app_menu_close(state->menu);
            }
            break;
        }
        case APP_DOCK_EVENT_PAIR_ENDED:
            if (app_menu_read(state->menu).mode == APP_MENU_PAIR) {
                app_menu_close(state->menu);
            }
            say_banner(state, "Pairing cancelled");
            break;
        case APP_DOCK_EVENT_SHRUG:
            if (strcmp(state->events[i].reason, "alreadyHere") == 0) {
                say_banner(state, "Already there. Sorting out the copies.");
            }
            state->sending = false;
            app_game_pet_shrug(state->game);
            if (state->exit_tick) {
                state->exit_tick = tick + 30;   /* he stays here, saved */
            }
            break;
        }
    }
    /* Another device owns the Pixl now (its Mac brought it back while this one was off): it
     * isn't here any more, so it walks off instead of lingering as a copy. */
    const app_dock_status_t d = app_dock_status(state->dock);
    const app_game_snapshot_t after = app_game_read(state->game);
    if (!d.owns_pet && !d.in_trip && !state->sending && after.phase != APP_GAME_PET_ABSENT &&
            after.phase != APP_GAME_PET_EXITING) {
        app_game_pet_leave(state->game);
    }
    if (state->exit_tick && !state->exited && tick >= state->exit_tick) {
        state->exited = app_dock_exit(state->dock);
        if (!state->exited) {
            state->exit_tick = 0;   /* couldn't switch: stay in the app */
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

/* A point in the Pixl's own frame (x right, y down, origin at the feet) on the screen, for a
 * Pixl standing on `surface`: the floor as drawn, a wall turned a quarter, the ceiling upside down. */
static void to_screen(int surface, int fx, int fy, int lx, int ly, int *sx, int *sy)
{
    switch (surface) {
    case APP_GAME_SURFACE_RIGHT_WALL: *sx = fx + ly, *sy = fy - lx; break;
    case APP_GAME_SURFACE_CEILING: *sx = fx - lx, *sy = fy - ly; break;
    case APP_GAME_SURFACE_LEFT_WALL: *sx = fx - ly, *sy = fy + lx; break;
    default: *sx = fx + lx, *sy = fy + ly; break;
    }
}

/* One frame bottom-centred on the feet, mirrored when facing left, at a whole-number scale,
 * turned to the edge it stands on; squash stretches pixel edges on whole pixels, so nothing is
 * ever blurred. */
static void draw_frame(const pixl_pet_t *pet, int frame, int fx, int fy, int facing, uint8_t scale,
                       uint16_t squash_x, uint16_t squash_y, unsigned brightness, int surface)
{
    const pixl_frame_t *f = &pet->frames[frame];
    long sx = (long)scale * squash_x; /* pixels per art pixel, in 1/1000 */
    long sy = (long)scale * squash_y;
    long left = -(long)f->w * sx / 2;
    for (uint16_t i = 0; i < f->count; i++) {
        const pixl_run_t *r = &f->runs[i];
        int ax = facing < 0 ? f->w - r->x - r->len : r->x;
        int x0 = fdiv(left + ax * sx, 1000), x1 = fdiv(left + (ax + r->len) * sx, 1000);
        int y0 = fdiv(-(long)(f->h - r->y) * sy, 1000);
        int y1 = fdiv(-(long)(f->h - r->y - 1) * sy, 1000);
        if (x1 <= x0 || y1 <= y0) {
            continue;
        }
        int ax0, ay0, ax1, ay1;
        to_screen(surface, fx, fy, x0, y0, &ax0, &ay0);
        to_screen(surface, fx, fy, x1, y1, &ax1, &ay1);
        int rx = ax0 < ax1 ? ax0 : ax1, ry = ay0 < ay1 ? ay0 : ay1;
        int rw = ax0 < ax1 ? ax1 - ax0 : ax0 - ax1, rh = ay0 < ay1 ? ay1 - ay0 : ay0 - ay1;
        const uint8_t *c = pet->palette[r->colour];
        DrawRectangle(rx, ry, rw, rh, shade(c[0], c[1], c[2], brightness));
    }
}

/* Where its head is on the screen (above the feet, whichever way it's turned). */
static void head_point(const host_state_t *state, const app_game_snapshot_t *s, int *x, int *y)
{
    int h = pixl_pets[state->look].frames[PIXL_F_IDLE_0].h * state->scale;
    to_screen(s->surface, s->pet_x, s->pet_y, 0, -h, x, y);
}

static int head_y(const host_state_t *state, const app_game_snapshot_t *s)
{
    int x, y;
    head_point(state, s, &x, &y);
    return y;
}

/* "…" above the head while a trip is pending; at an edge, on the inside. */
static void draw_waiting(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    const int scale = state->scale;
    int top = head_y(state, s) - 6 * scale;
    Color colour = shade(230, 230, 230, brightness);
    int dot = 2 * scale, phase = (int)(s->tick / 8 % 3), hx, hy;
    head_point(state, s, &hx, &hy);
    int cx = s->edge < 0 ? s->pet_x + 10 * dot : (s->edge > 0 ? s->pet_x - 10 * dot : hx);
    if (top < 8) top = hy + 6 * scale;   /* upside down on the ceiling: below the head */
    for (int i = 0; i < 3; i++) {
        int lift = i == phase ? scale : 0;
        DrawRectangle(cx - 4 * dot + i * 3 * dot, top - lift, dot, dot, colour);
    }
}

/* Zz drifting up from the head while asleep. */
static void draw_zz(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    static const char *const letters[3] = {"z", "z", "Z"};
    int hx, base;
    head_point(state, s, &hx, &base);
    /* rise from the head toward the middle of the screen (down, when it hangs from the ceiling) */
    int dir = base < 60 ? 1 : -1;
    for (int i = 0; i < 3; i++) {
        uint32_t t = (s->tick + (uint32_t)i * 30) % 90;
        int y = base + dir * ((int)t / 2 + 4);
        int x = hx + (hx > GAME_WIDTH / 2 ? -24 : 18) + i * 10;
        unsigned fade = t < 60 ? brightness : brightness * (90 - t) / 30;
        draw_text(letters[i], x, y, 2 + (i == 2), shade(160, 200, 255, fade));
    }
}

/* The species' own sound, in a paper bubble by the head (SPEC §11.6, voice). A shy Pixl
 * (pixl.json ui.shy: Boo) has no bubble: its sounds float up from its head and fade. */
static void draw_speech(const host_state_t *state, const app_game_snapshot_t *s, unsigned brightness)
{
    const int scale = 2, pad = 8;
    int hx, hy;
    head_point(state, s, &hx, &hy);
    if (pixl_pets[state->look].shy) {
        uint32_t age = s->tick - state->speech_from;
        unsigned fade = age < SPEECH_TICKS / 2 ? brightness : brightness * (SPEECH_TICKS - age) / (SPEECH_TICKS / 2);
        int w = text_width(state->speech, scale), x = hx - w / 2;
        if (x < 8) x = 8;
        if (x + w > GAME_WIDTH - 8) x = GAME_WIDTH - 8 - w;
        draw_text(state->speech, x, hy - 24 - (int)age / 2, scale, shade(200, 215, 240, fade));
        return;
    }
    int w = text_width(state->speech, scale) + 2 * pad, h = PIXL_FONT_HEIGHT * scale + 2 * pad - 4;
    int cx = hx, bottom = hy - 10;
    int x = cx - w / 2;
    int y = bottom - h;
    switch (s->surface) {   /* beside the head, toward the middle of the screen */
    case APP_GAME_SURFACE_CEILING: y = hy + 10; break;
    case APP_GAME_SURFACE_RIGHT_WALL: x = hx - 10 - w, y = hy - h / 2; break;
    case APP_GAME_SURFACE_LEFT_WALL: x = hx + 10, y = hy - h / 2; break;
    default: break;
    }
    if (x < 8) x = 8;
    if (x + w > GAME_WIDTH - 8) x = GAME_WIDTH - 8 - w;
    if (y < 8) y = 8;
    if (y + h > GAME_HEIGHT - 8) y = GAME_HEIGHT - 8 - h;
    Color ink = shade(27, 42, 26, brightness), paper = shade(255, 251, 242, brightness);
    DrawRectangle(x - 2, y - 2, w + 4, h + 4, ink);
    DrawRectangle(x, y, w, h, paper);
    if (s->surface == APP_GAME_SURFACE_FLOOR) {
        int tail = cx < x + 16 ? x + 16 : (cx > x + w - 16 ? x + w - 16 : cx);
        for (int i = 0; i < 4; i++) {
            DrawRectangle(tail - 4 + i, y + h + i * 2, 8 - 2 * i, 2, i == 0 ? paper : ink);
        }
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
    case APP_MENU_BUBBLE_ANSWERS: return "Answers";
    case APP_MENU_BUBBLE_MEMORY: return "Memory";
    case APP_MENU_BUBBLE_CALL: return "Call";
    case APP_MENU_BUBBLE_BRING: return "Bring";
    case APP_MENU_BUBBLE_EXIT: return "Exit";
    case APP_MENU_BUBBLE_AGENTS: return "Agents";
    case APP_MENU_BUBBLE_UNPAIR: return "Unpair";
    case APP_MENU_BUBBLE_Q0: return "Continue";
    case APP_MENU_BUBBLE_Q1: return "Yes";
    case APP_MENU_BUBBLE_Q2: return "No";
    case APP_MENU_BUBBLE_Q3: return "Tests";
    default: return "";
    }
}

/* Each action keeps its own colour, whichever Pixl is here, so it's found by colour too. */
static Color bubble_colour(app_menu_bubble_t b)
{
    switch (b) {
    case APP_MENU_BUBBLE_SEND:
    case APP_MENU_BUBBLE_CALL:
    case APP_MENU_BUBBLE_BRING: return shade(110, 180, 245, 100);    /* blue: travel */
    case APP_MENU_BUBBLE_EXIT: return shade(150, 160, 200, 100);     /* slate */
    case APP_MENU_BUBBLE_AGENTS: return shade(255, 176, 60, 100);    /* amber */
    case APP_MENU_BUBBLE_UNPAIR: return shade(150, 160, 200, 100);   /* slate */
    case APP_MENU_BUBBLE_Q0: return shade(140, 215, 120, 100);       /* green: carry on */
    case APP_MENU_BUBBLE_Q1: return shade(110, 180, 245, 100);
    case APP_MENU_BUBBLE_Q2: return shade(240, 115, 105, 100);
    case APP_MENU_BUBBLE_Q3: return shade(245, 200, 80, 100);
    case APP_MENU_BUBBLE_TRICK: return shade(245, 200, 80, 100);     /* gold */
    case APP_MENU_BUBBLE_SWAP: return shade(185, 150, 240, 100);     /* violet */
    case APP_MENU_BUBBLE_MORE: return shade(120, 200, 190, 100);     /* teal */
    case APP_MENU_BUBBLE_ANSWERS: return shade(140, 215, 120, 100);  /* green */
    case APP_MENU_BUBBLE_MEMORY: return shade(245, 165, 95, 100);    /* orange */
    case APP_MENU_BUBBLE_LOCK:
    case APP_MENU_BUBBLE_UNLOCK: return shade(240, 115, 105, 100);   /* coral */
    case APP_MENU_BUBBLE_BACK:
    default: return shade(175, 175, 175, 100);                       /* grey */
    }
}

/* Four bubbles, each in its action's colour; greyed when they can't be used. */
static void draw_menu(const host_state_t *state, const app_menu_snapshot_t *m)
{
    (void)state;
    for (int i = 0; i < APP_MENU_SLOTS; i++) {
        const app_menu_slot_t *slot = &m->slots[i];
        if (slot->bubble == APP_MENU_BUBBLE_NONE || !slot->scale) {
            continue;
        }
        float r = (float)m->radius * (float)slot->scale / 1000.0f;
        Color fill = slot->enabled ? bubble_colour(slot->bubble) : shade(70, 70, 70, 100);
        DrawCircle(slot->x, slot->y, r + 3, shade(27, 42, 26, 100));
        DrawCircle(slot->x, slot->y, r, fill);
        if (slot->scale >= 900) {
            Color ink = slot->enabled ? shade(20, 24, 20, 100) : shade(150, 150, 150, 100);
            const char *label = bubble_label(slot->bubble);
            draw_text_centred(label, slot->x, slot->y - PIXL_FONT_HEIGHT, 2, ink);
            if ((slot->bubble == APP_MENU_BUBBLE_SEND || slot->bubble == APP_MENU_BUBBLE_CALL) && !slot->enabled) {
                draw_text_centred("no Mac", slot->x, slot->y + 14, 1, ink);
            }
        }
    }
}

static void draw_buttons(const app_menu_snapshot_t *m);

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
    draw_frame(pet, frame, cx, 310, 1, (uint8_t)scale, 1000, 1000, 100, APP_GAME_SURFACE_FLOOR);

    Color grey = shade(120, 120, 120, 100);
    draw_text("<", 18, 200, 4, grey);
    draw_text(">", GAME_WIDTH - 34, 200, 4, grey);
    const int gap = 18, x0 = GAME_WIDTH / 2 - (m->pet_count - 1) * gap / 2;
    for (int i = 0; i < m->pet_count; i++) {
        Color dot = i == m->pet_index ? shade(pet->accent[0], pet->accent[1], pet->accent[2], 100) : grey;
        DrawCircle(x0 + i * gap, 336, i == m->pet_index ? 6.0f : 4.0f, dot);
    }

    draw_buttons(m);
}

/* Red ✕ cancel, green ✓ confirm (swap and exit); a held button grows a little. */
static void draw_buttons(const app_menu_snapshot_t *m)
{
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

static int wrap_text(const char *text, int x, int y, int width, int scale, Color colour, bool draw);

/* Agents: four sessions a screen; waiting ones in amber with "needs you". */
static void draw_agents(const host_state_t *state, const app_menu_snapshot_t *m)
{
    const app_dock_agents_t *ag = app_dock_agents(state->dock);
    Color white = shade(240, 240, 235, 100), grey = shade(130, 130, 130, 100), amber = shade(255, 176, 60, 100);
    char line[96];
    if (ag && ag->waiting) {
        snprintf(line, sizeof line, "Agents  %d waiting", ag->waiting);
    } else {
        snprintf(line, sizeof line, "Agents");
    }
    draw_text_centred(line, GAME_WIDTH / 2, 36, 3, white);
    if (!ag || ag->count == 0) {
        wrap_text("No Claude Code sessions right now. Connect Claude Code under Agents on your Mac, then start one.",
                  60, 180, GAME_WIDTH - 120, 2, grey, true);
        return;
    }
    for (int k = 0; k < APP_MENU_AGENT_ROWS; k++) {
        const int i = m->agent_first + k;
        if (i >= ag->count) {
            break;
        }
        const app_dock_agent_t *a = &ag->items[i];
        const int y = m->rows_y + k * m->row_h;
        const bool wait = a->req[0] != 0;
        DrawRectangleRounded((Rectangle){20, (float)y + 4, GAME_WIDTH - 40, (float)m->row_h - 8}, 0.25f, 6,
                             wait ? shade(70, 48, 16, 100) : shade(28, 30, 28, 100));
        draw_text(a->project, 36, y + 16, 2, wait ? amber : white);
        if (wait) {
            draw_text_centred("needs you >", GAME_WIDTH - 100, y + 18, 1, amber);
        }
        snprintf(line, sizeof line, "%.40s", wait ? a->summary : a->doing);
        draw_text(line, 36, y + 48, 1, grey);
    }
    if (ag->count > APP_MENU_AGENT_ROWS) {
        draw_text_centred("swipe for more", GAME_WIDTH / 2, GAME_HEIGHT - 30, 1, grey);
    }
}

/* One request: what it wants to run, red Deny, green Allow greyed until pairing (D19). */
static void draw_agent(const host_state_t *state, const app_menu_snapshot_t *m)
{
    const app_dock_agents_t *ag = app_dock_agents(state->dock);
    if (!ag || m->agent_first >= ag->count) {
        return;
    }
    const app_dock_agent_t *a = &ag->items[m->agent_first];
    Color white = shade(240, 240, 235, 100), grey = shade(140, 140, 140, 100), amber = shade(255, 176, 60, 100);
    draw_text_centred(a->project, GAME_WIDTH / 2, 30, 3, amber);
    int h = wrap_text(a->summary, 40, 82, GAME_WIDTH - 80, 2, white, true);
    if (a->detail[0] && strcmp(a->detail, a->summary) != 0) {
        DrawRectangleRounded((Rectangle){30, (float)(92 + h), GAME_WIDTH - 60, 150}, 0.1f, 6, shade(24, 26, 24, 100));
        BeginScissorMode(34, 96 + h, GAME_WIDTH - 68, 142);
        wrap_text(a->detail, 42, 104 + h, GAME_WIDTH - 84, 1, grey, true);
        EndScissorMode();
    }
    if (!a->answerable) {
        draw_text_centred("Answer it in the terminal", GAME_WIDTH / 2, m->buttons_y - 90, 1, grey);
    }
    /* Red Deny; green Allow, live only when paired with this Mac (D20). */
    const bool can_allow = app_dock_status(state->dock).agents_paired && a->answerable;
    const int y = m->buttons_y;
    DrawCircle(m->cancel_x, y, (float)m->button_radius + (m->pressed < 0 ? 4.0f : 0.0f),
               a->answerable ? shade(205, 52, 52, 100) : shade(90, 50, 50, 100));
    DrawCircle(m->confirm_x, y, (float)m->button_radius + (m->pressed > 0 ? 4.0f : 0.0f),
               can_allow ? shade(58, 170, 82, 100) : shade(50, 70, 55, 100));
    draw_text_centred("Deny", m->cancel_x, y - PIXL_FONT_HEIGHT, 2, white);
    if (can_allow) {
        draw_text_centred("Allow", m->confirm_x, y - PIXL_FONT_HEIGHT, 2, white);
    } else {
        draw_text_centred("Allow", m->confirm_x, y - PIXL_FONT_HEIGHT - 6, 2, grey);
        draw_text_centred("pair first", m->confirm_x, y + 10, 1, grey);
    }
}

/* One session's chat: your prompts, Claude's replies, the tools it ran; newest at the bottom. */
static void draw_chat(host_state_t *state, const app_menu_snapshot_t *m)
{
    const app_dock_chat_t *ch = app_dock_chat(state->dock);
    const app_dock_agents_t *ag = app_dock_agents(state->dock);
    Color white = shade(240, 240, 235, 100), grey = shade(130, 130, 130, 100), amber = shade(255, 176, 60, 100);
    const char *project = "Session";
    bool reply_open = false;
    for (int i = 0; ag && ch && i < ag->count; i++) {
        if (strcmp(ag->items[i].id, ch->id) == 0) {
            project = ag->items[i].project;
            reply_open = ag->items[i].reply_open;
        }
    }
    draw_text_centred(project, GAME_WIDTH / 2, 22, 2, amber);
    if (!ch || ch->count < 0) {
        draw_text_centred("Loading the chat...", GAME_WIDTH / 2, 200, 2, grey);
        return;
    }
    if (ch->count == 0) {
        wrap_text("Nothing to show yet. The chat appears once this session does something.", 50, 180, GAME_WIDTH - 100, 2,
                  grey, true);
        return;
    }
    const bool reply_ok = app_dock_status(state->dock).agents_paired && reply_open;
    const int bottom = reply_ok ? m->buttons_y - m->button_radius - 10 : READ_BOTTOM;
    const int view = bottom - READ_TOP;
    /* Measure, then draw scrolled; the view starts at the newest turn. */
    int h = 0;
    for (int i = 0; i < ch->count; i++) {
        const app_dock_chat_line_t *l = &ch->lines[i];
        h += (l->role == 't' ? 0 : 18) + wrap_text(l->text, READ_LEFT, 0, READ_WIDTH, l->role == 't' ? 1 : 2, white, false) + 10;
    }
    app_menu_set_read_extent(state->menu, h, view);
    BeginScissorMode(READ_LEFT - 4, READ_TOP, READ_WIDTH + 8, view);
    int y = READ_TOP - m->scroll;
    for (int i = 0; i < ch->count; i++) {
        const app_dock_chat_line_t *l = &ch->lines[i];
        if (l->role == 't') {
            char line[APP_DOCK_CHAT_TEXT + 4];
            snprintf(line, sizeof line, "> %s", l->text);
            y += wrap_text(line, READ_LEFT, y, READ_WIDTH, 1, grey, true) + 10;
            continue;
        }
        draw_text(l->role == 'y' ? "You" : "Claude", READ_LEFT, y, 1, l->role == 'y' ? grey : amber);
        y += 18;
        y += wrap_text(l->text, READ_LEFT, y, READ_WIDTH, 2, white, true) + 10;
    }
    EndScissorMode();
    if (reply_ok) {
        DrawCircle(m->confirm_x, m->buttons_y, (float)m->button_radius, shade(58, 170, 82, 100));
        draw_text_centred("Reply", m->confirm_x, m->buttons_y - PIXL_FONT_HEIGHT, 2, white);
        draw_text("tap to go back", 30, m->buttons_y - 4, 1, grey);
    } else {
        draw_text_centred(reply_open ? "pair with your Mac to reply" : "drag to scroll - tap to go back", GAME_WIDTH / 2,
                          GAME_HEIGHT - 26, 1, grey);
    }
}

/* A Mac's pairing code, big, with red (no) and green (same code). */
static void draw_pair(const host_state_t *state, const app_menu_snapshot_t *m)
{
    Color white = shade(240, 240, 235, 100), grey = shade(150, 150, 150, 100);
    draw_text_centred("Pair with your Mac?", GAME_WIDTH / 2, 50, 3, white);
    char spaced[8];
    snprintf(spaced, sizeof spaced, "%.3s %.3s", state->pair_code, state->pair_code + 3);
    draw_text_centred(spaced, GAME_WIDTH / 2, 140, 7, shade(255, 200, 110, 100));
    wrap_text("Same code on your Mac? Tap green here, then confirm there. Paired, this Mosaico can Allow your agents.",
              50, 250, GAME_WIDTH - 100, 1, grey, true);
    draw_buttons(m);
}

/* A line across the top (an agent waiting, "Denied"), over everything. */
static void draw_banner(const host_state_t *state, uint32_t tick)
{
    if (tick >= state->banner_until || !state->banner[0]) {
        return;
    }
    const int w = text_width(state->banner, 2) + 32;
    DrawRectangleRounded((Rectangle){(float)(GAME_WIDTH - w) / 2, 10, (float)w, 34}, 0.5f, 8, shade(70, 48, 16, 100));
    draw_text_centred(state->banner, GAME_WIDTH / 2, 20, 2, shade(255, 200, 110, 100));
}

/* "Leave Pixlz?" with what happens to the Pixl, over the red and green buttons. */
static void draw_exit(const host_state_t *state, const app_menu_snapshot_t *m)
{
    const app_dock_status_t d = app_dock_status(state->dock);
    const app_game_snapshot_t s = app_game_read(state->game);
    const bool here = d.owns_pet && s.phase != APP_GAME_PET_ABSENT;
    const char *name = pixl_pets[state->look].name;
    char line[128];
    Color white = shade(255, 255, 255, 100), grey = shade(170, 170, 170, 100);
    draw_text_centred("Leave Pixlz?", GAME_WIDTH / 2, 110, 4, white);
    if (here && d.macs > 0 && !d.locked) {
        snprintf(line, sizeof line, "%s hops home to your Mac first.", name);
    } else if (here) {
        snprintf(line, sizeof line, "%s stays here, saved.", name);
    } else {
        snprintf(line, sizeof line, "Nothing is lost.");
    }
    (void)wrap_text(line, 60, 190, GAME_WIDTH - 120, 2, grey, true);
    (void)wrap_text("Vibe Mode opens next. Open Pixlz from there to come back.", 60, 250, GAME_WIDTH - 120, 2,
                    grey, true);
    draw_buttons(m);
}

/* Nothing on screen: say where the Pixl is and how to get it, drifting slowly so no pixel
 * stays lit in one place on the AMOLED (SPEC §12.1). */
static void draw_empty(const host_state_t *state, uint32_t tick, unsigned brightness)
{
    const app_dock_status_t d = app_dock_status(state->dock);
    const int dx = (int)((tick / 600) % 5) * 8 - 16, dy = (int)((tick / 900) % 5) * 8 - 16;
    const int cx = GAME_WIDTH / 2 + dx, y = 180 + dy;
    const pixl_pet_t *pet = &pixl_pets[state->look];
    Color title = shade(pet->accent[0], pet->accent[1], pet->accent[2], brightness);
    Color body = shade(200, 200, 200, brightness), hint = shade(130, 130, 130, brightness);
    char line[128];
    if (state->exit_tick) {
        draw_text_centred("See you soon", cx, y + 30, 3, body);
        return;
    }
    if (d.in_trip) {
        snprintf(line, sizeof line, "%s is on the way...", pet->name);
        draw_text_centred(line, cx, y + 30, 2, body);
        return;
    }
    if (d.away_on[0]) {
        snprintf(line, sizeof line, "%s is on", pet->name);
        draw_text_centred(line, cx, y, 2, body);
        draw_text_centred(d.away_on, cx, y + 30, 2, title);
        draw_text_centred(d.can_call ? "Double-tap, then Call" :
                          d.can_bring ? "Mac off? Double-tap, then Bring" : "Waiting for your Mac",
                          cx, y + 80, 1, hint);
    } else {
        draw_text_centred("No Pixl here yet", cx, y, 2, body);
        draw_text_centred("Send one from your Mac", cx, y + 30, 2, title);
        draw_text_centred("Double-tap for the menu", cx, y + 80, 1, hint);
    }
}

/* The slime trail: dots on the edge it crawled, fading out. */
static void draw_trail(const host_state_t *state, uint32_t tick, unsigned brightness)
{
    const int dot = state->scale * 2;
    for (int i = 0; i < TRAIL_POINTS; i++) {
        const trail_point_t *p = &state->trail[i];
        if (!p->tick || tick - p->tick >= TRAIL_TICKS) {
            continue;
        }
        unsigned fade = brightness * (TRAIL_TICKS - (tick - p->tick)) / TRAIL_TICKS / 2;
        int x, y;
        to_screen(p->surface, p->x, p->y, 0, -dot / 2, &x, &y);
        DrawRectangle(x - dot / 2, y - dot / 2, dot, dot, shade(150, 205, 140, fade));
    }
}

/* Word-wrapped text in raylib's font; draws when `draw` and returns the height used. */
static int wrap_text(const char *text, int x, int y, int width, int scale, Color colour, bool draw)
{
    char line[96], candidate[96];
    int used = 0, height = 0;
    const int line_h = (PIXL_FONT_HEIGHT + 3) * scale;
    const char *p = text;
    while (*p) {
        while (*p == ' ') p++;
        const char *word = p;
        while (*p && *p != ' ') p++;
        int len = (int)(p - word);
        if (!len) break;
        int n = snprintf(candidate, sizeof candidate, "%s%s%.*s", used ? line : "", used ? " " : "", len, word);
        if (n < (int)sizeof candidate && (!used || text_width(candidate, scale) <= width) &&
                text_width(candidate, scale) <= width) {
            snprintf(line, sizeof line, "%s", candidate);
            used = 1;
            continue;
        }
        if (used) {   /* the line is full: draw it and try the word again on a fresh line */
            if (draw) draw_text(line, x, y + height, scale, colour);
            height += line_h;
            used = 0;
            p = word;
            continue;
        }
        /* a word wider than a whole line: as much as fits, then the rest */
        int k = 1;
        while (k < len && k < (int)sizeof line - 1) {
            snprintf(candidate, sizeof candidate, "%.*s", k + 1, word);
            if (text_width(candidate, scale) > width) break;
            k++;
        }
        snprintf(line, sizeof line, "%.*s", k, word);
        if (draw) draw_text(line, x, y + height, scale, colour);
        height += line_h;
        p = word + k;
    }
    if (used) {
        if (draw) draw_text(line, x, y + height, scale, colour);
        height += line_h;
    }
    return height;
}

/* Answers or Memory: one item at a time from the Mac, scrolled by dragging. */
static void draw_reader(host_state_t *state, const app_menu_snapshot_t *m)
{
    const bool answers = m->mode == APP_MENU_ANSWERS;
    const app_dock_feed_t *feed = app_dock_feed(state->dock);
    const uint8_t *accent = pixl_pets[state->look].accent;
    Color head = shade(accent[0], accent[1], accent[2], 100), white = shade(240, 240, 235, 100);
    Color grey = shade(120, 120, 120, 100);
    char header[48];
    if (m->read_count > 0) {
        snprintf(header, sizeof header, "%s  %d/%d", answers ? "Answers" : "Memory", m->read_index + 1, m->read_count);
    } else {
        snprintf(header, sizeof header, "%s", answers ? "Answers" : "Memory");
    }
    draw_text_centred(header, GAME_WIDTH / 2, 26, 2, head);
    if (m->read_count == 0 || !feed) {
        const char *hint = answers ? "Nothing yet. Ask on your Mac and the answers show up here."
                                   : "Nothing yet. Save highlights on your Mac and they show up here.";
        wrap_text(hint, READ_LEFT + 20, 180, READ_WIDTH - 40, 2, white, true);
        return;
    }
    const app_dock_feed_item_t *item = answers ? &feed->answers[m->read_index] : &feed->memory[m->read_index];
    const int view = READ_BOTTOM - READ_TOP;
    int title_h = item->title[0] ? wrap_text(item->title, READ_LEFT, 0, READ_WIDTH, 2, head, false) + 10 : 0;
    int body_h = wrap_text(item->body, READ_LEFT, 0, READ_WIDTH, 2, white, false);
    app_menu_set_read_extent(state->menu, title_h + body_h, view);
    BeginScissorMode(READ_LEFT - 4, READ_TOP, READ_WIDTH + 8, view);
    int y = READ_TOP - m->scroll;
    if (item->title[0]) {
        wrap_text(item->title, READ_LEFT, y, READ_WIDTH, 2, head, true);
    }
    wrap_text(item->body, READ_LEFT, y + title_h, READ_WIDTH, 2, white, true);
    EndScissorMode();
    draw_text_centred(m->read_count > 1 ? "swipe for more - tap to go back" : "tap to go back", GAME_WIDTH / 2,
                      GAME_HEIGHT - 26, 1, grey);
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
    } else if (m.mode == APP_MENU_EXIT) {
        draw_exit(state, &m);
    } else if (m.mode == APP_MENU_CHAT) {
        draw_chat(state, &m);
    } else if (m.mode == APP_MENU_PAIR) {
        draw_pair(state, &m);
    } else if (m.mode == APP_MENU_AGENTS) {
        draw_agents(state, &m);
    } else if (m.mode == APP_MENU_AGENT) {
        draw_agent(state, &m);
    } else if (m.mode == APP_MENU_ANSWERS || m.mode == APP_MENU_MEMORY) {
        draw_reader(state, &m);
    } else {
        draw_trail(state, s.tick, m.mode == APP_MENU_CLOSED ? brightness : 45);
        if (s.phase == APP_GAME_PET_ABSENT && m.mode == APP_MENU_CLOSED) {
            draw_empty(state, s.tick, brightness < 50 ? 50 : brightness);
        }
        if (s.phase != APP_GAME_PET_ABSENT) {
            /* Behind an open menu the Pixl is dimmed so the bubbles stand out. */
            unsigned b = m.mode == APP_MENU_CLOSED ? brightness : 45;
            draw_frame(&pixl_pets[state->look], (int)s.pose, s.pet_x, s.pet_y, s.facing, state->scale,
                       s.squash_x, s.squash_y, b, (int)s.surface);
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
    draw_banner(state, s.tick);
    const app_dock_status_t dock = app_dock_status(state->dock);
    if (!dock.network_ready) {   /* offline: no trips, no agents; say so (drifts with the empty screen's rule) */
        draw_text("no Wi-Fi", 14 + (int)((s.tick / 900) % 3) * 4, 14, 1, shade(200, 120, 90, brightness < 50 ? 50 : brightness));
    }
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
                        "\"look\":\"%s\",\"scale\":%u,\"asleep\":%s,\"surface\":%d,\"menu\":%d,\"swap_index\":%d,"
                        "\"speech\":\"%s\",\"waiting\":%s,\"macs\":%d,\"owns_pet\":%s,\"in_trip\":%s,"
                        "\"locked\":%s,\"battery\":%d,\"on_battery\":%s,\"state_hash\":\"%08lx\"}",
                        s.paused ? "paused" : "running", (unsigned long)s.tick, (long)s.pointer_x,
                        (long)s.pointer_y, s.pointer_down ? "true" : "false", phase_name(s.phase), (int)s.pose,
                        (long)s.pet_x, (long)s.pet_y, pixl_pets[state->look].id, (unsigned)state->scale,
                        s.asleep ? "true" : "false", (int)s.surface, (int)m.mode, m.pet_index,
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
