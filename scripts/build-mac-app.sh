#!/bin/sh
# Builds macos/PixlMemory, signs it with a stable self-signed identity ("Pixl Dev"), installs it
# to ~/Applications/Pixl Memory.app and (optionally) launches it.
#
#   scripts/build-mac-app.sh               build, sign, install
#   scripts/build-mac-app.sh --open        … and launch
#   scripts/build-mac-app.sh --debug       … and launch with PIXL_DEBUG=1 (log: ~/Library/Logs/PixlMemory/debug.log)
#   scripts/build-mac-app.sh --selftest    … and run the in-app click self-test (prints PASS/FAIL)
#
# Why a stable identity: macOS ties the Accessibility grant to the app's code signature. An
# ad-hoc signature changes on every build, so the grant was lost each time. A self-signed
# certificate keeps the same designated requirement across rebuilds.
#
# First run only: macOS may ask to let codesign use the "Pixl Dev" key. Enter your login
# password and choose "Always Allow". Set PIXL_SIGN_IDENTITY to use another identity.
set -eu
cd "$(git rev-parse --show-toplevel)"

IDENTITY="${PIXL_SIGN_IDENTITY:-Pixl Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DEST="$HOME/Applications/Pixl Memory.app"

ensure_identity() {
  # Our own certificate: look it up by name, and create it once if it's missing.
  if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then return; fi
  if [ "$IDENTITY" != "Pixl Dev" ]; then echo "No certificate named $IDENTITY in the login keychain." >&2; exit 1; fi
  echo "Creating the self-signed code-signing certificate \"Pixl Dev\" in your login keychain (once)…"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cert.conf" <<'CONF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Pixl Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.conf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  pass="$(openssl rand -hex 16)"
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "Pixl Dev" \
    -out "$tmp/pixl.p12" -passout "pass:$pass"
  security import "$tmp/pixl.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
  trap - EXIT
  echo "Created. (It isn't trusted system-wide and doesn't need to be: macOS only needs it to stay the same.)"
}

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

ensure_identity
codesign --force --sign "$IDENTITY" --identifier dev.pixlz.PixlMemory --timestamp=none "$APP"
echo "Signed with: $IDENTITY ($(codesign -dr - "$APP" 2>/dev/null | sed -n 's/^designated => //p' | cut -c1-80))"

# Install as a normal app. Quit the running copy first so the new one takes over.
pkill -x PixlMemory 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed: $DEST"

case "${1:-}" in
  --open)     open "$DEST" ;;
  --debug)    rm -f "$HOME/Library/Logs/PixlMemory/debug.log"
              open --env PIXL_DEBUG=1 "$DEST"
              echo "Debug log: tail -f ~/Library/Logs/PixlMemory/debug.log" ;;
  --selftest) PIXL_DEBUG=1 "$DEST/Contents/MacOS/PixlMemory" --selftest ;;
esac
