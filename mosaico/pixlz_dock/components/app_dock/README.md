# app_dock

The Mosaico's travel dock (D17): a TCP server for Macs on port 47860, PixlzCore's framing, the
`pixl_trip` node and the saved record. **Spike:** plain TCP with a hello frame, no pairing or TLS.

## Responsibilities

- Accept up to 3 connections; send `{"hello":…}` first and expect one back (SPEC §10.3).
- Feed frames to the node and perform its outputs in order. A failed save stops the step, so
  nothing that depends on it is sent (SPEC §10.5).
- Turn exits, entrances and shrugs into `app_dock_event_t` for the runtime.
- `app_dock_send_home`: offer the Pixl to the connected Mac (the spike's tap).

## Dependencies

`pixl_trip` (by relative path, so the simulator can compile it from a source list), and a
platform file:

| File | Where | Does |
|---|---|---|
| `app_dock_platform_esp.c` | device | Wi-Fi from `sysmeta`/`shared` (`wifi_ssid`, `wifi_password`, read-only), else `CONFIG_PIXLZ_WIFI_*`; mDNS `_pixlz._tcp` TXT `id`, `name`, `kind=mosaico`, `proto=2`; SNTP; the record as one blob in the app `nvs` partition, namespace `pixlz`. |
| `app_dock_platform_host.c` | simulator | Always online, the Mac's clock, the record in a file (`PIXLZ_DOCK_STATE`, default `~/Library/Application Support/PixlzDockSim/record.bin`), id `PIXL_DEVICE_ID` or `MOSAICO-SIM`. |

## Contracts

- **Single owner.** Call everything from the game loop (`update`). Nonblocking; returns quickly.
  The ESP Wi-Fi/IP handlers only set an atomic flag and register mDNS.
- **Memory.** The dock is one heap allocation (~70 KB: node, per-connection buffers, scratch);
  nothing large on the caller's stack.
- **Clock.** Trips need a set wall clock (SNTP). Until then the dock declines offers (`busy`)
  and a tap shrugs `noClock`.
- **Never erases.** If the app NVS can't initialise, trips are disabled and it says so.

## Usage

```c
app_dock_handle_t dock = app_dock_create();
app_dock_event_t ev[4];
int n = app_dock_poll(dock, ev, 4);   // every tick
app_dock_send_home(dock);             // on a tap
```
