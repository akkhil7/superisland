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
if [ -f "$BIN/KlipChromeNativeHost" ]; then
    cp "$BIN/KlipChromeNativeHost" "$MACOS/KlipChromeNativeHost"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$ROOT/Extensions/Chrome" ]; then
    rm -rf "$RES/ChromeExtension"
    cp -R "$ROOT/Extensions/Chrome" "$RES/ChromeExtension"
fi

# Onboarding art + brand fonts (fall back gracefully when absent).
mkdir -p "$RES/Onboarding"
for f in "$ROOT/website/assets/hero-aurora.webp" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Regular.ttf" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Italic.ttf"; do
    [ -f "$f" ] && cp "$f" "$RES/Onboarding/" || true
done

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
SIGN_ID="${KLIP_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    # Prefer a local self-signed dev identity. This keeps TCC grants stable
    # without using a personal Apple Development certificate.
    SIGN_ID="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Klip Dev/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    # Auto-pick a stable Apple identity only if no local Klip identity exists.
    # Falls back to ad-hoc ("-") only if none is found.
    SIGN_ID="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
SIGN_ID="${SIGN_ID:--}"
codesign --force --deep --sign "$SIGN_ID" "$APP"

echo "Built: $APP  (signed with: $SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
    echo "Note: ad-hoc signed — macOS re-prompts for permissions after each"
    echo "rebuild and Accessibility grants are unreliable. Set KLIP_SIGN_IDENTITY"
    echo "to a code-signing identity (e.g. an Apple Development cert) to fix this."
fi
echo "Run with: open \"$APP\"   (or: \"$MACOS/Klip\")"
