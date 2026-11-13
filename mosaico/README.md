# ESP-Mosaico: a Pixl travels Mac → Mosaico → Mac

The Mosaico half of Pixl trips. The Mac app finds a Mosaico by Bonjour (Wi-Fi) or Bluetooth LE and sends the Pixl with More ▸ **Send to device**; tapping the Pixl on the Mosaico sends it home. A Mosaico pairs with a Mac by showing the same 6-digit code on both screens (D20, `pixl_trip/include/pixl_trip/pt_pair.h`); a paired Mosaico can Allow or Deny Claude Code agent requests with signed decisions. **The trip link isn't encrypted yet** (see Known gaps).

| Path | What |
|---|---|
| `pixl_trip/` | The trip protocol in C (port of `TravelNode`). `make test`: 306 host checks against PixlzCore fixtures and the RFC vectors. |
| `pixlz_dock/` | The Mosaico app (Raylib Lite). `make -C pixlz_dock/tests`: model tests (6,252 checks). |
| `tools/PixlzSend/` | A command-line Mac stand-in for testing: `send`, `dock`, `status`, `fixtures`. Store: `~/Library/Application Support/PixlzDock`. The Mac app does all of this itself. |
| `tools/export_pets.py`, `tools/export_font.py` | The Pixls' frames and the font → C headers of colour runs. |
| `sync-dock.sh`, `sim.sh` | Copy the app into the vendor workspace; run its simulator. |
| `tools/iris_tap.py` | Tap the real Mosaico's screen through the ESP-Iris gateway (testing without a finger). |
| `tools/mdns_query.py` | Ask a device's mDNS responder directly, to tell a silent device from a network that drops multicast. |

**Status (2026-11-10):** on a real Mosaico (Vibe Mode 0.2.1 + pixlz_dock), Frogg went Mac → Mosaico → Mac
twice; the Mosaico's state edit passed the Mac's checksum both times.

## One-time setup

- Vendor workspace at `~/esp-mosaico-vibe` (`git clone https://github.com/esp-mosaico/esp-mosaico-vibe`,
  then `git submodule update --init submodule/esp-mosaico-utils submodule/esp-mosaico-bsp submodule/raylib-lite-engine`).
- ESP-IDF at `~/esp/esp-idf`, commit `7b9cc1ac79f865983f59bb8ff3ff43eb74ff1dbe`,
  `./install.sh esp32s31`, plus `python tools/idf_tools.py install cmake ninja` (macOS).
- A Python 3.10+ venv with Pillow for the simulator: `~/.venvs/mosaico` (`uv venv -p 3.12 ~/.venvs/mosaico && uv pip install pillow numpy`).
- `python mosaico.py game create pixlz_dock` once, then `mosaico/sync-dock.sh` from here on.

## Simulator (no hardware)

```sh
mosaico/sim.sh                                   # browser preview at http://127.0.0.1:8460
cd mosaico/tools/PixlzSend && swift run PixlzSend dock --host 127.0.0.1 &   # catches him back
swift run PixlzSend send --host 127.0.0.1        # Frogg drops in on the simulated Mosaico
# tap Frogg in the preview: after the double-tap window he hops out and arrives home
```

## Device

```sh
cd ~/esp-mosaico-vibe && export IDF_PATH=~/esp/esp-idf
python mosaico.py game build --project projects/pixlz_dock
# first build only: the bmgr step in docs/game-development.md, then build again
python mosaico.py iris status --all --json && python mosaico.py iris list --details --json
python mosaico.py iris system-update --project projects/pixlz_dock   # installs only through mosaico.py
```

Then, with the Mosaico plugged in and on the Mac's Wi-Fi (its saved Wi-Fi, or `CONFIG_PIXLZ_WIFI_*`):
`swift run PixlzSend send` finds it by Bonjour (`_pixlz._tcp`, `kind=mosaico`). If the Wi-Fi drops
multicast, Bonjour finds nothing: run once with `--host <its IP>` (the app logs it: "Wi-Fi ready: …");
PixlzSend remembers the last address that answered and falls back to it.

Device notes from the first install:
- A Mosaico whose current app doesn't start ESP-Iris over USB doesn't appear on the Mac at all, and the
  AI button may not reach Vibe Mode. Hold **Boot** (left of the USB-C port) while powering on (the right
  button), then `python mosaico.py recover`. The host Python needs `pyserial` (the workspace pins 3.5),
  or recover silently finds no device.
- Save Wi-Fi in Vibe Mode: `iris test enter-recovery`, then `iris test recovery-wifi --ssid <name>`
  (password on stdin), then `iris restart`.
- If `recover`'s final reset loses the port, the write still verifies but no host record is kept, so
  `iris app-update` refuses; `iris system-update` works.
- Tap Frogg from the Mac: keep `python mosaico.py iris run --project projects/pixlz_dock` open, then
  `python3 mosaico/tools/iris_tap.py <gateway URL> <device id> <x> <y>`.

## Known gaps

- The trip link isn't encrypted. Pairing derives a shared key (HKDF over X25519); using it to encrypt the link is next.
- PixlzCore still re-encodes to check the ack; the raw-bytes checksum (SPEC §10.1) and `proto` in
  offers are only in the C side so far. The C side writes canonical bytes, so both agree today.
- On arrival the C node only updates `savedAt` (no needs bumps or `happy` emotion).
- Wi-Fi stays on (power save off) when unplugged; the sleep rules of SPEC §12.1 aren't implemented.
- Bonjour depends on the Wi-Fi passing multicast; the remembered address is the fallback.
