#!/bin/bash
# build-app.sh — bundle the SwiftPM AtmosControlApp binary into atmos-control.app
# (CLT-only, no Xcode). Menu-bar agent (LSUIElement).
#
# Signing: a Core Audio process tap is gated by TCC (kTCCServiceAudioCapture, shown as
# "System Audio Recording Only"). TCC keys its grant to the app's code signature, so an
# ad-hoc signature — whose cdhash changes on EVERY build — makes the grant unstable and
# can stop the prompt from ever appearing. Set a stable identity:
#
#   bash tools/make-signing-cert.sh            # once: creates a self-signed identity
#   CODESIGN_ID="atmos-control-dev" ./install.sh
#
# Without CODESIGN_ID we still build (ad-hoc), but print a loud warning.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="atmos-control"
BUNDLE_ID="dev.atmoscontrol.app"
DIST="dist"
APP="$DIST/$APP_NAME.app"
CODESIGN_ID="${CODESIGN_ID:-}"

echo "==> swift build -c $CONFIG --product AtmosControlApp"
swift build -c "$CONFIG" --product AtmosControlApp
BIN=".build/$CONFIG/AtmosControlApp"
[ -f "$BIN" ] || { echo "binary not found: $BIN"; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>     <string>atmos-control</string>
  <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>0.1</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSMinimumSystemVersion</key>  <string>15.0</string>
  <key>LSUIElement</key>             <true/>
  <key>NSHighResolutionCapable</key> <true/>
  <!-- REQUIRED for Core Audio process taps (kTCCServiceAudioCapture). Without this key
       macOS denies system-audio capture SILENTLY: every Core Audio call returns noErr and
       the tap delivers zero-filled buffers, while a muting tap still silences the apps. -->
  <key>NSAudioCaptureUsageDescription</key>
  <string>atmos-control reads the audio your Mac is playing so it can equalize and spatialize it. Nothing is recorded or sent anywhere.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>atmos-control reads system audio from the virtual output device in order to spatialize it.</string>
  <key>NSMotionUsageDescription</key>
  <string>atmos-control uses AirPods head-motion to visualize and track your head position for spatial audio.</string>
</dict>
</plist>
PLIST

# Fail fast if the TCC key ever goes missing again (this is the #1 silent-failure mode).
if ! /usr/bin/plutil -p "$APP/Contents/Info.plist" | grep -q 'NSAudioCaptureUsageDescription'; then
    echo "ERROR: NSAudioCaptureUsageDescription missing from the built Info.plist" >&2
    exit 1
fi

if [ -n "$CODESIGN_ID" ]; then
    echo "==> codesign with identity: $CODESIGN_ID"
    codesign --force --sign "$CODESIGN_ID" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "==> codesign ad-hoc (no CODESIGN_ID set)"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    cat >&2 <<'WARN'
WARNING: ad-hoc signature. TCC binds the "System Audio Recording" grant to the code
         signature, and an ad-hoc cdhash changes on every build — the permission can
         silently stop applying after a rebuild (symptom: total silence, or a brief
         blip of sound whenever settings change).
         Fix once:  bash tools/make-signing-cert.sh
         Then:      CODESIGN_ID="atmos-control-dev" ./install.sh
WARN
fi

codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true

echo "==> done: $APP"
echo "    launch:  open \"$APP\"      (menu-bar glyph appears top-right)"
echo "    preview: ATMOS_PREVIEW=1 open -n \"$APP\"   (opens the panel in a window)"
