#!/bin/sh
# Every check that runs without a device: the package tests on the Mac, the app build for the iOS and tvOS
# simulators and for the Mac, the repository tools. Exit code 0 when all pass.
#   sh tools/test.sh
# DELOS_DERIVED_DATA sets the simulator builds' derived data folder (default /tmp/delos-dd) and, with "-mac" appended,
# the Mac build's, so parallel worktrees do not lock each other's build database.
set -eu
cd "$(dirname "$0")/.."
dd="${DELOS_DERIVED_DATA:-/tmp/delos-dd}"

echo "== package tests (swift test)"
(cd Packages/DelosKit && swift test --quiet)

echo "== app build: iOS Simulator"
xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" build
echo "== app build: tvOS Simulator"
xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination 'generic/platform=tvOS Simulator' -derivedDataPath "$dd" build

echo "== app build: macOS (ad hoc signed)"
DELOS_MAC_DERIVED_DATA="$dd-mac" sh tools/mac.sh build

echo "== repository tools"
python3 tools/docs/check_links.py
python3 -m unittest discover -s tools/docs 2>&1 | tail -n 1
python3 -m unittest discover -s tools/l10n 2>&1 | tail -n 1
python3 tools/l10n/check_usage.py
sh tools/hooks/test-commit-msg.sh
sh tools/hooks/test-check-branch-name.sh
echo "== all checks passed"
