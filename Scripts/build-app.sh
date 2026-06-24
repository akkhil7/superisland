#!/bin/bash
# Build SuperIsland and assemble a runnable .app bundle, ad-hoc signed.
#
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/.build/SuperIsland.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RES"

cp "$BIN/SuperIslandApp" "$MACOS/SuperIsland"
if [ -f "$BIN/SuperIslandChromeNativeHost" ]; then
    cp "$BIN/SuperIslandChromeNativeHost" "$MACOS/SuperIslandChromeNativeHost"
fi
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$ROOT/Extensions/Chrome" ]; then
    rm -rf "$RES/ChromeExtension"
    cp -R "$ROOT/Extensions/Chrome" "$RES/ChromeExtension"
fi

# Brand assets are vendored in the repo (Resources/Brand) so release/CI builds —
# where the separate website/ checkout is absent — still get the icon and art.
BRAND="$ROOT/Resources/Brand"

# Onboarding art + brand fonts (fall back gracefully when absent).
mkdir -p "$RES/Onboarding"
for f in "$BRAND/hero-aurora.webp" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Regular.ttf" \
         "$ROOT/Resources/Fonts/InstrumentSerif-Italic.ttf"; do
    [ -f "$f" ] && cp "$f" "$RES/Onboarding/" || true
done

# App icon (Finder / About / Settings) and the menu-bar colored face (no cape).
[ -f "$BRAND/AppIcon.icns" ] && cp "$BRAND/AppIcon.icns" "$RES/AppIcon.icns" || true
mkdir -p "$RES/Brand"
[ -f "$BRAND/superisland-menubar.png" ] && \
    cp "$BRAND/superisland-menubar.png" "$RES/Brand/superisland-menubar.png" || true

# --- Embed Sparkle.framework -------------------------------------------------
# SPM builds Sparkle into the bin dir; copy it into the bundle and point the
# executable's loader at Contents/Frameworks so the app finds it at runtime.
SPARKLE_FW="$BIN/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/SuperIsland" 2>/dev/null || true
else
    echo "WARNING: Sparkle.framework not found at $SPARKLE_FW — auto-update will not work"
fi

# Sign so TCC (Accessibility / Screen Recording / Automation) can attach grants.
#
# Ad-hoc ("-") signatures change hash on every build, so macOS treats each build
# as a new app and re-prompts for permissions. Set SUPERISLAND_SIGN_IDENTITY to a
# stable self-signed code-signing identity to keep grants across rebuilds:
#
#   1. Keychain Access → Certificate Assistant → Create a Certificate…
#      Name "SuperIsland Dev", Identity Type "Self Signed Root",
#      Certificate Type "Code Signing".
#   2. export SUPERISLAND_SIGN_IDENTITY="SuperIsland Dev"
#
SIGN_ID="${SUPERISLAND_SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
    # Prefer a local self-signed dev identity. This keeps TCC grants stable
    # without using a personal Apple Development certificate.
    SIGN_ID="$(security find-identity -v -p codesigning \
        | awk -F'"' '/SuperIsland Dev/ {print $2; exit}')"
fi
if [ -z "$SIGN_ID" ]; then
    # Auto-pick a stable Apple identity only if no local SuperIsland identity exists.
    # Falls back to ad-hoc ("-") only if none is found.
    SIGN_ID="$(security find-identity -v -p codesigning \
        | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi
SIGN_ID="${SIGN_ID:--}"
FW="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FW" ]; then
    # Sign nested helpers first (paths use Sparkle's current version dir).
    for nested in \
        "$FW/Versions/Current/XPCServices/Installer.xpc" \
        "$FW/Versions/Current/XPCServices/Downloader.xpc" \
        "$FW/Versions/Current/Autoupdate" \
        "$FW/Versions/Current/Updater.app"; do
        [ -e "$nested" ] && codesign --force --options runtime --timestamp \
            --sign "$SIGN_ID" "$nested"
    done
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$FW"
fi
# A second executable in Contents/MacOS is NOT covered when codesign signs the
# bundle, so it stays ad-hoc (linker-signed) from `swift build` and fails
# notarization ("not signed with a valid Developer ID"). Sign it explicitly.
[ -f "$MACOS/SuperIslandChromeNativeHost" ] && codesign --force --options runtime --timestamp \
    --sign "$SIGN_ID" "$MACOS/SuperIslandChromeNativeHost"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built: $APP  (signed with: $SIGN_ID)"
if [ "$SIGN_ID" = "-" ]; then
    echo "Note: ad-hoc signed — macOS re-prompts for permissions after each"
    echo "rebuild and Accessibility grants are unreliable. Set SUPERISLAND_SIGN_IDENTITY"
    echo "to a code-signing identity (e.g. an Apple Development cert) to fix this."
fi
echo "Run with: open \"$APP\"   (or: \"$MACOS/SuperIsland\")"
