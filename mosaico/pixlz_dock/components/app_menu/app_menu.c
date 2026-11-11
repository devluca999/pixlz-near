// SPDX-License-Identifier: Apache-2.0
#include <stdlib.h>
#include <string.h>
#include "include/app_menu.h"

enum { TICK_HZ = 30 };
/* Bubbles: ≥ 110 px targets (SPEC §12.1), 8 px in from the edge. */
enum { RADIUS = 58, INSET = 8 };
/* Pop-in (design C8): 45 ms stagger, 320 ms spring. In ticks: 2 apart, 9 long. */
enum { STAGGER = 2, POP_TICKS = 9 };
enum { CLOSE_AFTER = 8 * TICK_HZ, SWAP_CLOSE_AFTER = 30 * TICK_HZ };
enum { TAP_SLOP = 14, SWIPE_MIN = 60, SIDE_TAP = 90 };
enum { BUTTON_RADIUS = 55, BUTTON_SPREAD = 110, BUTTON_INSET = 70 };
/* Agents rows: under a title, above nothing; 4 × 84 px = full-width targets. */
enum { ROWS_Y = 96, ROW_H = 84 };

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
    int read_index;
    float scroll, scroll_at_down;
    int scroll_max;
    int agent_first, agent;
    app_menu_agent_row_t rows[APP_MENU_AGENT_MAX];
    int agents_count;
    char opened_id[APP_MENU_ID_MAX];    /* the session a request, chat or quick view is about */
    char opened_req[APP_MENU_REQ_MAX];  /* the request opened (Agent) */
    bool chat_reply_ok;
    bool chat_can_pair;    /* not paired, but a Mac is there: the mic spot asks to pair */
    bool to_end;           /* chat: jump to the newest turn once its size is known */
    bool mic_off;          /* holding the mic, finger slid away from it */
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
    m->read_index = 0;
    m->scroll = 0;
    m->scroll_max = 0;
    m->agent_first = 0;
    m->agent = 0;
    m->to_end = mode == APP_MENU_CHAT;
}

static bool reading(const app_menu_handle_t m)
{
    if (m->mode == APP_MENU_CHAT) {
        return true;
    }
    return m->mode == APP_MENU_ANSWERS || m->mode == APP_MENU_MEMORY;
}

static int read_count(const app_menu_handle_t m)
{
    return m->mode == APP_MENU_ANSWERS ? m->context.answers_count : m->mode == APP_MENU_MEMORY ? m->context.memory_count : 0;
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
        if (c->has_pet) {
            bubbles[0] = APP_MENU_BUBBLE_SEND, enabled[0] = c->can_send;
        } else if (!c->can_call && c->can_bring) {
            bubbles[0] = APP_MENU_BUBBLE_BRING, enabled[0] = true;     /* its Mac is off */
        } else {
            bubbles[0] = APP_MENU_BUBBLE_CALL, enabled[0] = c->can_call;   /* bring it here */
        }
        bubbles[1] = APP_MENU_BUBBLE_AGENTS, enabled[1] = c->agents_connected;
        bubbles[2] = APP_MENU_BUBBLE_SWAP, enabled[2] = c->can_swap && c->pet_count > 1;
        bubbles[3] = APP_MENU_BUBBLE_MORE, enabled[3] = true;
    } else if (m->mode == APP_MENU_PAGE_2) {
        bubbles[0] = APP_MENU_BUBBLE_ANSWERS, enabled[0] = true;   /* empty: says how to fill it */
        bubbles[1] = APP_MENU_BUBBLE_MEMORY, enabled[1] = true;
        bubbles[2] = APP_MENU_BUBBLE_TRICK, enabled[2] = c->has_pet;
        bubbles[3] = APP_MENU_BUBBLE_MORE, enabled[3] = true;
    } else if (m->mode == APP_MENU_QUICK) {
        for (int i = 0; i < APP_MENU_SLOTS; i++) {
            bubbles[i] = (app_menu_bubble_t)(APP_MENU_BUBBLE_Q0 + i), enabled[i] = true;
        }
    } else if (m->mode == APP_MENU_PAGE_3) {
        bubbles[0] = c->locked ? APP_MENU_BUBBLE_UNLOCK : APP_MENU_BUBBLE_LOCK, enabled[0] = c->has_pet;
        bubbles[1] = APP_MENU_BUBBLE_EXIT, enabled[1] = true;
        if (c->paired) {
            bubbles[2] = APP_MENU_BUBBLE_UNPAIR, enabled[2] = true;
        } else {
            bubbles[2] = APP_MENU_BUBBLE_PAIR, enabled[2] = c->agents_connected;   /* needs a Mac to ask */
        }
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

/* The action, with the session (and request) the view is about. */
static void set_action(app_menu_handle_t m, app_menu_action_kind_t kind, int arg)
{
    memset(&m->action, 0, sizeof m->action);
    m->action.kind = kind;
    m->action.arg = arg;
    if (kind == APP_MENU_ACTION_AGENT_DENY || kind == APP_MENU_ACTION_AGENT_ALLOW ||
            kind == APP_MENU_ACTION_AGENT_CHAT || kind == APP_MENU_ACTION_AGENT_REPLY) {
        memcpy(m->action.id, m->opened_id, sizeof m->action.id);
        memcpy(m->action.req, m->opened_req, sizeof m->action.req);
    }
}

static void act(app_menu_handle_t m, app_menu_action_kind_t kind, int arg)
{
    set_action(m, kind, arg);
    app_menu_close(m);
}

static void tap_page(app_menu_handle_t m, int32_t x, int32_t y)
{
    app_menu_bubble_t bubbles[APP_MENU_SLOTS];
    bool enabled[APP_MENU_SLOTS];
    page(m, bubbles, enabled);
    int i = hit_slot(m, x, y);
    if (i < 0 || bubbles[i] == APP_MENU_BUBBLE_NONE) {
        if (m->mode == APP_MENU_QUICK) {
            int row = m->agent;
            show(m, APP_MENU_CHAT);   /* not now: back to the chat */
            m->agent = row;
            return;
        }
        app_menu_close(m);   /* a tap anywhere else closes it */
        return;
    }
    if (!enabled[i]) {
        return;              /* greyed out: stays open, nothing happens */
    }
    switch (bubbles[i]) {
    case APP_MENU_BUBBLE_SEND: act(m, APP_MENU_ACTION_SEND_HOME, 0); break;
    case APP_MENU_BUBBLE_CALL: act(m, APP_MENU_ACTION_CALL, 0); break;
    case APP_MENU_BUBBLE_TRICK: act(m, APP_MENU_ACTION_TRICK, 0); break;
    case APP_MENU_BUBBLE_NAP: act(m, APP_MENU_ACTION_NAP, 0); break;
    case APP_MENU_BUBBLE_LOCK: act(m, APP_MENU_ACTION_LOCK, 1); break;
    case APP_MENU_BUBBLE_UNLOCK: act(m, APP_MENU_ACTION_LOCK, 0); break;
    case APP_MENU_BUBBLE_BRING: act(m, APP_MENU_ACTION_BRING, 0); break;
    case APP_MENU_BUBBLE_MORE: show(m, m->mode == APP_MENU_PAGE_1 ? APP_MENU_PAGE_2 : APP_MENU_PAGE_3); break;
    case APP_MENU_BUBBLE_AGENTS: show(m, APP_MENU_AGENTS); break;
    case APP_MENU_BUBBLE_BACK: show(m, m->mode == APP_MENU_PAGE_3 ? APP_MENU_PAGE_2 : APP_MENU_PAGE_1); break;
    case APP_MENU_BUBBLE_EXIT: show(m, APP_MENU_EXIT); break;
    case APP_MENU_BUBBLE_UNPAIR: act(m, APP_MENU_ACTION_UNPAIR, 0); break;
    case APP_MENU_BUBBLE_PAIR: act(m, APP_MENU_ACTION_PAIR_REQUEST, 0); break;
    case APP_MENU_BUBBLE_Q0: case APP_MENU_BUBBLE_Q1: case APP_MENU_BUBBLE_Q2: case APP_MENU_BUBBLE_Q3:
        act(m, APP_MENU_ACTION_AGENT_REPLY, m->agent * 16 + (int)(bubbles[i] - APP_MENU_BUBBLE_Q0));
        break;
    case APP_MENU_BUBBLE_ANSWERS: show(m, APP_MENU_ANSWERS); break;
    case APP_MENU_BUBBLE_MEMORY: show(m, APP_MENU_MEMORY); break;
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

/* "Leave Pixlz?": red goes back to page 3, green leaves. Anything else does nothing. */
static void exit_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    if (pressed && !was_down) {
        m->pressed = (int8_t)button_at(m, x, y);
        return;
    }
    if (pressed) {
        if (m->pressed && button_at(m, x, y) != m->pressed) {
            m->pressed = 0;
        }
        return;
    }
    int8_t button = m->pressed;
    m->pressed = 0;
    if (button && button_at(m, x, y) == button) {
        if (button < 0) {
            show(m, APP_MENU_PAGE_3);
        } else {
            act(m, APP_MENU_ACTION_EXIT, 0);
        }
    }
}

static bool waiting(const app_menu_handle_t m, int row)
{
    return row >= 0 && row < m->agents_count && m->rows[row].req[0] != 0;
}

/* Agents list: tap a waiting row to open it; swipe sideways for the next four; tap above or
 * below the rows to go back to page 1. */
static void agents_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    (void)was_down;
    if (pressed) {
        return;
    }
    int32_t dx = x - m->down_x, dy = y - m->down_y;
    const int n = m->agents_count;
    if (dx * dx >= dy * dy && (dx <= -SWIPE_MIN || dx >= SWIPE_MIN)) {
        int first = m->agent_first + (dx < 0 ? APP_MENU_AGENT_ROWS : -APP_MENU_AGENT_ROWS);
        if (first >= 0 && first < n) {
            m->agent_first = first;
        }
        return;
    }
    if (dx * dx + dy * dy > TAP_SLOP * TAP_SLOP) {
        return;
    }
    int k = y < ROWS_Y ? -1 : (int)((y - ROWS_Y) / ROW_H);
    int row = m->agent_first + k;
    if (k < 0 || k >= APP_MENU_AGENT_ROWS || row >= n) {
        show(m, APP_MENU_PAGE_1);
        return;
    }
    int first = m->agent_first;
    show(m, waiting(m, row) ? APP_MENU_AGENT : APP_MENU_CHAT);   /* a request first; else its chat */
    m->agent_first = first;
    m->agent = row;
    memcpy(m->opened_id, m->rows[row].id, sizeof m->opened_id);   /* act on this, wherever it moves */
    memcpy(m->opened_req, m->rows[row].req, sizeof m->opened_req);
    if (m->mode == APP_MENU_CHAT) {
        m->opened_req[0] = 0;
        set_action(m, APP_MENU_ACTION_AGENT_CHAT, row);   /* the menu stays open */
    }
}

/* One request: red denies; green is Allow, greyed until pairing; anything else goes back. */
static void agent_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    if (pressed && !was_down) {
        m->pressed = (int8_t)button_at(m, x, y);
        if (m->pressed > 0 && !m->context.agents_paired) {
            m->pressed = 0;   /* Allow needs pairing with that Mac (D20) */
        }
        return;
    }
    if (pressed) {
        if (m->pressed && button_at(m, x, y) != m->pressed) {
            m->pressed = 0;
        }
        return;
    }
    int8_t button = m->pressed;
    m->pressed = 0;
    if (button && button_at(m, x, y) == button) {
        act(m, button < 0 ? APP_MENU_ACTION_AGENT_DENY : APP_MENU_ACTION_AGENT_ALLOW, m->agent);
        return;
    }
    int32_t dx = x - m->down_x, dy = y - m->down_y;
    if (!button && button_at(m, x, y) == 0 && dx * dx + dy * dy <= TAP_SLOP * TAP_SLOP) {
        int first = m->agent_first;
        show(m, APP_MENU_AGENTS);
        m->agent_first = first;
    }
}

/* What the Mac heard: red goes back to the chat, green sends it. */
static void heard_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    if (pressed && !was_down) {
        m->pressed = (int8_t)button_at(m, x, y);
        return;
    }
    if (pressed) {
        return;
    }
    int8_t button = m->pressed;
    m->pressed = 0;
    if (!button || button_at(m, x, y) != button) {
        return;
    }
    if (button > 0) {
        act(m, APP_MENU_ACTION_DICTATE_SEND, m->agent);
    } else {
        int row = m->agent;
        show(m, APP_MENU_CHAT);
        m->agent = row;
    }
}

/* The pairing code: red says no, green says the codes match. Nothing else. */
static void pair_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    if (pressed && !was_down) {
        m->pressed = (int8_t)button_at(m, x, y);
        return;
    }
    if (pressed) {
        if (m->pressed && button_at(m, x, y) != m->pressed) {
            m->pressed = 0;
        }
        return;
    }
    int8_t button = m->pressed;
    m->pressed = 0;
    if (button && button_at(m, x, y) == button) {
        act(m, APP_MENU_ACTION_PAIR, button > 0);
    }
}

/* Readers: drag up/down to scroll, swipe sideways for the next item, tap to go back. */
static void read_pointer(app_menu_handle_t m, int32_t x, int32_t y, bool pressed, bool was_down)
{
    int32_t dx = x - m->down_x, dy = y - m->down_y;
    /* Chat: hold the mic (red spot, bottom left) to dictate; let go to send it to the Mac. */
    if (m->mode == APP_MENU_CHAT && !m->chat_reply_ok && m->chat_can_pair && !pressed && was_down &&
            button_at(m, x, y) < 0 && dx * dx + dy * dy <= TAP_SLOP * TAP_SLOP) {
        m->action.kind = APP_MENU_ACTION_PAIR_REQUEST;   /* "Pair to talk": the menu stays */
        return;
    }
    if (m->mode == APP_MENU_CHAT && m->chat_reply_ok) {
        if (pressed && !was_down && button_at(m, x, y) < 0) {
            m->pressed = -1;
            m->action.kind = APP_MENU_ACTION_DICTATE_START;
            m->action.arg = m->agent;
            return;
        }
        if (m->pressed < 0) {
            /* Sliding well away from the mic arms "cancel"; coming back disarms it. */
            int32_t mx = x - m->down_x, my = y - m->down_y;
            m->mic_off = mx * mx + my * my > (BUTTON_RADIUS + 40) * (BUTTON_RADIUS + 40);
            if (!pressed) {
                m->pressed = 0;
                m->action.kind = m->mic_off ? APP_MENU_ACTION_DICTATE_CANCEL : APP_MENU_ACTION_DICTATE_STOP;
                m->action.arg = m->agent;
                m->mic_off = false;
            }
            return;   /* holding: no scrolling */
        }
    }
    if (pressed && !was_down) {
        m->scroll_at_down = m->scroll;
        return;
    }
    if (pressed) {
        if (dy * dy > dx * dx) {
            float s = m->scroll_at_down - (float)dy;
            m->scroll = s < 0 ? 0 : (s > (float)m->scroll_max ? (float)m->scroll_max : s);
        }
        return;
    }
    const int n = read_count(m);
    if (dx * dx >= dy * dy && (dx <= -SWIPE_MIN || dx >= SWIPE_MIN) && n > 1) {
        int dir = dx < 0 ? 1 : -1;
        m->read_index = ((m->read_index + dir) % n + n) % n;
        m->scroll = 0;
        m->scroll_max = 0;
    } else if (dx * dx + dy * dy <= TAP_SLOP * TAP_SLOP) {
        if (m->mode == APP_MENU_CHAT) {
            int row = m->agent, first = m->agent_first;
            if (m->chat_reply_ok && button_at(m, x, y) > 0) {
                show(m, APP_MENU_QUICK);
                m->agent = row;
                return;
            }
            show(m, APP_MENU_AGENTS);   /* back to the sessions */
            m->agent_first = first;
            return;
        }
        show(m, APP_MENU_PAGE_2);   /* a tap goes back to the page it came from */
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
    } else if (m->mode == APP_MENU_EXIT) {
        exit_pointer(m, x, y, pressed, was_down);
    } else if (m->mode == APP_MENU_PAIR) {
        pair_pointer(m, x, y, pressed, was_down);
    } else if (m->mode == APP_MENU_HEARD) {
        heard_pointer(m, x, y, pressed, was_down);
    } else if (m->mode == APP_MENU_AGENTS) {
        agents_pointer(m, x, y, pressed, was_down);
    } else if (m->mode == APP_MENU_AGENT) {
        agent_pointer(m, x, y, pressed, was_down);
    } else if (reading(m)) {
        read_pointer(m, x, y, pressed, was_down);
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
    if (m->mode == APP_MENU_PAIR) {
        return;   /* stays until answered, or until the dock says the pairing ended */
    }
    const bool long_open = m->mode == APP_MENU_SWAP || reading(m) || m->mode == APP_MENU_AGENTS ||
                           m->mode == APP_MENU_AGENT || m->mode == APP_MENU_QUICK || m->mode == APP_MENU_HEARD;
    if (!m->down && idle >= (long_open ? SWAP_CLOSE_AFTER : CLOSE_AFTER)) {
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
    s.mic_off = m->mic_off;
    s.read_index = m->read_index;
    s.read_count = read_count(m);
    s.scroll = (int16_t)m->scroll;
    s.agent_first = (m->mode == APP_MENU_AGENT || m->mode == APP_MENU_CHAT || m->mode == APP_MENU_QUICK ||
                     m->mode == APP_MENU_HEARD) ? m->agent
                                                                                                       : m->agent_first;
    s.agent_count = m->agents_count;
    if (m->mode == APP_MENU_AGENT || m->mode == APP_MENU_CHAT || m->mode == APP_MENU_QUICK || m->mode == APP_MENU_HEARD) {
        memcpy(s.agent_id, m->opened_id, sizeof s.agent_id);
        memcpy(s.agent_req, m->opened_req, sizeof s.agent_req);
    }
    s.rows_y = ROWS_Y;
    s.row_h = ROW_H;
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

void app_menu_set_read_extent(app_menu_handle_t m, int content_px, int view_px)
{
    if (!m) {
        return;
    }
    m->scroll_max = content_px > view_px ? content_px - view_px : 0;
    if (m->to_end && m->scroll_max > 0) {
        m->scroll = (float)m->scroll_max;
        m->to_end = false;
    }
    if (m->scroll > (float)m->scroll_max) {
        m->scroll = (float)m->scroll_max;
    }
}

void app_menu_set_chat(app_menu_handle_t m, bool talk, bool can_pair)
{
    if (!m) {
        return;
    }
    m->chat_reply_ok = talk;
    m->chat_can_pair = can_pair;
    if (m->mode == APP_MENU_QUICK && !talk) {
        int row = m->agent;
        show(m, APP_MENU_CHAT);   /* can't reply from here now */
        m->agent = row;
    }
}

void app_menu_back_to_agents(app_menu_handle_t m)
{
    if (m && (m->mode == APP_MENU_AGENT || m->mode == APP_MENU_CHAT || m->mode == APP_MENU_QUICK)) {
        int first = m->agent_first;
        show(m, APP_MENU_AGENTS);
        m->agent_first = first;
    }
}

void app_menu_open_heard(app_menu_handle_t m)
{
    if (m && (m->mode == APP_MENU_CHAT || m->mode == APP_MENU_HEARD)) {
        int row = m->agent;
        show(m, APP_MENU_HEARD);
        m->agent = row;
    }
}

void app_menu_open_pair(app_menu_handle_t m)
{
    if (m) {
        show(m, APP_MENU_PAIR);
    }
}

void app_menu_set_paired(app_menu_handle_t m, bool paired, bool agents_paired)
{
    if (m) {
        m->context.paired = paired;
        m->context.agents_paired = agents_paired;
    }
}

void app_menu_set_agents(app_menu_handle_t m, const app_menu_agent_row_t *rows, int count)
{
    if (!m) {
        return;
    }
    if (!rows || count < 0) {
        count = 0;
    }
    if (count > APP_MENU_AGENT_MAX) {
        count = APP_MENU_AGENT_MAX;
    }
    for (int i = 0; i < count; i++) {
        m->rows[i] = rows[i];
        m->rows[i].id[APP_MENU_ID_MAX - 1] = m->rows[i].req[APP_MENU_REQ_MAX - 1] = 0;
    }
    m->agents_count = count;
    if (m->agent_first >= count) {
        m->agent_first = 0;
    }
    if (m->mode != APP_MENU_AGENT && m->mode != APP_MENU_CHAT && m->mode != APP_MENU_QUICK) {
        return;
    }
    int found = -1;   /* the opened session, wherever it is now */
    for (int i = 0; i < count && found < 0; i++) {
        if (strcmp(m->rows[i].id, m->opened_id) == 0) {
            found = i;
        }
    }
    if (found >= 0) {
        m->agent = found;
    }
    if (m->mode == APP_MENU_AGENT && (found < 0 || strcmp(m->rows[found].req, m->opened_req) != 0)) {
        int first = m->agent_first;
        show(m, APP_MENU_AGENTS);   /* answered on the Mac or in the terminal, or it's gone */
        m->agent_first = first;
    }
}

void app_menu_set_counts(app_menu_handle_t m, int answers_count, int memory_count)
{
    if (!m) {
        return;
    }
    m->context.answers_count = answers_count;
    m->context.memory_count = memory_count;
    int n = read_count(m);
    if (m->read_index >= n) {
        m->read_index = n > 0 ? n - 1 : 0;
    }
}

app_menu_action_t app_menu_take_action(app_menu_handle_t m)
{
    app_menu_action_t a;
    memset(&a, 0, sizeof a);
    if (m) {
        a = m->action;
        memset(&m->action, 0, sizeof m->action);
    }
    return a;
}
