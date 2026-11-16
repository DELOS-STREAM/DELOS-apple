#!/bin/sh
# Every check that runs without a device: the package tests on the Mac, the app build for the iOS and tvOS
# simulators and for the Mac, the repository tools. Exit code 0 when all pass.
#   sh tools/test.sh
set -eu
cd "$(dirname "$0")/.."

echo "== package tests (swift test)"
(cd Packages/DelosKit && swift test --quiet)

echo "== app build: iOS Simulator"
xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/delos-dd build
echo "== app build: tvOS Simulator"
xcodebuild -quiet -project DELOS.xcodeproj -scheme DELOS -configuration Debug \
    -destination 'generic/platform=tvOS Simulator' -derivedDataPath /tmp/delos-dd build

echo "== app build: macOS (ad hoc signed)"
sh tools/mac.sh build

echo "== repository tools"
python3 tools/docs/check_links.py
python3 -m unittest discover -s tools/docs 2>&1 | tail -n 1
python3 -m unittest discover -s tools/l10n 2>&1 | tail -n 1
python3 tools/l10n/check_usage.py
sh tools/hooks/test-commit-msg.sh
sh tools/hooks/test-check-branch-name.sh
echo "== all checks passed"
