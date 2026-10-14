#!/bin/bash
#
# Builds and signs Vault/MatchVault.xpc, the small service that holds the saved sign-in.
#
# RUN THIS ONLY WHEN THE VAULT ITSELF HAS TO CHANGE. The whole point of the vault is
# that it is the same program in every release, so that macOS never asks the user to
# approve it again. Every run of this script produces a different program as far as
# the Keychain is concerned, and everyone who updates past it is asked once more.
#
#     tools/build_vault.sh [--identity "Match Self-Signed"]
#
# The result is committed to the repository, so releases and other people's builds
# use the vault as it is and never rebuild it.

set -euo pipefail

identity="Match Self-Signed"
while [ $# -gt 0 ]; do
    case "$1" in
        --identity) identity="${2:?--identity needs a name}"; shift 2 ;;
        -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "error: unknown option: $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

# The vault only answers apps signed with this certificate, so it has to know which.
certificate_hash="$(security find-certificate -c "$identity" -Z | awk '/SHA-1/ {print tolower($NF); exit}')"
if [ -z "$certificate_hash" ]; then
    echo "error: no certificate named \"$identity\" in your keychain. Run tools/make_signing_cert.sh first." >&2
    exit 1
fi

cat > Vault/Sources/VaultPeer.swift <<EOF
// Written by tools/build_vault.sh. Do not edit by hand.

enum VaultPeer {
    /// Who may talk to the vault: Match itself, signed with the project's certificate.
    static let requirement =
        "identifier \"com.dhruvrungta.match\" and certificate leaf = H\"$certificate_hash\""
}
EOF

work="build/vault"
rm -rf "$work"
mkdir -p "$work"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
for architecture in arm64 x86_64; do
    xcrun swiftc -O -swift-version 5 -sdk "$sdk" -target "$architecture-apple-macos14.0" \
        Vault/Sources/*.swift -o "$work/MatchVault-$architecture"
done

bundle="Vault/MatchVault.xpc"
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
lipo -create -output "$bundle/Contents/MacOS/MatchVault" "$work/MatchVault-arm64" "$work/MatchVault-x86_64"
cp Vault/Info.plist "$bundle/Contents/Info.plist"

codesign --force --options runtime --timestamp=none \
    --entitlements Vault/Vault.entitlements --sign "$identity" "$bundle"
codesign --verify --strict "$bundle"

echo "Built $bundle"
echo "  architectures: $(lipo -archs "$bundle/Contents/MacOS/MatchVault")"
echo "  code hash:     $(codesign -dvvv "$bundle" 2>&1 | sed -n 's/^CDHash=//p')"
echo "  answers only:  identifier \"com.dhruvrungta.match\" and certificate leaf = H\"$certificate_hash\""
echo "Commit Vault/MatchVault.xpc and Vault/Sources/VaultPeer.swift together."
