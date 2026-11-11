// SPDX-License-Identifier: Apache-2.0
// What app_dock needs from the platform: app_dock_platform_esp.c on the device,
// app_dock_platform_host.c in the simulator. Called only from the dock's owner loop
// (except the ESP Wi-Fi event handlers, which only set atomic flags).
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../pixl_trip/include/pixl_trip/pt_trip.h"

#define APP_DOCK_PORT 47860

/** Start Wi-Fi, mDNS and SNTP on the device; nothing in the simulator. */
void dock_platform_start(const pt_device_t *me);
void dock_platform_stop(void);
bool dock_platform_net_ready(void);
bool dock_platform_clock_ok(void);
/** The Mac's time from its hello; sets the clock only if nothing better (SNTP) has. */
void dock_platform_offer_clock(int64_t unix_ms);
int64_t dock_platform_now_ms(void);
void dock_platform_random(void *ctx, uint8_t *out, size_t n);
/** This device's stable id and name. */
void dock_platform_device(pt_device_t *me);
/** Loads the saved record; false = none (or unreadable). */
bool dock_platform_load(pt_record_t *record);
/** Saves the record atomically; false on failure. */
bool dock_platform_save(const pt_record_t *record);
void dock_platform_log(const char *fmt, ...);
/** Battery charge (0..100) and whether it is running on battery; false = unknown.
 * Also adapts power use: Wi-Fi power saving on battery, off on USB. Call every few seconds. */
bool dock_platform_battery(int *percent, bool *on_battery);
/** True once after the maintenance "forget" request arrived (ESP-Iris RPC over USB, device only).
 * The dock honours it only when it doesn't hold a Pixl. */
bool dock_platform_take_forget_request(void);
/** Leave the app for Vibe Mode (the device restarts into it). False if it can't. */
bool dock_platform_enter_vibe_mode(void);
/** A small device setting (the Pixl swap's look): "" when unset. */
void dock_platform_load_look(char *out, size_t cap);
bool dock_platform_save_look(const char *id);
