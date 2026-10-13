#!/bin/bash
#
# Checks the vault for real: builds the app signed with "Match Self-Signed", then
# saves, reads and removes a test item through the vault, and confirms that the
# Keychain records the vault, not the app, as the item's owner.
#
# It needs the signing certificate, so it runs on the maintainer's Mac and not in CI.
# It uses an item of its own and never touches the real saved sign-in.
#
#     tools/test_vault.sh

set -euo pipefail

cd "$(dirname "$0")/.."
app="build/DerivedData/Build/Products/Debug/Match.app"
binary="$app/Contents/MacOS/Match"
item="com.dhruvrungta.match.vault.credentials.check"

fail() {
    echo "test_vault: $1" >&2
    exit 1
}

if ! security find-identity -v -p codesigning | grep -q '"Match Self-Signed"'; then
    fail "the \"Match Self-Signed\" certificate is not installed, and the vault only answers apps signed with it"
fi

make build > /dev/null

# Runs one check, giving up if it hangs, which would mean macOS is showing a dialog.
check() {
    local output pid waited=0
    output="$(mktemp)"
    "$binary" --vault-check "$1" > "$output" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge 20 ]; then
            kill "$pid" 2>/dev/null || true
            rm -f "$output"
            fail "'$1' did not finish: macOS is probably showing a Keychain dialog"
        fi
        sleep 0.5
        waited=$((waited + 1))
    done
    grep 'vault-check' "$output" || true
    rm -f "$output"
}

vault_hash="$(codesign -dvvv "$app/Contents/XPCServices/MatchVault.xpc" 2>&1 | sed -n 's/^CDHash=//p')"
committed_hash="$(codesign -dvvv Vault/MatchVault.xpc 2>&1 | sed -n 's/^CDHash=//p')"
[ "$vault_hash" = "$committed_hash" ] || fail "the vault inside the app is not the committed one"

result="$(check save)"
echo "$result"
[ "$result" = "vault-check save: ok" ] || fail "saving through the vault failed"

result="$(check load)"
echo "$result"
case "$result" in
    "vault-check load: found an item"*) ;;
    *) fail "reading through the vault failed" ;;
esac

owner="$(security dump-keychain -a "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
    | awk 'BEGIN { RS = "keychain: " } /"'"$item"'"/' \
    | sed -n 's/.*description: cdhash:\([0-9a-f]*\).*/\1/p' | head -1)"
echo "Keychain item owner: $owner"
[ "$owner" = "$vault_hash" ] || fail "the Keychain item is not owned by the vault"

result="$(check clear)"
echo "$result"
[ "$result" = "vault-check clear: ok" ] || fail "removing through the vault failed"

echo "test_vault: ok (vault $vault_hash)"
