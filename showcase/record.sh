#!/bin/zsh
# Records one take of a Showcase scene: the app (started with --showcase) plays the scene
# hands-free while ffmpeg records a fixed region of the screen, cursor visible.
#   showcase/record.sh <scene> <take> <seconds> [x,y,w,h]
#   RUN_DELAY=3    holds the opening longer before the scene plays
#   UNTIL_DONE=1   stops when the scene logs "done" (for beats that wait on something live);
#                  <seconds> is then the longest it will wait
# Takes land in showcase/takes/<scene>/take-<n>.mov (not committed).
set -e
scene=$1 take=$2 secs=$3 region=${4:-570,90,540,960}
bin="$HOME/Applications/Pixl Memory.app/Contents/MacOS/PixlMemory"
log="$HOME/Library/Logs/PixlMemory/debug.log"
out="$(dirname $0)/takes/$scene/take-$take.mov"
# a locked screen (or the screen saver) records as the lock screen: stop instead
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q true; then
  echo "The screen is locked: unlock the Mac, then record again." >&2; exit 2
fi
mkdir -p "$(dirname $out)"
rm -f "$out"
caffeinate -d -u -t $((secs + 20)) &   # no screen saver or display sleep mid-take
from=$(($(wc -l < "$log") + 1))
"$bin" showcase select "$scene" >/dev/null
sleep ${SETUP_WAIT:-1.5}
( sleep ${RUN_DELAY:-0.5}; "$bin" showcase run "$scene" >/dev/null ) &
# ffmpeg (avfoundation) on a fixed timer: screencapture -v sometimes never returned mid-scene.
# The region is in points; the screen is captured in pixels (2x).
IFS=, read x y w h <<< "$region"
/opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -y -f avfoundation -capture_cursor 1 -framerate 60 \
  -pixel_format uyvy422 -i "${SCREEN_DEVICE:-1}:none" -t "$secs" \
  -vf "crop=$((w*2)):$((h*2)):$((x*2)):$((y*2)),format=yuv420p" -c:v libx264 -preset ultrafast -crf 14 "$out" 2>/dev/null &
rec=$!
if [[ -n "$UNTIL_DONE" ]]; then
  while kill -0 $rec 2>/dev/null; do
    if tail -n +$from "$log" | grep -q "showcase: $scene done"; then sleep ${TAIL_HOLD:-1.5}; kill -INT $rec; break; fi
    sleep 0.5
  done
fi
wait $rec || true
kill %1 2>/dev/null || true
echo "$out"
