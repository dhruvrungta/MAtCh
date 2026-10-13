#!/bin/bash
#
# Builds what a release consists of:
#
#   Match-<version>.zip          the signed universal app
#   Match-<version>.zip.sha256   its SHA-256
#   latest.json                  what the installer and the in-app update check read
#
#     tools/build_release.sh <version> [options]
#
#     --build <number>        build number (default 1)
#     --identity <name|hash>  signing identity (default "Match Self-Signed")
#     --keychain <path>       look for the identity only in this keychain
#     --notes <text>          one line of release notes for latest.json
#     --out <directory>       where to put the files (default build/release)
#
# The same script runs on a developer's Mac ("make zip") and in the release workflow,
# so a release is built the same way in both places.

set -euo pipefail

version=""
build_number="1"
identity="Match Self-Signed"
keychain=""
notes=""
out_dir="build/release"

while [ $# -gt 0 ]; do
    case "$1" in
        --build)    build_number="${2:?--build needs a number}"; shift 2 ;;
        --identity) identity="${2:?--identity needs a value}"; shift 2 ;;
        --keychain) keychain="${2:?--keychain needs a path}"; shift 2 ;;
        --notes)    notes="${2:-}"; shift 2 ;;
        --out)      out_dir="${2:?--out needs a directory}"; shift 2 ;;
        -h|--help)  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)         echo "error: unknown option: $1" >&2; exit 2 ;;
        *)
            if [ -n "$version" ]; then
                echo "error: unexpected argument: $1" >&2
                exit 2
            fi
            version="$1"; shift ;;
    esac
done

case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "error: give a version such as 1.2.0" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."

# The repository that hosts the releases: taken from the workflow when there is one,
# otherwise from the project's build configuration.
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    owner="${GITHUB_REPOSITORY%%/*}"
    repository="${GITHUB_REPOSITORY##*/}"
else
    owner="$(sed -n 's/^ *MATCH_GITHUB_OWNER: *//p' project.yml)"
    repository="$(sed -n 's/^ *MATCH_GITHUB_REPOSITORY: *//p' project.yml)"
fi
if [ -z "$owner" ] || [ -z "$repository" ]; then
    echo "error: could not tell which repository hosts the releases" >&2
    exit 1
fi

derived="build/ReleaseDerivedData"
app="$derived/Build/Products/Release/Match.app"

echo "Building Match $version ($build_number) for $owner/$repository..."
xcodegen generate --quiet
# Built unsigned, then signed below, so that the signing step is the same whether the
# identity is in the login keychain or in a temporary one.
xcodebuild -project Match.xcodeproj -scheme Match -configuration Release \
    -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    MATCH_GITHUB_OWNER="$owner" MATCH_GITHUB_REPOSITORY="$repository" \
    -quiet build

echo "Signing with \"$identity\"..."
sign_arguments=(--force --options runtime --timestamp=none --entitlements Match/Match.entitlements --sign "$identity")
if [ -n "$keychain" ]; then
    sign_arguments+=(--keychain "$keychain")
fi
codesign "${sign_arguments[@]}" "$app"

tools/verify_signature.sh "$app"

mkdir -p "$out_dir"
zip_name="Match-$version.zip"
rm -f "$out_dir/$zip_name" "$out_dir/$zip_name.sha256" "$out_dir/latest.json"
# ditto keeps the signature intact, which plain zip does not.
ditto -c -k --keepParent "$app" "$out_dir/$zip_name"
(cd "$out_dir" && shasum -a 256 "$zip_name" > "$zip_name.sha256")
sha256="$(awk '{print $1}' "$out_dir/$zip_name.sha256")"

# The values go into a property list first and plutil turns that into JSON, so
# quotes and other awkward characters in the notes come out correctly escaped.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}
plist="$out_dir/latest.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>version</key><string>$(xml_escape "$version")</string>
    <key>url</key><string>$(xml_escape "https://github.com/$owner/$repository/releases/download/v$version/$zip_name")</string>
    <key>sha256</key><string>$(xml_escape "$sha256")</string>
    <key>notes</key><string>$(xml_escape "${notes:-Match $version}")</string>
</dict>
</plist>
PLIST
plutil -convert json -o "$out_dir/latest.json" "$plist"
rm -f "$plist"

echo
echo "Release files in $out_dir:"
echo "  $zip_name"
echo "  $zip_name.sha256   ($sha256)"
echo "  latest.json"
