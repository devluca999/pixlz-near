#!/bin/zsh
# One command for a person who just cloned the repo:
#   scripts/install.sh
# Sets up the memory service, builds and installs Pixl Memory.app into ~/Applications,
# and opens it. After this, the app starts the service itself; click the frog in the menu
# bar to call your Pixl. Nothing here needs sudo.
set -euo pipefail
cd "$(dirname "$0")/.."

say() { print -P "%F{green}▸%f $1"; }

# 1. uv (runs the Python memory service)
UV="$(command -v uv || true)"
for c in "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do [ -z "$UV" ] && [ -x "$c" ] && UV="$c"; done
if [ -z "$UV" ]; then
  print "uv isn't installed. Install it (either works), then run this again:"
  print "  brew install uv"
  print "  curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi
say "uv: $UV"

# 2. the memory service's dependencies, and a .env if there isn't one
(cd memory && "$UV" sync --quiet)
[ -f .env ] || { cp .env.example .env; say "created .env (to polish, put your NEAR AI key in it: see .env.example)"; }
say "memory service ready"

# 3. the app (also registers the Chrome bridge when it starts)
scripts/build-mac-app.sh --open
say "Pixl Memory is in ~/Applications and running."
print ""
print "  • Click the frog in the menu bar to call your Pixl; right-click it for the menu."
print "  • First run: allow Accessibility (System Settings ▸ Privacy & Security ▸ Accessibility)."
print "  • Chrome: load extension/ unpacked (chrome://extensions ▸ Developer mode ▸ Load unpacked)."
print "  • Open at login: right-click the frog ▸ Open at login."
