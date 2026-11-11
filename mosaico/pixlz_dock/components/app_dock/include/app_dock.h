// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** The Mosaico's travel dock: a TCP server for Macs, the trip node and the saved record.
 * One owner loop; poll it every tick. Contracts: ../README.md. Spike: no pairing or TLS. */
typedef struct app_dock *app_dock_handle_t;

typedef enum {
    APP_DOCK_EVENT_ARRIVED = 1,  /**< The Pixl is owned here now: play the entrance. */
    APP_DOCK_EVENT_LEFT,         /**< Committed: play the exit. */
    APP_DOCK_EVENT_SHRUG,        /**< The trip didn't happen; `reason` says why. */
} app_dock_event_kind_t;

typedef struct {
    app_dock_event_kind_t kind;
    char reason[32];
} app_dock_event_t;

typedef struct {
    bool network_ready;  /**< Wi-Fi has an address (always true in the simulator). */
    bool clock_ok;       /**< Wall clock set (SNTP); trips need it. */
    int macs;            /**< Connected Macs that said hello. */
    bool in_trip;
    bool owns_pet;
    int battery_percent; /**< 0..100, or -1 when unknown. */
    bool on_battery;     /**< Unplugged (discharging). */
    bool locked;         /**< The Pixl here is locked to this device (SPEC §10.6). */
} app_dock_status_t;

/** Loads the saved record and starts networking. Returns NULL on allocation failure. */
app_dock_handle_t app_dock_create(void);
/** Closes sockets and frees the dock; clears the handle. NULL is a no-op. */
void app_dock_destroy(app_dock_handle_t *handle);
/** Nonblocking network and timer work; writes up to `max` events, returns how many. */
int app_dock_poll(app_dock_handle_t dock, app_dock_event_t *events, int max);
/** Send the Pixl to the connected Mac. The result arrives as LEFT or SHRUG events. */
void app_dock_send_home(app_dock_handle_t dock);
app_dock_status_t app_dock_status(app_dock_handle_t dock);
/** Lock or unlock the Pixl here; saved at once. False if nothing changed. */
bool app_dock_set_locked(app_dock_handle_t dock, bool locked);
/** The species ids this device can draw (the strings must outlive the dock). */
void app_dock_set_known_species(app_dock_handle_t dock, const char *const *ids, int count);
/** The species of the Pixl here (from its state), or false when none. */
bool app_dock_pet_species(app_dock_handle_t dock, char *out, int cap);
/** The look chosen on this device (Pixl swap), saved across restarts; "" when none. */
void app_dock_load_look(char *out, int cap);
void app_dock_save_look(const char *id);

#ifdef __cplusplus
}
#endif
