#!/bin/sh
# Builds DELOS for this Mac (ad-hoc signed, sandboxed, hardened runtime), starts it and saves a screenshot of its window.
#   sh tools/mac.sh [screenshot.png] [seconds before the screenshot] [app arguments...]
#   sh tools/mac.sh build                 only builds (tools/test.sh)
# Build products go to /tmp/delos-dd-mac. The app arguments are the debug launch arguments of docs/BUILDING.md, such as
# `-DelosSettings stream`. DELOS_PROFILE=<name> puts a profile with that name into the app's container first (the app
# starts on its first-run screens without one, and Settings needs a profile). The screenshot needs the Screen Recording
# permission of the terminal that runs this script. The app is left running; quit it with Command-Q.
set -eu
cd "$(dirname "$0")/.."

dd=/tmp/delos-dd-mac
bundle=io.github.meitoncz.delos.debug
app="$dd/Build/Products/Debug/DELOS.app"

# No team: ad-hoc signature (`-`). Xcode leaves the hardened runtime off for an ad-hoc signature, so the flag turns it
# on, and the hardened runtime then needs the entitlement that lets the app load its own, equally ad-hoc signed,
# OpenSSL.framework (Config/DELOS-macOS-adhoc.entitlements).
build() {
    xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
        -destination "${1:-platform=macOS}" -derivedDataPath "$dd" \
        CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_STYLE=Manual \
        DELOS_ENTITLEMENTS=DELOS-macOS-adhoc.entitlements OTHER_CODE_SIGN_FLAGS=--options=runtime build
}

if [ "${1:-}" = build ]; then
    build 'generic/platform=macOS'
    exit 0
fi

shot=${1:-}
wait=${2:-4}
shift $(( $# < 2 ? $# : 2 ))

build

pids() { pgrep -f "$app/Contents/MacOS/DELOS" || true; }
stop() {
    for pid in $(pids); do kill "$pid" 2>/dev/null || true; done
    n=0
    while [ -n "$(pids)" ] && [ $n -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
}

stop

if [ -n "${DELOS_PROFILE:-}" ]; then
    prefs="$HOME/Library/Containers/$bundle/Data/Library/Preferences/$bundle.plist"
    if [ ! -d "$HOME/Library/Containers/$bundle" ]; then
        # The system makes the container when the app first starts
        open -n "$app"
        sleep 4
        stop
    fi
    id=$(uuidgen | tr 'A-Z' 'a-z')
    json=$(printf '{"all":[{"id":"%s","name":"%s","avatar":0}],"currentID":"%s"}' "$id" "$DELOS_PROFILE" "$id")
    defaults write "$prefs" profiles -data "$(printf %s "$json" | xxd -p | tr -d '\n')"
    # defaults writes through the preferences daemon, so the daemon and the file agree; no need to restart it
fi

open -n "$app" --args "$@"

# The id of the app's window, found by the app's process id
window_id() {
    osascript -l JavaScript -e '
        ObjC.import("CoreGraphics");
        const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
        const pids = "'"$(pids | tr '\n' ' ')"'".trim().split(/\s+/).map(Number);
        const w = list.find(w => pids.includes(w.kCGWindowOwnerPID) && w.kCGWindowLayer === 0);
        w ? w.kCGWindowNumber : "";'
}

if [ -n "$shot" ]; then
    id=""
    n=0
    while [ -z "$id" ] && [ $n -lt 50 ]; do
        sleep 0.4
        id=$(window_id)
        n=$((n + 1))
    done
    [ -n "$id" ] || { echo "mac.sh: DELOS opened no window" >&2; exit 1; }
    sleep "$wait"
    screencapture -x -o -l "$id" "$shot"
    echo "$shot"
fi
