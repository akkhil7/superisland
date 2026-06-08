#!/bin/bash
# Build Klip and assemble a runnable .app bundle, ad-hoc signed.
#
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/.build/Klip.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$BIN/KlipApp" "$MACOS/Klip"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Sign so TCC (Accessibility / Screen Recording / Automation) can attach grants.
#
# Ad-hoc ("-") signatures change hash on every build, so macOS treats each build
# as a new app and re-prompts for permissions. Set KLIP_SIGN_IDENTITY to a
# stable self-signed code-signing identity to keep grants across rebuilds:
#
#   1. Keychain Access → Certificate Assistant → Create a Certificate…
#      Name "Klip Dev", Identity Type "Self Signed Root",
#      Certificate Type "Code Signing".
#   2. export KLIP_SIGN_IDENTITY="Klip Dev"
#
SIGN_ID="${KLIP_SIGN_IDENTITY:--}"
codesign --force --deep --sign "$SIGN_ID" "$APP"

echo "Built: $APP  (signed with: $SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
    echo "Note: ad-hoc signed — macOS will re-prompt for permissions after each"
    echo "rebuild. Set KLIP_SIGN_IDENTITY to a self-signed identity to avoid this."
fi
echo "Run with: open \"$APP\"   (or: \"$MACOS/Klip\")"
