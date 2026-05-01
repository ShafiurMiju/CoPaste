#!/bin/bash
# Creates a self-signed code signing certificate for Copaste in your login
# keychain. Run once. After that, every `make` build is signed with the same
# cert, so macOS TCC will preserve Accessibility (and any other) permission
# across rebuilds — no more re-granting on every version bump.
#
# Cost: zero. Apple Developer account: not required.
# Caveat: only your Mac can build with this cert. Anyone else cloning the
# repo would run this script on their own machine to make their own cert.

set -euo pipefail

CN="Copaste Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CN\""; then
  echo "→ '$CN' already exists in your login keychain. Nothing to do."
  echo "  Future 'make dmg' runs will sign with it."
  exit 0
fi

echo "→ Creating self-signed code signing certificate '$CN'…"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/req.conf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = $CN
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/req.conf" 2>/dev/null

# Keychain refuses to import empty-password PKCS12 bundles, so use a transient
# placeholder password that's only relevant for the few milliseconds between
# `openssl pkcs12 -export` and `security import`.
PASS="setup"
openssl pkcs12 -export \
  -out "$TMP/cert.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$CN" -password "pass:$PASS"

# -A: allow any application to use this key without an "allow access?" prompt.
# -T /usr/bin/codesign: also explicitly trust codesign (belt + braces).
security import "$TMP/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$PASS" \
  -A \
  -T /usr/bin/codesign

echo "✓ Created '$CN' and imported into login keychain."
echo
echo "Next steps:"
echo "  1. make dmg            # builds, signs with the new cert"
echo "  2. drag the DMG to Applications, launch, grant Accessibility once"
echo "  3. all future versions you build will inherit that grant"
