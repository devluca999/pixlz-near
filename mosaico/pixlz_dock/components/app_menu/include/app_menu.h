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
    APP_MENU_PAGE_1,   /**< Send home · Trick · Swap · More */
    APP_MENU_PAGE_2,   /**< Answers · Memory · Lock / Unlock · Back */
    APP_MENU_SWAP,     /**< Swipe through the Pixls; red cancel, green confirm. */
    APP_MENU_ANSWERS,  /**< Reading the Mac's Ask answers: swipe for the next, drag to scroll. */
    APP_MENU_MEMORY,   /**< Reading the Mac's saved highlights, the same way. */
} app_menu_mode_t;

typedef enum {
    APP_MENU_BUBBLE_NONE = 0,
    APP_MENU_BUBBLE_SEND, APP_MENU_BUBBLE_TRICK, APP_MENU_BUBBLE_SWAP, APP_MENU_BUBBLE_MORE,
    APP_MENU_BUBBLE_LOCK, APP_MENU_BUBBLE_UNLOCK, APP_MENU_BUBBLE_NAP, APP_MENU_BUBBLE_BACK,
    APP_MENU_BUBBLE_ANSWERS, APP_MENU_BUBBLE_MEMORY,
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
    int answers_count;  /**< Items the Mac has sent for the Answers and Memory readers. */
    int memory_count;
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
} app_menu_snapshot_t;

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
/** New feed counts while a reader may be open (the Mac sends again). */
void app_menu_set_counts(app_menu_handle_t menu, int answers_count, int memory_count);
app_menu_snapshot_t app_menu_read(app_menu_handle_t menu);
/** The chosen action, once. */
app_menu_action_t app_menu_take_action(app_menu_handle_t menu);

#ifdef __cplusplus
}
#endif
