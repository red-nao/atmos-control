#!/usr/bin/env bash
# make-signing-cert.sh — create a STABLE, self-signed code-signing identity for local
# development, so TCC's "System Audio Recording" grant survives rebuilds.
#
# Why: a Core Audio process tap is gated by kTCCServiceAudioCapture. TCC keys the grant to
# the app's code signature. An ad-hoc signature (`codesign -s -`) produces a new cdhash on
# every build, so the grant can silently stop applying — and a denied grant looks exactly
# like working code: every Core Audio call returns noErr and the tap hands back silence.
#
# Usage:
#   bash tools/make-signing-cert.sh [identity-name]        # default: atmos-control-dev
#   CODESIGN_ID="atmos-control-dev" ./install.sh
#
# This only touches your LOGIN keychain. Remove it later with:
#   security delete-identity -c "atmos-control-dev" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="${1:-atmos-control-dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "==> identity \"$NAME\" already exists — nothing to do"
    echo "    use it with:  CODESIGN_ID=\"$NAME\" ./install.sh"
    exit 0
fi

echo "==> generating a self-signed code-signing certificate: $NAME"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass: >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout pass: >/dev/null 2>&1

echo "==> importing into the login keychain (you may be asked to allow access)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -A

echo "==> marking the certificate as trusted for code signing"
echo "    (a password prompt from macOS is expected here)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "==> OK. Identity \"$NAME\" is ready."
else
    cat <<EOT
==> The identity was imported but is not showing up as a valid codesigning identity.
    Fall back to Keychain Access:
      Keychain Access ▸ menu Certificate Assistant ▸ Create a Certificate…
        Name: $NAME
        Identity Type: Self Signed Root
        Certificate Type: Code Signing
      Then set the certificate's Trust ▸ Code Signing to "Always Trust".
EOT
fi

cat <<EOT

Next:
  CODESIGN_ID="$NAME" ./install.sh

Because the signing identity changed, macOS treats the app as new. Reset the old grant:
  tccutil reset AudioCapture dev.atmoscontrol.app
  tccutil reset ScreenCapture dev.atmoscontrol.app
Then relaunch and grant "System Audio Recording" when prompted.
EOT
