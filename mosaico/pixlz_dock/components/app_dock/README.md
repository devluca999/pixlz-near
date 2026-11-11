# app_dock

The Mosaico's travel dock (D17): a TCP server for Macs on port 47860, PixlzCore's framing, the
`pixl_trip` node and the saved record. **Spike:** plain TCP with a hello frame, no pairing or TLS.

## Responsibilities

- Accept up to 3 connections; send `{"hello":…}` first and expect one back (SPEC §10.3).
- Feed frames to the node and perform its outputs in order. A failed save stops the step, so
  nothing that depends on it is sent (SPEC §10.5).
- Turn exits, entrances and shrugs into `app_dock_event_t` for the runtime.
- `app_dock_send_home`: offer the Pixl to the connected Mac (a fling, or the menu's Home).
- **Feed:** a `{"feed":{"answers":[{"q","a"}],"highlights":[{"title","text"}]},"from","fromName"}`
  frame from a Mac (opt-in on the Mac: `PixlMemory.feedDevices`) fills `app_dock_feed`: up to 6
  answers and 6 highlights, ASCII, for the Answers and Memory readers. Never passed to the trip node.
- Lock/unlock (`app_dock_set_locked`, saved at once), the species list it can host, and the
  device's chosen look (Pixl swap) in NVS.

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
- **Never erases.** If the app NVS can't initialise, trips are disabled and it says so. A record
  that exists but can't be read is kept (copied to `record_bad` on the device, renamed aside in the
  simulator); offers are declined (`busy`) and the screen says so until the forget RPC clears it.
- **Record format.** `PXL2` (adds the holder's or sender's id); `PXL1` records still load.
- **Saved first.** A failed save reloads the record from storage, ends any trip (`abort`
  `saveFailed`) and shrugs `saveFailed`. Lock, restyle, forget, pairing and unpairing change
  memory only once saved.
- **Connections.** A Mac that identifies again replaces its older Wi-Fi connection. Wi-Fi
  connections use TCP keepalive and close after 5 minutes without a byte. The agents list, its
  chat and the feed are cleared when the Mac that sent them goes. While a Pixl is pending, every
  connected Mac is asked `status` each minute.
- **Who.** Call goes only to the device holding the Pixl; Send home goes to the paired Mac, else
  the one whose agents are shown, else the latest. Agent answers go only to the Mac the sessions
  came from, by session and request id.

## Usage

```c
app_dock_handle_t dock = app_dock_create();
app_dock_event_t ev[4];
int n = app_dock_poll(dock, ev, 4);   // every tick
app_dock_send_home(dock);             // on a tap
```
