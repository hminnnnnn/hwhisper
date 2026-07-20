#!/usr/bin/env bash
# Creates a self-signed "hwhisper-dev" code-signing certificate and imports
# it into the login keychain, so scripts/make-app.sh can sign Hwhisper.app
# with a STABLE identity across rebuilds instead of ad-hoc (`codesign
# --sign -`).
#
# Why this matters: ad-hoc signing derives the code signature purely from
# the binary's own hash, so every rebuild produces a signature macOS has
# never seen before. TCC (Microphone / Accessibility permission grants) is
# keyed off that code signature — so every rebuild silently invalidates
# previously-granted permissions, and the user sees the request/prompt
# behavior recur even though they already granted access. A persistent
# self-signed identity keeps the signature (and therefore the TCC grant)
# stable across rebuilds.
#
# Usage: bash scripts/make-signing-cert.sh
set -euo pipefail

CERT_NAME="hwhisper-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Checking for an existing '$CERT_NAME' codesigning identity"
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Found an existing '$CERT_NAME' identity in the login keychain — nothing to do."
    echo "If 'bash scripts/make-app.sh' still falls back to ad-hoc signing with it"
    echo "present, the certificate likely isn't trusted for code signing yet — see"
    echo "the manual trust step in README.md."
    exit 0
fi

echo "==> Generating a self-signed code-signing certificate ($CERT_NAME)"
CONFIG_FILE="$WORK_DIR/codesign.cnf"
cat > "$CONFIG_FILE" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = hwhisper-dev

[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

KEY_FILE="$WORK_DIR/hwhisper-dev.key"
CERT_FILE="$WORK_DIR/hwhisper-dev.crt"
P12_FILE="$WORK_DIR/hwhisper-dev.p12"
P12_PASSWORD="hwhisper"

openssl req -x509 -newkey rsa:2048 -keyout "$KEY_FILE" -out "$CERT_FILE" \
    -days 3650 -nodes -config "$CONFIG_FILE" -extensions ext

echo "==> Packaging as PKCS#12 for keychain import"
openssl pkcs12 -export -legacy -out "$P12_FILE" -inkey "$KEY_FILE" -in "$CERT_FILE" -passout "pass:$P12_PASSWORD"

echo "==> Importing into the login keychain"
security import "$P12_FILE" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

cat <<'EOF'

==> Certificate imported. One MANUAL step remains — macOS requires explicit
    user confirmation in the Keychain Access UI before codesign will
    actually trust a self-signed code-signing certificate (this cannot be
    scripted without additional prompts/entitlements):

    1. Open Keychain Access (Spotlight > "Keychain Access").
    2. In the sidebar, select the "login" keychain and the "My Certificates"
       category.
    3. Find "hwhisper-dev", double-click it to open the certificate panel.
    4. Expand "Trust", set "Code Signing" to "Always Trust".
    5. Close the panel (enter your macOS account password if prompted).

After that, re-run:

    bash scripts/make-app.sh

It will detect and use this identity automatically instead of falling back
to ad-hoc signing, so future rebuilds keep the same code signature and your
Microphone/Accessibility permission grants survive rebuilds.
EOF
