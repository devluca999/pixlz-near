# ESP-Mosaico spike: Frogg travels Mac → Mosaico → Mac

**Spike only (D17):** plain TCP with a hello frame, no pairing or TLS. Pairing with a PAKE must
land before `mosaico` merges (D9).

| Path | What |
|---|---|
| `pixl_trip/` | The trip protocol in C (port of `TravelNode`). `make test`: 124 host checks against PixlzCore fixtures. |
| `pixlz_dock/` | The Mosaico app (Raylib Lite). `make -C pixlz_dock/tests`: model tests. |
| `tools/PixlzSend/` | The Mac half: `send`, `dock`, `status`, `fixtures`. Store: `~/Library/Application Support/PixlzDock`. |
| `tools/export_sprites.py` | `sprites.json` → C header of colour runs. |
| `sync-dock.sh`, `sim.sh` | Copy the app into the vendor workspace; run its simulator. |

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
`swift run PixlzSend send` finds it by Bonjour (`_pixlz._tcp`, `kind=mosaico`).

## Known gaps (before merge)

- Pairing + TLS (D9, SPEC §15 Q7).
- PixlzCore still re-encodes to check the ack; the raw-bytes checksum (SPEC §10.1) and `proto` in
  offers are only in the C side so far. The C side writes canonical bytes, so both agree today.
- On arrival the C node only updates `savedAt` (no needs bumps or `happy` emotion).
- Wi-Fi stays on when unplugged; the sleep rules of SPEC §12.1 aren't implemented.
- The Mac app (`macos/`) doesn't know about the Mosaico yet; `PixlzSend` stands in for it.
