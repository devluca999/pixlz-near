#!/bin/sh
# Syncs the app into the Mosaico workspace and runs its simulator.
#   mosaico/sim.sh                      interactive (browser preview)
#   mosaico/sim.sh --headless --frames 120
# Env: MOSAICO_WORKSPACE (default ~/esp-mosaico-vibe), MOSAICO_PYTHON (default ~/.venvs/mosaico/bin/python,
# needs Pillow), PIXLZ_DOCK_STATE (the simulated Mosaico's record file).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
workspace=${MOSAICO_WORKSPACE:-$HOME/esp-mosaico-vibe}
python=${MOSAICO_PYTHON:-$HOME/.venvs/mosaico/bin/python}
"$here/sync-dock.sh" >/dev/null
cd "$workspace"
PATH="$here/tools/simcc:$PATH" exec "$python" mosaico.py game sim --project projects/pixlz_dock "$@"
