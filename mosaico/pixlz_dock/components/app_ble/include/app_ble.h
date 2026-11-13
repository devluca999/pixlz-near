// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The Bluetooth LE link to a Mac (D21): a GATT service that carries the same byte stream as the
 * trip port. Bytes the Mac writes go into a loopback connection to 127.0.0.1:`port`; what the
 * dock sends back goes out as notifications. So trips, the feed, agents and pairing work without
 * Wi-Fi, and nothing above the socket knows which link it came over.
 *
 *   service 6E1B0001-8F3C-4C6A-9B1E-70697868C0DE
 *   RX   …0002  write (with response): bytes to the dock
 *   TX   …0003  notify: bytes from the dock
 *   INFO …0004  read: {"id":"MOSAICO-…","name":"Mosaico …"}
 */
void app_ble_start(const char *device_id, const char *device_name, uint16_t port);

#ifdef __cplusplus
}
#endif
