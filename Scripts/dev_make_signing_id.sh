#!/usr/bin/env bash
#
# dev_make_signing_id.sh — create a throwaway self-signed code-signing identity
# in a DEDICATED keychain whose password we control, so `codesign` works
# non-interactively without touching your (possibly out-of-sync) login keychain.
#
# This identity is self-signed: it lets you build/sign/launch the app locally
# and attempt the real SMAppService flow. Actual registration acceptance must
# be observed; signing alone does not establish it or distribution eligibility.
#
# Usage:  dev_make_signing_id.sh ["Identity Name"]
# Env:    DEV_SIGN_KEYCHAIN           (default ~/Library/Keychains/procexp-dev.keychain-db)
#         DEV_SIGN_KEYCHAIN_PASSWORD  supplied locally; no default, never printed
#         PROCEXP_SIGNING_KEYCHAIN_CREATE_APPROVED=1  explicit creation scope
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$REPO_ROOT/Scripts/helper_lifecycle_guard.py" identity

NAME="${1:-ProcexpMac Dev}"
[[ -n "$NAME" && "$NAME" != *$'\n'* && "$NAME" != *$'\r'* ]] || {
    echo "ERROR: expected a nonempty, single-line identity name" >&2
    exit 1
}
KEYCHAIN="${DEV_SIGN_KEYCHAIN:-$HOME/Library/Keychains/procexp-dev.keychain-db}"
KC_PASS="${DEV_SIGN_KEYCHAIN_PASSWORD:?Supply the new dedicated keychain password locally}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Generating self-signed code-signing certificate: \"$NAME\""
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/openssl.cnf" >/dev/null

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout env:DEV_SIGN_KEYCHAIN_PASSWORD >/dev/null

echo "==> Creating a new dedicated keychain: $KEYCHAIN"
[[ ! -e "$KEYCHAIN" && ! -L "$KEYCHAIN" ]] || {
    echo "ERROR: refusing to replace existing keychain: $KEYCHAIN" >&2
    exit 1
}
security create-keychain -p "$KC_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"          # no auto-lock timeout
security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"

echo "==> Importing identity and authorizing codesign…"
security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null

cat <<EOF

==> DONE. Identity imported: "$NAME"
    Keychain: $KEYCHAIN
    Certificate trust was not configured. Code signing may reject an untrusted
    identity; approving helper tests does not automatically change certificate trust.

Use it:
    DEV_SIGN_IDENTITY="$NAME" \\
    DEV_SIGN_KEYCHAIN="$KEYCHAIN" \\
    PROCEXP_HELPER_INSTALL_APPROVED=1 \\
    bash Scripts/dev_install_helper.sh

Remove it later:
    security delete-keychain "$KEYCHAIN"
EOF
