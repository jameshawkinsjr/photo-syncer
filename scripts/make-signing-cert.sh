#!/bin/bash
#
# Creates a self-signed code-signing certificate named "Photo Syncer Local Signing"
# in your login keychain, for builds on a Mac without an Apple Developer certificate.
#
#   scripts/make-signing-cert.sh
#
# Why: macOS ties the Photos permission to the app's signature. An ad-hoc signature
# changes on every build, so macOS forgets the permission after each rebuild. A
# certificate that stays the same keeps it. scripts/build-app.sh picks this one up
# automatically when there's no Developer ID or Apple Development certificate.
#
# The certificate is only good for this Mac: other Macs don't trust it, so apps you
# give away still need right-click › Open the first time. To remove it, delete
# "Photo Syncer Local Signing" in Keychain Access (both the certificate and its key).

set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/common.sh

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$LOCAL_SIGNING_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$LOCAL_SIGNING_NAME\" is already in your login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_SIGNING_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "==> Creating the certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
    -config "$WORK/cert.conf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# The .p12 only exists to carry the key into the keychain; it's deleted on exit.
PASSWORD="$(openssl rand -hex 16)"
LEGACY=()
if openssl version | grep -q "^OpenSSL 3"; then LEGACY=(-legacy); fi
openssl pkcs12 -export ${LEGACY[@]+"${LEGACY[@]}"} -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$LOCAL_SIGNING_NAME" -passout "pass:$PASSWORD" -out "$WORK/identity.p12"

echo "==> Adding it to your login keychain"
# -T lets codesign use the key without asking each time.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

echo "==> Checking that codesign can use it"
cp /usr/bin/true "$WORK/probe"
if codesign --force --sign "$LOCAL_SIGNING_NAME" "$WORK/probe" 2>"$WORK/codesign.log"; then
    echo "Done. scripts/build-app.sh now signs with \"$LOCAL_SIGNING_NAME\"."
    echo "Allow Photos access once more after the next build; after that it lasts across rebuilds."
else
    cat "$WORK/codesign.log" >&2
    echo "The certificate is in your keychain, but codesign couldn't use it (see above)." >&2
    exit 1
fi
