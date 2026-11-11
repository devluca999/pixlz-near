// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The small-screen menu (SPEC §11.2) and the Pixl swap carousel: what is open, where the
 * bubbles are, and what a touch means. Pure state, no drawing; one owner loop, 30 Hz ticks.
 * Contracts: ../README.md. */
typedef struct app_menu *app_menu_handle_t;

typedef enum {
    APP_MENU_CLOSED = 0,
    APP_MENU_PAGE_1,   /**< Home · Agents · Swap · More */
    APP_MENU_PAGE_2,   /**< Answers · Memory · Trick · More */
    APP_MENU_SWAP,     /**< Swipe through the Pixls; red cancel, green confirm. */
    APP_MENU_ANSWERS,  /**< Reading the Mac's Ask answers: swipe for the next, drag to scroll. */
    APP_MENU_MEMORY,   /**< Reading the Mac's saved highlights, the same way. */
    APP_MENU_PAGE_3,   /**< Lock / Unlock · Exit · Back */
    APP_MENU_EXIT,     /**< "Leave Pixlz?": red stay, green leave (the swap's buttons). */
    APP_MENU_AGENTS,   /**< Claude Code sessions, four rows a screen; swipe for more. */
    APP_MENU_AGENT,    /**< One waiting request: red Deny, green Allow (greyed until pairing). */
    APP_MENU_PAIR,     /**< A Mac's pairing code: red no, green "same code" (D20). */
    APP_MENU_CHAT,     /**< One session's chat: drag to scroll, tap to go back; green Reply when it can. */
    APP_MENU_QUICK,    /**< Quick replies: Continue · Yes · No · Run the tests. */
    APP_MENU_HEARD,    /**< What the Mac heard: red discard, green send it as the reply. */
} app_menu_mode_t;

typedef enum {
    APP_MENU_BUBBLE_NONE = 0,
    APP_MENU_BUBBLE_SEND, APP_MENU_BUBBLE_TRICK, APP_MENU_BUBBLE_SWAP, APP_MENU_BUBBLE_MORE,
    APP_MENU_BUBBLE_LOCK, APP_MENU_BUBBLE_UNLOCK, APP_MENU_BUBBLE_NAP, APP_MENU_BUBBLE_BACK,
    APP_MENU_BUBBLE_ANSWERS, APP_MENU_BUBBLE_MEMORY, APP_MENU_BUBBLE_CALL,
    APP_MENU_BUBBLE_BRING, APP_MENU_BUBBLE_EXIT, APP_MENU_BUBBLE_AGENTS, APP_MENU_BUBBLE_UNPAIR,
    APP_MENU_BUBBLE_Q0, APP_MENU_BUBBLE_Q1, APP_MENU_BUBBLE_Q2, APP_MENU_BUBBLE_Q3,
} app_menu_bubble_t;

/** Bubble slots at the middle of each screen edge. */
enum { APP_MENU_SLOTS = 4 };

typedef enum {
    APP_MENU_ACTION_NONE = 0,
    APP_MENU_ACTION_SEND_HOME,
    APP_MENU_ACTION_TRICK,
    APP_MENU_ACTION_NAP,
    APP_MENU_ACTION_LOCK,       /**< arg: 1 lock, 0 unlock */
    APP_MENU_ACTION_SWAP,       /**< arg: the chosen Pixl's index */
    APP_MENU_ACTION_CALL,       /**< Ask the Mac that has the Pixl to send it here. */
    APP_MENU_ACTION_BRING,      /**< No Mac answers: bring it back from the copy kept here. */
    APP_MENU_ACTION_EXIT,       /**< Leave the app for Vibe Mode (the Pixl goes home first). */
    APP_MENU_ACTION_AGENT_DENY, /**< arg: the agents row whose request to deny */
    APP_MENU_ACTION_AGENT_ALLOW,/**< arg: the agents row (only when paired with that Mac) */
    APP_MENU_ACTION_PAIR,       /**< arg: 1 the codes match, 0 no */
    APP_MENU_ACTION_UNPAIR,
    APP_MENU_ACTION_AGENT_CHAT, /**< arg: the agents row; the menu stays open (ask the Mac for its chat) */
    APP_MENU_ACTION_AGENT_REPLY,/**< arg: row * 16 + quick reply (0..3) */
    APP_MENU_ACTION_DICTATE_START, /**< the mic button went down in a chat (menu stays open) */
    APP_MENU_ACTION_DICTATE_STOP,  /**< it came up: send what was said */
    APP_MENU_ACTION_DICTATE_SEND,  /**< green on the heard screen */
} app_menu_action_kind_t;

typedef struct {
    app_menu_action_kind_t kind;
    int arg;
} app_menu_action_t;

/** What the screen can do right now, given when the menu opens. */
typedef struct {
    bool can_send;      /**< A Mac is connected and the Pixl is here and unlocked. */
    bool locked;        /**< Shows Unlock instead of Lock. */
    bool has_pet;       /**< Trick and Nap need a Pixl here. */
    int pet_index;      /**< The current look, where the carousel starts. */
    int pet_count;      /**< How many Pixls the carousel offers, >= 1. */
    bool can_call;      /**< The Pixl is away and a Mac is connected: "Call" replaces "Home". */
    int answers_count;  /**< Items the Mac has sent for the Answers and Memory readers. */
    int memory_count;
    bool can_bring;     /**< Away, no Mac connected, and a safety copy here: "Bring" replaces "Call". */
    int agents_count;   /**< Sessions the Mac sent (Agents list rows). */
    uint32_t agents_waiting; /**< Bit i: row i waits on you. */
    bool agents_connected;   /**< A Mac is connected (Agents is greyed without one). */
    bool agents_paired;      /**< Paired with the Mac whose sessions these are: Allow works. */
    bool paired;             /**< Paired with a Mac: Unpair on page 3. */
} app_menu_context_t;

typedef struct {
    app_menu_bubble_t bubble;
    bool enabled;
    int16_t x, y;          /**< Centre, pixels. */
    uint16_t scale;        /**< Pop-in animation, 1/1000 of the full radius. */
} app_menu_slot_t;

typedef struct {
    app_menu_mode_t mode;
    app_menu_slot_t slots[APP_MENU_SLOTS];
    int16_t radius;        /**< Bubble radius, pixels (≥ 55: a 110 px target). */
    int pet_index;         /**< Swap: the Pixl shown. */
    int pet_count;
    int16_t offset_x;      /**< Swap: the carousel's horizontal slide, pixels. */
    int16_t cancel_x, confirm_x, buttons_y, button_radius;
    int8_t pressed;        /**< Swap: -1 cancel held, +1 confirm held, 0 none. */
    int read_index;        /**< Answers/Memory: the item shown, and how many there are. */
    int read_count;
    int16_t scroll;        /**< Answers/Memory: pixels scrolled down. */
    int agent_first;       /**< Agents: the first row shown; Agent: the row opened. */
    int agent_count;
    int16_t rows_y, row_h; /**< Agents: where the rows start and their height. */
} app_menu_snapshot_t;

/** Agents: four rows a screen. */
enum { APP_MENU_AGENT_ROWS = 4 };

app_menu_handle_t app_menu_create(uint16_t width, uint16_t height);
void app_menu_destroy(app_menu_handle_t *handle);
/** Opens page 1 (closing anything else). */
void app_menu_open(app_menu_handle_t menu, const app_menu_context_t *context);
void app_menu_close(app_menu_handle_t menu);
bool app_menu_is_open(app_menu_handle_t menu);
/** Feeds a touch. Returns true when the menu used it (the Pixl must not see it). */
bool app_menu_pointer(app_menu_handle_t menu, int32_t x, int32_t y, bool pressed);
void app_menu_update(app_menu_handle_t menu);
/** Answers/Memory: the shown item's text height vs. the space for it, so scrolling stops at the end. */
void app_menu_set_read_extent(app_menu_handle_t menu, int content_px, int view_px);
/** Chat: whether the open session takes a reply from here now (held open, and paired). */
void app_menu_set_chat(app_menu_handle_t menu, bool reply_ok);
/** The Mac's transcript is in: show it with red and green. */
void app_menu_open_heard(app_menu_handle_t menu);
/** A Mac asks to pair: show its code over anything else, with red and green. */
void app_menu_open_pair(app_menu_handle_t menu);
/** New pairing state (paired now, or not) while the menu is open. */
void app_menu_set_paired(app_menu_handle_t menu, bool paired, bool agents_paired);
/** New sessions while the Agents list may be open; a request answered elsewhere closes. */
void app_menu_set_agents(app_menu_handle_t menu, int count, uint32_t waiting);
/** New feed counts while a reader may be open (the Mac sends again). */
void app_menu_set_counts(app_menu_handle_t menu, int answers_count, int memory_count);
app_menu_snapshot_t app_menu_read(app_menu_handle_t menu);
/** The chosen action, once. */
app_menu_action_t app_menu_take_action(app_menu_handle_t menu);

#ifdef __cplusplus
}
#endif
