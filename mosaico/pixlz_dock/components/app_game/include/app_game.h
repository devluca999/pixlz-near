// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Opaque model owned by one loop; no concurrent or ISR access.
 * Lifecycle and timing contracts: ../README.md. */
typedef struct app_game *app_game_handle_t;

typedef enum {
    APP_GAME_OK = 0,
    APP_GAME_INVALID_ARGUMENT,
    APP_GAME_NO_MEMORY,
} app_game_err_t;

typedef struct {
    uint16_t width;      /**< Viewport width in pixels, 1..65535. */
    uint16_t height;     /**< Viewport height in pixels, 1..65535. */
    uint8_t scale;       /**< Whole-number pet scale (SPEC §12.2), 1..16. */
    uint8_t pet_w;       /**< Idle frame size in art pixels, for hit tests and edges. */
    uint8_t pet_h;
    uint32_t seed;       /**< Random seed for blinks and hops; any value. */
} app_game_config_t;

typedef enum {
    APP_GAME_PET_ABSENT = 0,  /**< Not on this device; nothing drawn. */
    APP_GAME_PET_ENTERING,    /**< Dropping in from the top, then the landing squash. */
    APP_GAME_PET_IDLE,
    APP_GAME_PET_HOPPING,     /**< A short hop along the floor (keeps the AMOLED from burning in). */
    APP_GAME_PET_EXITING,     /**< Hopping out (off the side, or out of the edge it clings to). */
    APP_GAME_PET_SHRUGGING,   /**< Annoyed: a trip failed, or poked three times. */
    APP_GAME_PET_POKED,       /**< A tap: the poke reaction. */
    APP_GAME_PET_HAPPY,       /**< A double-tap: a happy jump. */
    APP_GAME_PET_HELD,        /**< Dragged by a finger. */
    APP_GAME_PET_AIRBORNE,    /**< Thrown: bounces off walls and ceiling, lands on the floor. */
    APP_GAME_PET_CLINGING,    /**< Flung off a side edge: half off, waiting for the trip. */
} app_game_pet_phase_t;

typedef enum {
    APP_GAME_POSE_IDLE_0 = 0, APP_GAME_POSE_IDLE_1, APP_GAME_POSE_IDLE_2, APP_GAME_POSE_BLINK,
    APP_GAME_POSE_CROUCH, APP_GAME_POSE_AIR, APP_GAME_POSE_LAND, APP_GAME_POSE_ANNOYED,
    APP_GAME_POSE_POKE_0, APP_GAME_POSE_POKE_1, APP_GAME_POSE_POKE_2,
    APP_GAME_POSE_GRAB_0, APP_GAME_POSE_GRAB_1, APP_GAME_POSE_HAPPY,
    APP_GAME_POSE_COUNT
} app_game_pose_t;

typedef enum {
    APP_GAME_REQUEST_NONE = 0,
    APP_GAME_REQUEST_SEND_HOME,  /**< Flung off a side edge: send him to the Mac. */
} app_game_request_t;

typedef struct {
    uint32_t tick;       /**< Update count, wraps modulo 2^32; not milliseconds. */
    int32_t pointer_x;   /**< Pixels from left edge, 0..width-1. */
    int32_t pointer_y;   /**< Pixels from top edge, 0..height-1. */
    bool pointer_down;
    bool paused;
    app_game_pet_phase_t phase;
    app_game_pose_t pose;
    int32_t pet_x;        /**< Feet: horizontal centre in pixels (may be off screen while exiting). */
    int32_t pet_y;        /**< Feet: bottom row in pixels; height = on the floor. */
    int8_t facing;        /**< +1 right (as drawn), -1 left (mirrored). */
    uint16_t squash_x;    /**< Width and height factors in 1/1000 (1000 = none). */
    uint16_t squash_y;
    bool waiting;         /**< A send was requested and the trip hasn't finished. */
    int8_t edge;          /**< While clinging: -1 left, +1 right; else 0. */
} app_game_snapshot_t;

/** Copy config and create a caller-owned model; arguments must be non-NULL.
 * Width/height/scale/pet size must be positive; clears *out_handle on failure. */
app_game_err_t app_game_create(const app_game_config_t *config, app_game_handle_t *out_handle);
/** Free the model and clear the handle. NULL pointer/handle is a no-op. */
void app_game_destroy(app_game_handle_t *handle);
/** Reset input, tick, pause and pet to absent; keep config. NULL is a no-op. */
void app_game_reset(app_game_handle_t handle);
/** Change pause state. NULL is a no-op. Pausing stops ticks, not input recording. */
void app_game_set_paused(app_game_handle_t handle, bool paused);
/** Pointer in pixels (clamped) and button state: taps, double-taps, drags and throws. */
void app_game_set_pointer(app_game_handle_t handle, int32_t x, int32_t y, bool pressed);
/** Advance one fixed tick (30 Hz) unless paused. No rendering or hardware access. */
void app_game_update(app_game_handle_t handle);
/** Return a value snapshot on the owning loop; NULL returns all zeros. */
app_game_snapshot_t app_game_read(app_game_handle_t handle);

/** The Pixl arrived (or is owned here at startup): drop in from the top. */
void app_game_pet_arrive(app_game_handle_t handle);
/** The trip committed: hop out (through the edge it clings to, or off the nearer side). */
void app_game_pet_leave(app_game_handle_t handle);
/** The trip didn't happen: bounce back in if clinging, then an annoyed shrug. */
void app_game_pet_shrug(app_game_handle_t handle);
/** Take the pending request (at most one), clearing it. */
app_game_request_t app_game_take_request(app_game_handle_t handle);

#ifdef __cplusplus
}
#endif
