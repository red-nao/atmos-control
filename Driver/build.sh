#!/usr/bin/env bash
# Driver/build.sh — build, assemble, and ad-hoc sign atmos-control.driver
# Uses only CLT clang; no Xcode required.
# SIP must be disabled for coreaudiod to load the unsigned (ad-hoc) bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCES="$SCRIPT_DIR/Sources/AtmosDriver.c"
INFO_PLIST="$SCRIPT_DIR/Info.plist"

BUILD_DIR="$SCRIPT_DIR/.build"
BUNDLE_DIR="$BUILD_DIR/atmos-control.driver"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
BINARY="$MACOS_DIR/atmos-control"

SDK=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")

echo "==> SDK: $SDK"
echo "==> Building atmos-control.driver …"

# ── 1. Compile & link as a bundle ──────────────────────────────────────────
mkdir -p "$MACOS_DIR"

clang \
    -arch arm64 \
    -mmacosx-version-min=12.0 \
    -isysroot "$SDK" \
    -bundle \
    -o "$BINARY" \
    "$SOURCES" \
    -framework CoreAudio \
    -framework CoreFoundation \
    -framework AudioToolbox \
    -Wall \
    -Wextra \
    -Wno-unused-parameter \
    -O2

echo "==> Binary:  $BINARY"

# ── 2. Copy Info.plist ─────────────────────────────────────────────────────
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
echo "==> Info.plist copied."

# ── 3. Ad-hoc code sign ────────────────────────────────────────────────────
codesign --force --sign - --timestamp=none "$BUNDLE_DIR"
echo "==> Bundle signed (ad-hoc)."

# ── 4. Verify ──────────────────────────────────────────────────────────────
echo ""
echo "=== codesign -dv ==="
codesign -dv "$BUNDLE_DIR" 2>&1

echo ""
echo "=== Bundle layout ==="
find "$BUNDLE_DIR" -not -type d | sort

echo ""
echo "✓  Done: $BUNDLE_DIR"
