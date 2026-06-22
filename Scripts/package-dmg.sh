#!/bin/bash
# Build SuperIsland, Developer ID–sign, package a DMG, notarize, and staple it
# into a download anyone can run without Gatekeeper warnings.
#
# Usage:
#   Scripts/package-dmg.sh
#
# Required environment (paid Apple Developer account):
#   DEVELOPER_ID   Full identity, e.g. "Developer ID Application: Jane Doe (AB12CD34EF)"
#
# Notarization credentials — provide ONE of:
#   NOTARY_PROFILE   Name of a stored notarytool keychain profile, OR
#   APPLE_ID + TEAM_ID + APPLE_APP_PASSWORD   (app-specific password)
#
# The release .app is signed with hardened runtime + secure timestamp so it can
# be notarized; the .build/SuperIsland.app from build-app.sh is only for local
# dev (ad-hoc) and won't pass notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: …' identity}"

# --- 1. Build the release bundle (reuses build-app.sh assembly) -------------
SUPERISLAND_SIGN_IDENTITY="$DEVELOPER_ID" "$ROOT/Scripts/build-app.sh" release

APP="$ROOT/.build/SuperIsland.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0)"
DMG="$ROOT/.build/SuperIsland-$VERSION.dmg"

# --- 2. Re-sign with hardened runtime (notarization requires it) ------------
# build-app.sh signs without --options runtime, so re-sign here explicitly.
echo "Signing with hardened runtime ($DEVELOPER_ID)…"
codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- 3. Build the DMG -------------------------------------------------------
echo "Packaging $DMG…"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install affordance
hdiutil create -volname "SuperIsland" -srcfolder "$STAGING" \
    -ov -format UDZO "$DMG"
rm -rf "$STAGING"

# --- 4. Notarize -----------------------------------------------------------
echo "Submitting for notarization (this can take a few minutes)…"
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
    : "${APPLE_ID:?Set NOTARY_PROFILE, or APPLE_ID + TEAM_ID + APPLE_APP_PASSWORD}"
    : "${TEAM_ID:?Set TEAM_ID}"
    : "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD (app-specific password)}"
    xcrun notarytool submit "$DMG" \
        --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait
fi

# --- 5. Staple so it verifies offline --------------------------------------
echo "Stapling ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "Done: $DMG"
echo "Verify a clean install with: spctl -a -t open --context context:primary-signature \"$DMG\""
