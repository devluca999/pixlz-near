#!/bin/sh
# Builds macos/PixlMemory into build/Pixl Memory.app and (optionally) opens it.
#   scripts/build-mac-app.sh          build
#   scripts/build-mac-app.sh --open   build and launch
# Signs with $PIXL_SIGN_IDENTITY or the first "Apple Development" identity; otherwise ad-hoc.
# With an ad-hoc signature macOS forgets the Accessibility grant after every rebuild (TN3127).
set -eu
cd "$(git rev-parse --show-toplevel)"

swift build -c release --package-path macos/PixlMemory --product PixlMemory
BIN="$(swift build -c release --package-path macos/PixlMemory --show-bin-path)/PixlMemory"

APP="build/Pixl Memory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PixlMemory"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.pixlz.PixlMemory</string>
  <key>CFBundleName</key><string>Pixl Memory</string>
  <key>CFBundleDisplayName</key><string>Pixl Memory</string>
  <key>CFBundleExecutable</key><string>PixlMemory</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

IDENTITY="${PIXL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc. After each rebuild, re-enable Pixl Memory in System Settings → Privacy & Security → Accessibility."
fi
echo "Built: $APP"

if [ "${1:-}" = "--open" ]; then
  pkill -x PixlMemory 2>/dev/null || true
  open "$APP"
fi
