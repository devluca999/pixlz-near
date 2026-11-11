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
