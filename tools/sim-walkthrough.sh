#!/bin/sh
# Builds DELOS for the iOS Simulator, creates a fresh simulator, launches the app with the demo harness (-DelosDemo: a fake PC,
# fake artwork and metadata, nothing real) on one screen and saves a screenshot; the simulator is deleted afterwards.
#   sh tools/sim-walkthrough.sh <ipad|iphone> <screen> [out.png] [extra launch arguments...]
# <screen>: start, home, devices, profile, pair, create, artwork, appsettings or settings:<stream|audio|controls|appearance|covers|devices|about>.
# Extra arguments, for example: -DelosDemoCommands "w3 menu" (side menu), "w3 options" (game menu), "w3 toast" (filter sheet),
# -DelosDemoInput controller|touch|keyboard, -DelosDemoApps 0 (empty library), -DelosStage 430x932, -DelosTheme light.
# Never the owner's devices and never the Mac app. The simulator's screenshot of a landscape iPad or iPhone is a rotated portrait
# buffer; it is rotated upright here.
set -eu
cd "$(dirname "$0")/.."

device=${1:?usage: sh tools/sim-walkthrough.sh <ipad|iphone> <screen> [out.png] [launch arguments...]}
screen=${2:?screen}
shot=${3:-/tmp/delos-$screen.png}
[ $# -ge 3 ] && shift 3 || shift $#

case "$device" in
    ipad) type=com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB ;;
    iphone) type=com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max ;;
    *) echo "sim-walkthrough.sh: device must be ipad or iphone" >&2; exit 1 ;;
esac
runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-2

xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/delos-dd build
udid=$(xcrun simctl create "delos-walkthrough-$$" "$type" "$runtime")
trap 'xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true; xcrun simctl delete "$udid" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" /tmp/delos-dd/Build/Products/Debug-iphonesimulator/DELOS.app
xcrun simctl launch "$udid" io.github.meitoncz.delos.debug -DelosDemo YES -DelosMuteMedia YES -DelosScreen "$screen" \
    -AppleLanguages "(en)" -AppleLocale en_US "$@" >/dev/null
sleep "${DELOS_WALKTHROUGH_WAIT:-10}"
xcrun simctl io "$udid" screenshot "$shot" >/dev/null 2>&1
# A landscape screenshot comes out as a portrait buffer
width=$(sips -g pixelWidth "$shot" | awk '/pixelWidth/ {print $2}')
height=$(sips -g pixelHeight "$shot" | awk '/pixelHeight/ {print $2}')
if [ "$height" -gt "$width" ]; then sips -r 270 "$shot" --out "$shot" >/dev/null; fi
echo "$shot"
