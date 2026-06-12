#!/bin/bash
# Create a local self-signed code-signing certificate named "Klip Dev".
#
# This keeps macOS TCC grants stable across local rebuilds without using a
# personal Apple Development certificate. Run once, then rebuild the app.
set -euo pipefail

NAME="${1:-Klip Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
P12_PASSWORD="klip-local-dev"

if security find-identity -v -p codesigning | grep -q "\"${NAME}\""; then
    echo "Code-signing identity already exists: ${NAME}"
    exit 0
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

OPENSSL_CONF="$TMPDIR/codesign.cnf"
KEY="$TMPDIR/codesign.key"
CRT="$TMPDIR/codesign.crt"
P12="$TMPDIR/codesign.p12"

cat > "$OPENSSL_CONF" <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = codesign_ext

[ dn ]
CN = ${NAME}
O = Klip Local Development

[ codesign_ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 \
    -keyout "$KEY" \
    -out "$CRT" \
    -config "$OPENSSL_CONF" >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$CRT" \
    -name "$NAME" \
    -out "$P12" \
    -passout "pass:${P12_PASSWORD}" >/dev/null 2>&1

security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASSWORD" \
    -A \
    -f pkcs12 \
    -T /usr/bin/codesign >/dev/null

security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN" \
    "$CRT" >/dev/null 2>&1 || true

security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "" \
    "$KEYCHAIN" >/dev/null 2>&1 || true

echo "Created local code-signing identity: ${NAME}"
echo "Next: ./Scripts/build-app.sh debug"
