#!/usr/bin/env bash
# Packages the Chrome Bridge extension into an upload-ready zip for the
# Chrome Web Store. Includes only the runtime files (README and the native-host
# template are not part of the extension). The `key` field is kept but the Web
# Store ignores it — see docs/superpowers/specs for the ID-consistency steps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Extensions/Chrome"
OUT="$ROOT/.build/SuperIslandChromeBridge.zip"

mkdir -p "$ROOT/.build"
rm -f "$OUT"

( cd "$SRC" && zip -r -X "$OUT" manifest.json background.js content.js icons -x "*.DS_Store" >/dev/null )

echo "Packaged → $OUT"
unzip -l "$OUT"
