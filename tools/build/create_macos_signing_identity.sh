#!/usr/bin/env bash
# tools/build/create_macos_signing_identity.sh
#
# ==============================================================================
# MODULE: macOS stable code-signing identity
# DESCRIPTION:
# Creates, once, the self-signed code-signing certificate that
# build_macos_app.sh signs ErgoptiPlus.app with, packed with its private key in
# a password-protected .p12, and prints the two GitHub repository secrets that
# carry it to the release build.
#
# USAGE:
#  bash tools/build/create_macos_signing_identity.sh [output-directory]
#  (default output directory: ~/ErgoptiPlus-signing)
#
# OUTPUT:
#  ErgoptiPlus-signing.p12         — certificate + private key, encrypted with
#                                    the printed password; back it up
#  ErgoptiPlus-signing.p12.base64  — the same .p12 on one line, the value of
#                                    MACOS_SIGNING_CERTIFICATE_BASE64
#  ErgoptiPlus-signing.cer.pem     — the public certificate alone
#
# RATIONALE:
#  - An ad hoc signature's designated requirement is the code hash, which every
#    build changes, so macOS drops the TCC and Login Items grants at each
#    update. A signature by one stable certificate has the requirement
#    `identifier "…" and certificate leaf = H"…"`, which every later build
#    signed with it satisfies. Self-signed is enough for that; no Apple
#    Developer ID is involved.
#  - Run it on the maintainer's machine, never in CI: a certificate generated
#    per run would be a new identity each time, exactly the ad hoc problem.
#  - The private key never leaves this script in clear: openssl writes it
#    encrypted with the .p12 password, and only the encrypted .p12 is kept.
#  - The .p12 uses PBE-SHA1-3DES with a SHA-1 MAC, which `security import`
#    accepts on every supported macOS; OpenSSL 3's AES default is refused by
#    older keychains.
#  - Existing output is never overwritten: replacing the certificate costs
#    every user one more re-grant, so it must be a deliberate act.
# ==============================================================================

set -euo pipefail

COMMON_NAME="ErgoptiPlus Self-Signed"
VALIDITY_DAYS=3650
BASENAME="ErgoptiPlus-signing"

log()  { printf '[macos-signing] %s\n' "$*" >&2; }
fail() { printf '[macos-signing] ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -le 1 ] || fail "Expected at most one argument: the output directory."
if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
	fail "Refusing to run in CI: a certificate created per run is a new code identity every time. Run it once on your own machine."
fi
command -v openssl >/dev/null 2>&1 || fail "missing required command: openssl"

OUT_DIR="${1:-$HOME/$BASENAME}"
P12="$OUT_DIR/$BASENAME.p12"
P12_BASE64="$OUT_DIR/$BASENAME.p12.base64"
CERT_PEM="$OUT_DIR/$BASENAME.cer.pem"

for target in "$P12" "$P12_BASE64" "$CERT_PEM"; do
	if [ -e "$target" ] || [ -L "$target" ]; then
		fail "Refusing to overwrite $target. A new certificate is a new code identity: every user would re-grant each permission once more. Keep the existing one, or move it away deliberately first."
	fi
done

umask 077
mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ergopti-signing-identity.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# 32 hex characters from the kernel's generator; openssl reads it from the
# environment, so it never appears in a process listing.
ERGOPTI_P12_PASSWORD="$(openssl rand -hex 16)"
[ "${#ERGOPTI_P12_PASSWORD}" -eq 32 ] || fail "Could not generate the .p12 password."
export ERGOPTI_P12_PASSWORD

cat > "$WORK_DIR/openssl.cnf" <<EOF
[ req ]
distinguished_name = subject
prompt = no
x509_extensions = code_signing

[ subject ]
CN = $COMMON_NAME

[ code_signing ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

log "Creating the certificate \"$COMMON_NAME\" (RSA 3072, $VALIDITY_DAYS days)"
# Without -nodes the key file is encrypted with the .p12 password.
openssl req -x509 -newkey rsa:3072 -sha256 -days "$VALIDITY_DAYS" \
	-config "$WORK_DIR/openssl.cnf" \
	-keyout "$WORK_DIR/key.pem" -passout env:ERGOPTI_P12_PASSWORD \
	-out "$WORK_DIR/cert.pem" \
	|| fail "openssl req failed to create the certificate."

pkcs12_options=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES)
# OpenSSL 3 defaults to a SHA-256 MAC; LibreSSL and OpenSSL 1.1 already use
# SHA-1 and may not know the option.
if openssl version | grep -q '^OpenSSL 3'; then
	pkcs12_options+=(-macalg sha1)
fi
set -o noclobber
openssl pkcs12 -export "${pkcs12_options[@]}" \
	-name "$COMMON_NAME" \
	-inkey "$WORK_DIR/key.pem" -passin env:ERGOPTI_P12_PASSWORD \
	-in "$WORK_DIR/cert.pem" \
	-passout env:ERGOPTI_P12_PASSWORD \
	-out "$WORK_DIR/identity.p12" \
	|| fail "openssl pkcs12 failed to pack the identity."

# Read the .p12 back with its password before handing anything out.
openssl pkcs12 -in "$WORK_DIR/identity.p12" -passin env:ERGOPTI_P12_PASSWORD \
	-nokeys -out /dev/null \
	|| fail "The new .p12 does not open with its password."

cp "$WORK_DIR/identity.p12" "$P12"
openssl base64 -A -in "$P12" > "$P12_BASE64"
printf '\n' >> "$P12_BASE64"
cp "$WORK_DIR/cert.pem" "$CERT_PEM"
set +o noclobber

FINGERPRINT="$(openssl x509 -in "$CERT_PEM" -noout -fingerprint -sha1 | sed 's/^.*=//; s/://g')"
EXPIRY="$(openssl x509 -in "$CERT_PEM" -noout -enddate | sed 's/^notAfter=//')"

cat <<EOF

Created the stable macOS code-signing identity "$COMMON_NAME".
  certificate SHA-1 : $FINGERPRINT
  expires           : $EXPIRY
  .p12              : $P12
  public certificate: $CERT_PEM

Add two repository secrets (GitHub > Settings > Secrets and variables >
Actions > New repository secret), each value on one line:

==== MACOS_SIGNING_CERTIFICATE_PASSWORD ====
$ERGOPTI_P12_PASSWORD
==== MACOS_SIGNING_CERTIFICATE_BASE64 (contents of $P12_BASE64) ====
$(cat "$P12_BASE64")
==== end ====

Or, with the GitHub CLI, from the repository checkout:
  gh secret set MACOS_SIGNING_CERTIFICATE_BASE64 < "$P12_BASE64"
  gh secret set MACOS_SIGNING_CERTIFICATE_PASSWORD   (then paste the password)

Keep the identity safe:
  - Store $BASENAME.p12 AND its password in your password manager (or another
    encrypted backup). The same certificate must sign every future release:
    losing it means a new certificate, and every user re-grants each
    permission once more.
  - Never commit the .p12, the .base64 file or the password.
  - Delete $P12_BASE64 once the secret is saved; the .p12 in your backup
    is enough to recreate it (openssl base64 -A -in $BASENAME.p12).
  - The release log prints the designated requirement of the app; it must
    name certificate H"$(printf '%s' "$FINGERPRINT" | tr 'A-F' 'a-f')".
EOF
