#!/bin/bash
#
# Checks that a built Match.app is signed the way a release must be:
#
#   - the signature is valid;
#   - its designated requirement names the signing certificate, not the hash of this
#     one build, so that every version has the same identity;
#   - the Hardened Runtime and the App Sandbox are on;
#   - it runs on both Apple silicon and Intel;
#   - it carries the vault exactly as committed, and the vault will answer it;
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

# The vault must be the committed one, untouched, and must be willing to talk to
# an app signed the way this one is.
repository="$(cd "$(dirname "$0")/.." && pwd)"
vault="$app/Contents/XPCServices/MatchVault.xpc"
[ -d "$vault" ] || fail "the vault is missing from the app"
codesign --verify --strict "$vault" || fail "the vault's signature is not valid"
embedded_vault="$(codesign -dvvv "$vault" 2>&1 | sed -n 's/^CDHash=//p')"
committed_vault="$(codesign -dvvv "$repository/Vault/MatchVault.xpc" 2>&1 | sed -n 's/^CDHash=//p')"
echo "vault code hash: $embedded_vault"
if [ -z "$embedded_vault" ] || [ "$embedded_vault" != "$committed_vault" ]; then
    fail "the vault inside the app is not the committed one; it was rebuilt or re-signed, and users would be asked to approve Keychain access again"
fi
app_certificate="$(printf '%s' "$requirement" | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | tr 'A-F' 'a-f')"
vault_certificate="$(sed -n 's/.*certificate leaf = H\\"\([0-9a-fA-F]*\)\\".*/\1/p' "$repository/Vault/Sources/VaultPeer.swift" | tr 'A-F' 'a-f')"
if [ -z "$vault_certificate" ] || [ "$app_certificate" != "$vault_certificate" ]; then
    fail "the app is signed with a different certificate from the one the vault answers to, so the vault would refuse it"
fi

if strings -a "$binary" | grep -q 'MatchPortalBase'; then
    fail "the binary contains the debug-only mock-portal override"
fi

echo "verify_signature: ok"
