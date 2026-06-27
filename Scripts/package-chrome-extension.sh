#!/usr/bin/env bash
# Packages the Chrome Bridge extension into an upload-ready zip for the
# Chrome Web Store. Includes only the runtime files (README and the native-host
# template are not part of the extension).
#
# The `key` field is STRIPPED from the packaged manifest: the Chrome Web Store
# rejects a manifest containing `key` (it assigns the published ID itself). The
# source `Extensions/Chrome/manifest.json` keeps `key` so unpacked dev installs
# keep a stable native-messaging ID. See the Web Store spec for ID alignment.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Extensions/Chrome"
OUT="$ROOT/.build/SuperIslandChromeBridge.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$SRC/background.js" "$SRC/providers.js" "$SRC/content.js" "$SRC/visibility-keepalive.js" "$SRC/icons" "$STAGE/"
python3 - "$SRC/manifest.json" "$STAGE/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
manifest.pop("key", None)  # Web Store rejects a manifest with `key`
json.dump(manifest, open(sys.argv[2], "w"), indent=2)
PY

mkdir -p "$ROOT/.build"
rm -f "$OUT"
( cd "$STAGE" && zip -r -X "$OUT" manifest.json background.js providers.js content.js visibility-keepalive.js icons -x "*.DS_Store" >/dev/null )

echo "Packaged → $OUT  (key field stripped for the Web Store)"
unzip -l "$OUT"
