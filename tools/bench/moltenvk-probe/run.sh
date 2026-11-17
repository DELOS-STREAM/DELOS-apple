#!/bin/sh
# Runs PyroWave's own Vulkan shaders on MoltenVK on this Mac (issue #13, docs/PYROWAVE_APPLE.md): feature report, pipeline
# creation and the inverse transform at 1080p and 4K. A command-line tool; no app is started.
#   sh tools/bench/moltenvk-probe/run.sh [path to the DELOS for Android checkout, default ../Delos]
# Needs: network (once), clang, Python 3. Writes only to a temporary directory.
set -eu
cd "$(dirname "$0")"

ANDROID="${1:-../../../../Delos}"
SLANGMOSH="$ANDROID/app/src/main/jni/pyrowave/pyrowave/shaders/slangmosh.hpp"
HEADERS="$ANDROID/app/src/main/jni/pyrowave/pyrowave/Granite/third_party/khronos/vulkan-headers/include"
[ -f "$SLANGMOSH" ] || { echo "no $SLANGMOSH: pass the DELOS for Android checkout as the first argument" >&2; exit 2; }

# MoltenVK 1.4.2, macOS package of the GitHub release (Apache-2.0). The checksum is the one GitHub lists for the asset.
URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar"
SHA256="f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"

WORK="$(mktemp -d /tmp/delos-moltenvk-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/MoltenVK-macos.tar" "$URL"
echo "$SHA256  $WORK/MoltenVK-macos.tar" | shasum -a 256 -c - >/dev/null || { echo "checksum mismatch" >&2; exit 1; }
tar -xf "$WORK/MoltenVK-macos.tar" -C "$WORK" MoltenVK/MoltenVK/dynamic/dylib/macOS
DYLIB_DIR="$WORK/MoltenVK/MoltenVK/dynamic/dylib/macOS"

python3 extract_spirv.py "$SLANGMOSH" "$WORK/spv"
clang -O2 -o "$WORK/probe" probe.c -I"$HEADERS" -L"$DYLIB_DIR" -lMoltenVK -Wl,-rpath,"$DYLIB_DIR"

run() {
    # $1 shader, $2 width, $3 height, $4 chroma, $5 levels stored as 16-bit floats
    printf '\n== %s %sx%s %s\n' "$1" "$2" "$3" "$4"
    MVK_CONFIG_LOG_LEVEL=1 "$WORK/probe" "$WORK/spv/$1.spv" "$WORK/spv/dequant_mode1.spv" "$2" "$3" "$4" 700 "$5" 2>&1
}

run idwt_p1_fp16 1920 1080 420 2
run idwt_p1_fp16 1920 1080 444 2
run idwt_p1_fp16 3840 2160 420 2
run idwt_p1_fp16 3840 2160 444 2
run idwt_p0_fp16 1920 1080 420 5
run idwt_p0_fp16 3840 2160 420 5
