#!/bin/bash
#
# Tests install.sh from start to finish without touching a real installation.
#
# It serves a made-up release from a local web server, and runs the installer against
# a made-up app, a made-up bundle identifier and a temporary home folder.
#
#     tools/test_install.sh

set -euo pipefail

cd "$(dirname "$0")/.."
installer="$PWD/install.sh"
test_id="com.dhruvrungta.match.installtest"
port="${MATCH_TEST_PORT:-8791}"

root="$(mktemp -d)"
server_pid=""
finish() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$root"
}
trap finish EXIT

site="$root/site"
home="$root/home"
apps="$root/apps"
mkdir -p "$site" "$home" "$apps"

passed=0
check() {
    # check "description" command...
    local description="$1"
    shift
    if "$@"; then
        passed=$((passed + 1))
        echo "  ok    $description"
    else
        echo "  FAIL  $description" >&2
        exit 1
    fi
}

contains() { grep -q -- "$2" <<< "$1"; }
lacks() { ! grep -q -- "$2" <<< "$1"; }

# Builds a stand-in Match.app whose only talent is recording that it was asked to clean up.
make_release() {
    local version="$1" identifier="$2" build="$root/build-$1"
    rm -rf "$build"
    mkdir -p "$build/Match.app/Contents/MacOS"
    cat > "$build/Match.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleExecutable</key><string>Match</string>
</dict></plist>
EOF
    cat > "$build/Match.app/Contents/MacOS/Match" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--uninstall-cleanup" ]; then
    touch "$HOME/cleanup-ran"
fi
EOF
    chmod +x "$build/Match.app/Contents/MacOS/Match"
    ditto -c -k --keepParent "$build/Match.app" "$site/Match-$version.zip"
}

publish() {
    local version="$1" sha256="${2:-}"
    [ -n "$sha256" ] || sha256="$(shasum -a 256 "$site/Match-$version.zip" | awk '{print $1}')"
    printf '{"version":"%s","url":"http://127.0.0.1:%s/Match-%s.zip","sha256":"%s","notes":"test"}' \
        "$version" "$port" "$version" "$sha256" > "$site/latest.json"
}

run_installer() {
    HOME="$home" MATCH_PAGES_URL="http://127.0.0.1:$port" MATCH_INSECURE_TEST=1 \
        MATCH_TEST_BUNDLE_ID="$test_id" bash "$installer" "$@"
}

installed_version() {
    defaults read "$apps/Match.app/Contents/Info" CFBundleShortVersionString 2>/dev/null
}

python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -fs "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
    sleep 0.3
done

echo "install"
make_release 1.0.0 "$test_id"
publish 1.0.0
run_installer --dir "$apps" --no-open >/dev/null
check "installs the app" test -d "$apps/Match.app"
check "installs the published version" test "$(installed_version)" = "1.0.0"
check "leaves the app runnable" test -x "$apps/Match.app/Contents/MacOS/Match"

echo "update"
make_release 1.1.0 "$test_id"
publish 1.1.0
output="$(run_installer --dir "$apps" --no-open)"
check "replaces the old version" test "$(installed_version)" = "1.1.0"
check "doesn't ask a user of a recent version to unlock" lacks "$output" "Unlock"

echo "update from a version before the vault"
defaults write "$apps/Match.app/Contents/Info" CFBundleShortVersionString 0.1.0
output="$(run_installer --dir "$apps" --no-open)"
check "asks the user to unlock once" contains "$output" "updated from Match 0.1.0"
check "and installs the new version" test "$(installed_version)" = "1.1.0"

echo "a download that doesn't match its checksum"
make_release 1.2.0 "$test_id"
publish 1.2.0 "0000000000000000000000000000000000000000000000000000000000000000"
if run_installer --dir "$apps" --no-open >/dev/null 2>&1; then
    echo "  FAIL  the installer accepted a bad checksum" >&2
    exit 1
fi
check "is refused" true
check "leaves the installed version alone" test "$(installed_version)" = "1.1.0"

echo "a download that isn't Match"
make_release 1.3.0 "com.example.somethingelse"
publish 1.3.0
if run_installer --dir "$apps" --no-open >/dev/null 2>&1; then
    echo "  FAIL  the installer accepted another app" >&2
    exit 1
fi
check "is refused" true
check "leaves the installed version alone" test "$(installed_version)" = "1.1.0"

echo "a real install refuses plain HTTP"
if HOME="$home" MATCH_PAGES_URL="http://127.0.0.1:$port" bash "$installer" --dir "$root/never" --no-open >/dev/null 2>&1; then
    echo "  FAIL  the installer downloaded over plain HTTP" >&2
    exit 1
fi
check "is refused" true
check "installs nothing" test ! -d "$root/never/Match.app"

echo "options"
check "--help works" bash -c "bash '$installer' --help | grep -q -- '--uninstall'"
check "--help works when piped in" bash -c "bash -s -- --help < '$installer' | grep -q -- '--uninstall'"
if bash "$installer" --nonsense >/dev/null 2>&1; then
    echo "  FAIL  an unknown option was accepted" >&2
    exit 1
fi
check "an unknown option is refused" true

echo "uninstall"
mkdir -p "$home/Library/Containers/$test_id/Data"
echo "history" > "$home/Library/Containers/$test_id/Data/sessions.json"
run_installer --uninstall --yes --dir "$apps" >/dev/null
check "asks the app to clean up after itself" test -f "$home/cleanup-ran"
check "removes the app" test ! -d "$apps/Match.app"
check "removes the app's data" test ! -d "$home/Library/Containers/$test_id"
check "uninstalling again is harmless" bash -c "HOME='$home' MATCH_INSECURE_TEST=1 MATCH_TEST_BUNDLE_ID='$test_id' bash '$installer' --uninstall --yes --dir '$apps' >/dev/null"

echo
echo "test_install: $passed checks passed"
