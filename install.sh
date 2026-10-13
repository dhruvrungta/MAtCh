#!/bin/bash
#
# Installs, updates or removes Match, the menu-bar app that signs you in to the VIT
# hostel Wi-Fi.
#
#   Install or update:
#       curl -fsSL https://dhruvrungta.github.io/match/install.sh | bash
#
#   Remove Match and everything it stored:
#       curl -fsSL https://dhruvrungta.github.io/match/install.sh | bash -s -- --uninstall
#
#   Options:
#       --uninstall     remove Match, its saved sign-in, settings and history
#       --yes           don't ask for confirmation when uninstalling
#       --system        install into /Applications with sudo if it isn't writable
#       --dir <folder>  install into this folder instead
#       --no-open       don't open Match after installing
#       --help          show this text
#
# It downloads one zip from this project's GitHub releases, checks its SHA-256
# against the published one, and copies Match.app into your Applications folder.
# It never asks for your Wi-Fi password and never uses sudo unless you pass --system.

set -euo pipefail

REPO_OWNER="dhruvrungta"
REPO_NAME="match"
BUNDLE_ID="com.dhruvrungta.match"
APP_NAME="Match.app"
MINIMUM_MACOS=14

# Where latest.json and this script are published. Forks can point this elsewhere.
PAGES_URL="${MATCH_PAGES_URL:-https://${REPO_OWNER}.github.io/${REPO_NAME}}"
# For this project's own tests only: allows a plain-HTTP local server to stand in for
# GitHub, and a made-up bundle identifier to stand in for Match's, so that a test can
# never touch a real installation. Never set this for a real install; it switches off
# the download checks.
INSECURE_TEST="${MATCH_INSECURE_TEST:-0}"
if [ "$INSECURE_TEST" = "1" ] && [ -n "${MATCH_TEST_BUNDLE_ID:-}" ]; then
    BUNDLE_ID="$MATCH_TEST_BUNDLE_ID"
fi

action="install"
assume_yes=0
use_sudo=0
open_after=1
install_dir=""
work_dir=""

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<USAGE
Installs, updates or removes Match.

  Install or update:
      curl -fsSL $PAGES_URL/install.sh | bash

  Remove Match and everything it stored:
      curl -fsSL $PAGES_URL/install.sh | bash -s -- --uninstall

  Options:
      --uninstall     remove Match, its saved sign-in, settings and history
      --yes           don't ask for confirmation when uninstalling
      --system        install into /Applications with sudo if it isn't writable
      --dir <folder>  install into this folder instead
      --no-open       don't open Match after installing
      --help          show this text
USAGE
}

cleanup() {
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --uninstall) action="uninstall" ;;
            --yes|-y)    assume_yes=1 ;;
            --system)    use_sudo=1 ;;
            --no-open)   open_after=0 ;;
            --dir)
                [ $# -ge 2 ] || fail "--dir needs a folder"
                install_dir="$2"
                shift
                ;;
            --help|-h)   usage; exit 0 ;;
            *)           fail "unknown option: $1 (try --help)" ;;
        esac
        shift
    done
}

check_macos() {
    [ "$(uname -s)" = "Darwin" ] || fail "Match only runs on macOS."
    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    case "$major" in
        ''|*[!0-9]*) fail "could not read the macOS version ($version)." ;;
    esac
    if [ "$major" -lt "$MINIMUM_MACOS" ]; then
        fail "Match needs macOS $MINIMUM_MACOS (Sonoma) or later. This Mac has macOS $version."
    fi
}

# Reads one string value out of a JSON file.
json_value() {
    plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

# Runs a command, with sudo when installing system-wide into a folder that needs it.
as_needed() {
    if [ "$use_sudo" -eq 1 ] && [ ! -w "$install_dir" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

choose_install_dir() {
    if [ -n "$install_dir" ]; then
        mkdir -p "$install_dir"
        return
    fi
    if [ -w /Applications ] || [ "$use_sudo" -eq 1 ]; then
        install_dir="/Applications"
    else
        install_dir="$HOME/Applications"
        mkdir -p "$install_dir"
        say "/Applications isn't writable, so Match will go into $install_dir."
        say "(Run again with --system to install into /Applications using sudo.)"
    fi
}

# Quits the copy of Match that lives at the given path, if it is running.
quit_app() {
    local app="$1" binary waited=0
    binary="$app/Contents/MacOS/Match"
    pgrep -f "$binary" >/dev/null 2>&1 || return 0
    say "Quitting Match..."
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    while pgrep -f "$binary" >/dev/null 2>&1; do
        if [ "$waited" -ge 10 ]; then
            pkill -f "$binary" >/dev/null 2>&1 || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

install() {
    check_macos
    choose_install_dir

    work_dir="$(mktemp -d)"
    local feed="$work_dir/latest.json" archive="$work_dir/Match.zip" unpacked="$work_dir/unpacked"
    local version url expected actual protocols="=https" destination="$install_dir/$APP_NAME"
    if [ "$INSECURE_TEST" = "1" ]; then
        protocols="=http,https"
    fi

    say "Looking up the latest version..."
    curl -fsSL --proto "$protocols" "$PAGES_URL/latest.json" -o "$feed" \
        || fail "couldn't reach $PAGES_URL. Check your internet connection and try again."
    version="$(json_value "$feed" version)" || fail "the release information could not be read."
    url="$(json_value "$feed" url)" || fail "the release information has no download address."
    expected="$(json_value "$feed" sha256)" || fail "the release information has no checksum."

    if [ "$INSECURE_TEST" != "1" ]; then
        case "$url" in
            "https://github.com/$REPO_OWNER/$REPO_NAME/releases/download/"*) ;;
            *) fail "the download address is not one of this project's releases: $url" ;;
        esac
    fi

    say "Downloading Match $version..."
    curl -fL --proto "$protocols" --progress-bar "$url" -o "$archive" || fail "the download failed."

    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" != "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" ]; then
        say "expected: $expected"
        say "got:      $actual"
        fail "the download's SHA-256 doesn't match the published one. Nothing was installed."
    fi
    say "Checksum verified."

    mkdir -p "$unpacked"
    ditto -x -k "$archive" "$unpacked" || fail "the download could not be unpacked."
    [ -d "$unpacked/$APP_NAME" ] || fail "the download doesn't contain $APP_NAME."
    local identifier
    identifier="$(defaults read "$unpacked/$APP_NAME/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    [ "$identifier" = "$BUNDLE_ID" ] || fail "the download isn't Match (found \"$identifier\")."

    quit_app "$destination"
    say "Installing into $install_dir..."
    as_needed rm -rf "$destination"
    as_needed ditto "$unpacked/$APP_NAME" "$destination"
    # A download is marked as quarantined; without this macOS refuses to open an app
    # that isn't notarized.
    as_needed xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true

    say "Match $version is installed."
    if [ "$open_after" -eq 1 ]; then
        open "$destination"
        say "Look for the Wi-Fi icon in the menu bar."
        say "If you updated, click it and choose Unlock so Match can use your saved sign-in."
    fi
}

# Asks the app to remove what only it can, giving up if it takes too long.
run_cleanup() {
    local binary="$1/Contents/MacOS/Match" pid waited=0
    [ -x "$binary" ] || return 0
    "$binary" --uninstall-cleanup 2>/dev/null &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge 15 ]; then
            kill "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    wait "$pid" 2>/dev/null || true
}

confirm_uninstall() {
    [ "$assume_yes" -eq 1 ] && return 0
    local answer=""
    # When this script arrives through a pipe, the keyboard is on /dev/tty.
    if [ -r /dev/tty ]; then
        printf 'Remove Match, its saved sign-in, settings and history? [y/N] ' > /dev/tty
        read -r answer < /dev/tty || answer=""
    else
        fail "can't ask for confirmation here. Run again with --yes to uninstall."
    fi
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) say "Nothing was removed."; exit 0 ;;
    esac
}

uninstall() {
    confirm_uninstall

    local found=0 app container="$HOME/Library/Containers/$BUNDLE_ID"
    local candidates=("/Applications/$APP_NAME" "$HOME/Applications/$APP_NAME")
    if [ -n "$install_dir" ]; then
        candidates=("$install_dir/$APP_NAME")
    fi

    for app in "${candidates[@]}"; do
        [ -d "$app" ] || continue
        found=1
        quit_app "$app"
        # Only Match itself can remove its Keychain item and its login item, so ask it to.
        run_cleanup "$app"
        say "Removing $app..."
        if [ -w "$(dirname "$app")" ]; then
            rm -rf "$app"
        elif [ "$use_sudo" -eq 1 ]; then
            sudo rm -rf "$app"
        else
            say "  $app couldn't be removed without sudo. Run again with --system, or drag it to the Bin."
        fi
    done

    # In case Match couldn't remove its own Keychain item (macOS only lets the exact
    # version that saved it do so without asking).
    if security find-generic-password -s "$BUNDLE_ID.credentials" >/dev/null 2>&1; then
        security delete-generic-password -s "$BUNDLE_ID.credentials" >/dev/null 2>&1 || true
    fi
    if security find-generic-password -s "$BUNDLE_ID.credentials" >/dev/null 2>&1; then
        say "The saved sign-in is still in your Keychain. To remove it, open Keychain Access,"
        say "search for \"Match Wi-Fi sign-in\" and delete it."
    fi

    # Match is sandboxed, so its settings and history live in its container.
    if [ -d "$container" ]; then
        rm -rf "$container" 2>/dev/null || true
    fi
    if [ -d "$container" ]; then
        say "macOS wouldn't let this script remove Match's data folder. To remove it, delete:"
        say "  $container"
    fi

    if [ "$found" -eq 1 ]; then
        say "Match has been removed."
    else
        say "Match wasn't found in /Applications or ~/Applications. Its saved data has been cleaned up."
    fi
}

main() {
    parse_arguments "$@"
    trap cleanup EXIT
    case "$action" in
        install)   install ;;
        uninstall) uninstall ;;
    esac
}

# Everything runs from here, so a download cut off part-way can't run half a script.
main "$@"
