#!/bin/sh
# Copies the Mosaico app from this repo into the vendor workspace, where `python mosaico.py`
# builds and simulates it (its CMake and simulator need it under <workspace>/projects/).
# This repo is the source of truth; edit here, then sync.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
workspace=${MOSAICO_WORKSPACE:-$HOME/esp-mosaico-vibe}
dest="$workspace/projects/pixlz_dock"
[ -f "$workspace/mosaico.py" ] || { echo "no Mosaico workspace at $workspace (set MOSAICO_WORKSPACE)" >&2; exit 1; }
mkdir -p "$dest"
# Generated and tool-owned files in the destination are left alone.
rsync -a --delete \
  --exclude .git --exclude build --exclude 'build-*' --exclude managed_components \
  --exclude dependencies.lock --exclude sdkconfig --exclude sdkconfig.old \
  --exclude assets/generated --exclude components/gen_bmgr_codes \
  --exclude components/pixl_trip --exclude tests/build \
  "$here/pixlz_dock/" "$dest/"
rsync -a --delete --exclude build --exclude test --exclude Makefile --exclude .gitignore \
  "$here/pixl_trip/" "$dest/components/pixl_trip/"
echo "synced to $dest"
