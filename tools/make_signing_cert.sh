#!/bin/bash
#
# Creates the long-lived self-signed code-signing certificate "Match Self-Signed".
#
# Signing every build with the same certificate gives the app a stable identity, so
# macOS keeps trusting its Keychain item and permissions from one build to the next.
#
# Run this once, by hand:
#
#     tools/make_signing_cert.sh
#
# It creates the certificate, exports it as a password-protected .p12, imports it
# into your login keychain and marks it as trusted for code signing (macOS asks for
# your login password for that last step).
#
#     tools/make_signing_cert.sh --export-only <directory>
#
# creates the .p12 without touching any keychain.
#
# The .p12 and its password are secrets. Never commit them.

set -euo pipefail

NAME="Match Self-Signed"
DAYS=3650
OPENSSL=/usr/bin/openssl
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

export_only=0
out_dir="$HOME/.match-signing"

while [ $# -gt 0 ]; do
    case "$1" in
        --export-only)
            export_only=1
            [ $# -ge 2 ] || { echo "error: --export-only needs a directory" >&2; exit 2; }
            out_dir="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [ "$export_only" -eq 0 ] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "\"$NAME\" is already in your keychain. Nothing to do."
    echo "To replace it, delete it in Keychain Access first, then run this script again."
    exit 0
fi

# The password protects the .p12 file. It goes to the tools through the environment,
# never on a command line that other processes could read, except for the one
# 'security import' call below, which offers no other way.
if [ -z "${P12_PASSWORD:-}" ]; then
    read -r -s -p "Choose a password for the .p12 file: " P12_PASSWORD
    echo
    read -r -s -p "Type it again: " confirmation
    echo
    [ "$P12_PASSWORD" = "$confirmation" ] || { echo "error: the passwords don't match" >&2; exit 1; }
fi
[ -n "$P12_PASSWORD" ] || { echo "error: the password can't be empty" >&2; exit 1; }
export P12_PASSWORD

umask 077
mkdir -p "$out_dir"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/cert.cnf" <<EOF
[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[subject]
CN = $NAME

[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days "$DAYS" \
    -config "$work_dir/cert.cnf" \
    -keyout "$work_dir/key.pem" -out "$work_dir/cert.pem" 2>/dev/null

p12="$out_dir/Match-signing.p12"
cert="$out_dir/Match-signing-cert.pem"

# OpenSSL 3 needs to be told to use the older encryption that macOS can import.
# The system's LibreSSL uses it already.
legacy_flags=()
if "$OPENSSL" version | grep -q '^OpenSSL 3'; then
    legacy_flags=(-legacy)
fi

"$OPENSSL" pkcs12 -export ${legacy_flags[@]+"${legacy_flags[@]}"} \
    -inkey "$work_dir/key.pem" -in "$work_dir/cert.pem" \
    -name "$NAME" -out "$p12" -passout env:P12_PASSWORD
cp "$work_dir/cert.pem" "$cert"

echo "Created $p12"
echo "        $cert (the public certificate; not secret)"

if [ "$export_only" -eq 0 ]; then
    echo
    echo "Importing into your login keychain..."
    security import "$p12" -k "$LOGIN_KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
    echo "Marking the certificate as trusted for code signing (macOS will ask for your password)..."
    security add-trusted-cert -r trustRoot -p codeSign -k "$LOGIN_KEYCHAIN" "$cert"

    echo
    if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
        echo "Done. \"$NAME\" is ready. Builds made with 'make' now use it."
    else
        echo "warning: the certificate was imported but is not listed as a valid signing identity." >&2
        echo "Open Keychain Access, find \"$NAME\", and set Code Signing to Always Trust." >&2
    fi
    echo "The first build may ask whether codesign can use the key: choose Always Allow."
fi

cat <<EOF

For GitHub Actions releases, add two repository secrets:

  SIGNING_CERT_P12        the output of:  base64 -i "$p12" | pbcopy
  SIGNING_CERT_PASSWORD   the password you just chose

Keep "$p12" somewhere safe and never commit it. Anyone who has it can sign
builds that macOS will treat as yours.
EOF
