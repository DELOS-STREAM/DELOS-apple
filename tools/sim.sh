#!/bin/sh
# Builds DELOS for a simulator, installs it, starts it and saves a screenshot.
#   sh tools/sim.sh <device> [screenshot.png] [seconds before the screenshot]
# <device>: iphone (iPhone 18 Pro Max), ipad (iPad Pro 13-inch), tv (Apple TV 4K) or a simulator UDID.
# The simulators are created by Xcode; `xcrun simctl list devices` lists them. Build products go to /tmp/delos-dd.
set -eu
cd "$(dirname "$0")/.."

device=${1:?usage: sh tools/sim.sh <iphone|ipad|tv|UDID> [screenshot.png] [seconds]}
shot=${2:-}
wait=${3:-4}

find_device() {
    xcrun simctl list devices available | grep -F "    $1 (" | head -n 1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

case "$device" in
    iphone) udid=$(find_device "iPhone 18 Pro Max"); platform="iOS Simulator"; sdk=iphonesimulator ;;
    ipad) udid=$(find_device "iPad Pro 13-inch (M5)"); platform="iOS Simulator"; sdk=iphonesimulator ;;
    tv) udid=$(find_device "Apple TV 4K (4th generation)"); platform="tvOS Simulator"; sdk=appletvsimulator ;;
    *) udid=$device
       case "$(xcrun simctl list devices | grep -F "$udid")" in
           *"Apple TV"*) platform="tvOS Simulator"; sdk=appletvsimulator ;;
           *) platform="iOS Simulator"; sdk=iphonesimulator ;;
       esac ;;
esac
[ -n "$udid" ] || { echo "sim.sh: simulator for '$device' not found" >&2; exit 1; }

xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination "platform=$platform,id=$udid" -derivedDataPath /tmp/delos-dd build
app="/tmp/delos-dd/Build/Products/Debug-$sdk/DELOS.app"

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
xcrun simctl terminate "$udid" io.github.meitoncz.delos.debug 2>/dev/null || true
xcrun simctl launch "$udid" io.github.meitoncz.delos.debug >/dev/null
if [ -n "$shot" ]; then
    sleep "$wait"
    xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
    echo "$shot"
fi
