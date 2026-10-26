#!/bin/bash
# OPTIONAL, run once. Creates a private code-signing certificate that lives only in
# your login Keychain. Builds signed with it keep the same identity across updates,
# so macOS won't ask "Tidings wants to access your Keychain" after every update.
set -euo pipefail
NAME="Tidings Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ \"$NAME\" already exists."; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
PASS="tidings-$RANDOM$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" >/dev/null 2>&1
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "macOS will now ask for your login password to trust this certificate for code signing."
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem" || true
echo "✓ Created \"$NAME\". Future ./build.sh runs will use it."
