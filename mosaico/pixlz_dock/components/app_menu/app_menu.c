// SPDX-License-Identifier: Apache-2.0
#include <stdlib.h>
#include "include/app_menu.h"

enum { TICK_HZ = 30 };
/* Bubbles: ≥ 110 px targets (SPEC §12.1), 8 px in from the edge. */
enum { RADIUS = 58, INSET = 8 };
/* Pop-in (design C8): 45 ms stagger, 320 ms spring. In ticks: 2 apart, 9 long. */
enum { STAGGER = 2, POP_TICKS = 9 };
enum { CLOSE_AFTER = 8 * TICK_HZ, SWAP_CLOSE_AFTER = 30 * TICK_HZ };
enum { TAP_SLOP = 14, SWIPE_MIN = 60, SIDE_TAP = 90 };
enum { BUTTON_RADIUS = 55, BUTTON_SPREAD = 110, BUTTON_INSET = 70 };

struct app_menu {
    uint16_t width, height;
    app_menu_mode_t mode;
    app_menu_context_t context;
    uint32_t tick, opened_tick, last_touch;
    bool down;
    int32_t down_x, down_y;
    int8_t pressed;
    int pet_index;
    float offset;
    app_menu_action_t action;
};

app_menu_handle_t app_menu_create(uint16_t width, uint16_t height)
{
    if (!width || !height) {
        return NULL;
    }
    app_menu_handle_t m = calloc(1, sizeof *m);
    if (m) {
        m->width = width;
        m->height = height;
    }
    return m;
}

void app_menu_destroy(app_menu_handle_t *handle)
{
    if (handle) {
        free(*handle);
        *handle = NULL;
    }
}

static void show(app_menu_handle_t m, app_menu_mode_t mode)
{
    m->mode = mode;
    m->opened_tick = m->tick;
    m->last_touch = m->tick;
    m->pressed = 0;
    m->offset = 0;
}

void app_menu_open(app_menu_handle_t m, const app_menu_context_t *context)
{
    if (!m || !context) {
        return;
    }
    m->context = *context;
    if (m->context.pet_count < 1) {
        m->context.pet_count = 1;
    }
    if (m->context.pet_index < 0 || m->context.pet_index >= m->context.pet_count) {
        m->context.pet_index = 0;
    }
    m->down = false;
    show(m, APP_MENU_PAGE_1);
}

void app_menu_close(app_menu_handle_t m)
{
    if (m) {
        m->mode = APP_MENU_CLOSED;
        m->down = false;
        m->pressed = 0;
    }
}

bool app_menu_is_open(app_menu_handle_t m)
{
    return m && m->mode != APP_MENU_CLOSED;
}

static void slot_centre(app_menu_handle_t m, int i, int16_t *x, int16_t *y)
{
    const int w = m->width, h = m->height, r = RADIUS + INSET;
    static const int8_t dx[APP_MENU_SLOTS] = {0, 1, 0, -1}, dy[APP_MENU_SLOTS] = {-1, 0, 1, 0};
    *x = (int16_t)(w / 2 + dx[i] * (w / 2 - r));
    *y = (int16_t)(h / 2 + dy[i] * (h / 2 - r));
}

/* Which bubble sits in each slot (top, right, bottom, left) and whether it can be used. */
static void page(app_menu_handle_t m, app_menu_bubble_t bubbles[APP_MENU_SLOTS], bool enabled[APP_MENU_SLOTS])
{
    const app_menu_context_t *c = &m->context;
    for (int i = 0; i < APP_MENU_SLOTS; i++) {
        bubbles[i] = APP_MENU_BUBBLE_NONE;
        enabled[i] = false;
    }
    if (m->mode == APP_MENU_PAGE_1) {
        bubbles[0] = APP_MENU_BUBBLE_SEND, enabled[0] = c->can_send;
        bubbles[1] = APP_MENU_BUBBLE_TRICK, enabled[1] = c->has_pet;
        bubbles[2] = APP_MENU_BUBBLE_SWAP, enabled[2] = c->pet_count > 1;
        bubbles[3] = APP_MENU_BUBBLE_MORE, enabled[3] = true;
    } else if (m->mode == APP_MENU_PAGE_2) {
        bubbles[0] = c->locked ? APP_MENU_BUBBLE_UNLOCK : APP_MENU_BUBBLE_LOCK, enabled[0] = c->has_pet;
        bubbles[1] = APP_MENU_BUBBLE_NAP, enabled[1] = c->has_pet;
        bubbles[3] = APP_MENU_BUBBLE_BACK, enabled[3] = true;
    }
}

static int hit_slot(app_menu_handle_t m, int32_t x, int32_t y)
{
    for (int i = 0; i < APP_MENU_SLOTS; i++) {
        int16_t cx, cy;
        slot_centre(m, i, &cx, &cy);
        int32_t dx = x - cx, dy = y - cy;
        if (dx * dx + dy * dy <= RADIUS * RADIUS) {
            return i;
        }
    }
    return -1;
}

static void act(app_menu_handle_t m, app_menu_action_kind_t kind, int arg)
{
    m->action.kind = kind;
    m->action.arg = arg;
    app_menu_close(m);
}

static void tap_page(app_menu_handle_t m, int32_t x, int32_t y)
{
    app_menu_bubble_t bubbles[APP_MENU_SLOTS];
    bool enabled[APP_MENU_SLOTS];
    page(m, bubbles, enabled);
    int i = hit_slot(m, x, y);
    if (i < 0 || bubbles[i] == APP_MENU_BUBBLE_NONE) {
        app_menu_close(m);   /* a tap anywhere else closes it */
        return;
    }
    if (!enabled[i]) {
        return;              /* greyed out: stays open, nothing happens */
    }
    switch (bubbles[i]) {
    case APP_MENU_BUBBLE_SEND: act(m, APP_MENU_ACTION_SEND_HOME, 0); break;
    case APP_MENU_BUBBLE_TRICK: act(m, APP_MENU_ACTION_TRICK, 0); break;
    case APP_MENU_BUBBLE_NAP: act(m, APP_MENU_ACTION_NAP, 0); break;
    case APP_MENU_BUBBLE_LOCK: act(m, APP_MENU_ACTION_LOCK, 1); break;
    case APP_MENU_BUBBLE_UNLOCK: act(m, APP_MENU_ACTION_LOCK, 0); break;
    case APP_MENU_BUBBLE_MORE: show(m, APP_MENU_PAGE_2); break;
    case APP_MENU_BUBBLE_BACK: show(m, APP_MENU_PAGE_1); break;
    case APP_MENU_BUBBLE_SWAP:
        show(m, APP_MENU_SWAP);
        m->pet_index = m->context.pet_index;
        break;
    case APP_MENU_BUBBLE_NONE: break;
    }
}

static int button_at(app_menu_handle_t m, int32_t x, int32_t y)
{
    const int32_t by = m->height - BUTTON_INSET;
    const int32_t centres[2] = {m->width / 2 - BUTTON_SPREAD, m->width / 2 + BUTTON_SPREAD};
    for (int i = 0; i < 2; i++) {
        int32_t dx = x - centres[i], dy = y - by;
        if (dx * dx + dy * dy <= BUTTON_RADIUS * BUTTON_RADIUS) {
            return i == 0 ? -1 : 1;
        }
    }
    return 0;
}

/* Next or previous Pixl; the new one slides in from the side it was pushed from. */
static void step(app_menu_handle_t m, int dir, float carried)
{
    const int n = m->context.pet_count;
    m->pet_index = ((m->pet_index + dir) % n + n) % n;
    m->offset = carried + (float)(dir > 0 ? m->width : -(int)m->width);
}

static void swap_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    if (pressed && !was_down) {
        m->pressed = (int8_t)button_at(m, x, y);
        return;
    }
    int32_t dx = x - m->down_x, dy = y - m->down_y;
    if (pressed) {
        if (!m->pressed) {
            m->offset = (float)dx;   /* the carousel follows the finger */
        } else if (button_at(m, x, y) != m->pressed) {
            m->pressed = 0;          /* slid off the button */
        }
        return;
    }
    /* Released. */
    int8_t button = m->pressed;
    m->pressed = 0;
    if (button && button_at(m, x, y) == button) {
        if (button < 0) {
            app_menu_close(m);   /* cancel: nothing changes */
        } else {
            act(m, APP_MENU_ACTION_SWAP, m->pet_index);
        }
        return;
    }
    if (button) {
        return;
    }
    if (dx <= -SWIPE_MIN) {
        step(m, 1, (float)dx);
    } else if (dx >= SWIPE_MIN) {
        step(m, -1, (float)dx);
    } else if (dx * dx + dy * dy <= TAP_SLOP * TAP_SLOP && (x < SIDE_TAP || x > m->width - SIDE_TAP)) {
        step(m, x < SIDE_TAP ? -1 : 1, 0);   /* a tap on a side arrow */
    } else {
        /* too short a swipe: it springs back (offset eases to 0) */
    }
}

bool app_menu_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed)
{
    if (!m || m->mode == APP_MENU_CLOSED) {
        if (m) {
            m->down = pressed;
        }
        return false;
    }
    bool was_down = m->down;
    if (pressed && !was_down) {
        m->down_x = x;
        m->down_y = y;
    }
    m->last_touch = m->tick;
    if (m->mode == APP_MENU_SWAP) {
        swap_pointer(m, x, y, pressed, was_down);
    } else if (!pressed && was_down) {
        int32_t dx = x - m->down_x, dy = y - m->down_y;
        if (dx * dx + dy * dy <= TAP_SLOP * TAP_SLOP) {
            tap_page(m, x, y);
        }
    }
    m->down = pressed;
    return true;
}

void app_menu_update(app_menu_handle_t m)
{
    if (!m) {
        return;
    }
    ++m->tick;
    if (m->mode == APP_MENU_CLOSED) {
        return;
    }
    uint32_t idle = m->tick - m->last_touch;
    if (!m->down && idle >= (m->mode == APP_MENU_SWAP ? SWAP_CLOSE_AFTER : CLOSE_AFTER)) {
        app_menu_close(m);   /* nothing static stays on the AMOLED (SPEC §12.1) */
        return;
    }
    if (m->mode == APP_MENU_SWAP && !m->down) {
        m->offset *= 0.7f;
        if (m->offset > -1.0f && m->offset < 1.0f) {
            m->offset = 0;
        }
    }
}

/* 0.2 → 1.14 → 0.95 → 1.02 → 1 over the pop (design C8). */
static uint16_t pop(uint32_t t)
{
    static const uint16_t keys[POP_TICKS] = {200, 520, 860, 1140, 1060, 950, 990, 1020, 1000};
    return t < POP_TICKS ? keys[t] : 1000;
}

app_menu_snapshot_t app_menu_read(app_menu_handle_t m)
{
    app_menu_snapshot_t s = {0};
    if (!m) {
        return s;
    }
    s.mode = m->mode;
    s.radius = RADIUS;
    s.pet_index = m->mode == APP_MENU_SWAP ? m->pet_index : m->context.pet_index;
    s.pet_count = m->context.pet_count;
    s.offset_x = (int16_t)m->offset;
    s.cancel_x = (int16_t)(m->width / 2 - BUTTON_SPREAD);
    s.confirm_x = (int16_t)(m->width / 2 + BUTTON_SPREAD);
    s.buttons_y = (int16_t)(m->height - BUTTON_INSET);
    s.button_radius = BUTTON_RADIUS;
    s.pressed = m->pressed;
    app_menu_bubble_t bubbles[APP_MENU_SLOTS];
    bool enabled[APP_MENU_SLOTS];
    page(m, bubbles, enabled);
    uint32_t t = m->tick - m->opened_tick;
    for (int i = 0; i < APP_MENU_SLOTS; i++) {
        s.slots[i].bubble = bubbles[i];
        s.slots[i].enabled = enabled[i];
        slot_centre(m, i, &s.slots[i].x, &s.slots[i].y);
        uint32_t start = (uint32_t)i * STAGGER;
        s.slots[i].scale = t < start ? 0 : pop(t - start);
    }
    return s;
}

app_menu_action_t app_menu_take_action(app_menu_handle_t m)
{
    app_menu_action_t a = {APP_MENU_ACTION_NONE, 0};
    if (m) {
        a = m->action;
        m->action = (app_menu_action_t) {
            APP_MENU_ACTION_NONE, 0
        };
    }
    return a;
}
