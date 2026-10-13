#!/bin/bash
#
# Checks that a built Match.app is signed the way a release must be:
#
#   - the signature is valid;
#   - its designated requirement names the signing certificate, not the hash of this
#     one build, so that every version has the same identity;
#   - the Hardened Runtime and the App Sandbox are on;
#   - it runs on both Apple silicon and Intel;
#   - it carries no trace of the debug-only mock-portal override.
#
#     tools/verify_signature.sh path/to/Match.app

set -euo pipefail

app="${1:-}"
if [ -z "$app" ] || [ ! -d "$app" ]; then
    echo "usage: $0 path/to/Match.app" >&2
    exit 2
fi
binary="$app/Contents/MacOS/Match"

fail() {
    echo "verify_signature: $1" >&2
    exit 1
}

codesign --verify --strict --verbose=2 "$app" || fail "the signature is not valid"

requirement="$(codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p')"
echo "designated requirement: $requirement"
case "$requirement" in
    *cdhash*) fail "the designated requirement is tied to this build's hash, so it would change with every version" ;;
esac
case "$requirement" in
    *'certificate leaf = H"'*) ;;
    *) fail "the designated requirement does not name the signing certificate" ;;
esac

details="$(codesign -dv "$app" 2>&1)"
echo "$details" | grep -q 'flags=.*runtime' || fail "the Hardened Runtime is off"

entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null || true)"
echo "$entitlements" | grep -q 'com.apple.security.app-sandbox' || fail "the App Sandbox entitlement is missing"

architectures="$(lipo -archs "$binary")"
echo "architectures: $architectures"
case " $architectures " in *" arm64 "*) ;; *) fail "the app does not run on Apple silicon" ;; esac
case " $architectures " in *" x86_64 "*) ;; *) fail "the app does not run on Intel" ;; esac

if strings -a "$binary" | grep -q 'MatchPortalBase'; then
    fail "the binary contains the debug-only mock-portal override"
fi

echo "verify_signature: ok"
