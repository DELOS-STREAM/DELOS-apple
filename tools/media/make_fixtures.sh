#!/bin/sh
# Makes the video test fixtures of DelosMediaTests: two frames (an IDR frame and a P frame) of 64 x 64 test pattern
# per codec, as the host sends them (H.264 and HEVC in Annex B, AV1 as low-overhead OBUs).
#   sh tools/media/make_fixtures.sh
# Needs ffmpeg with libx264, libx265 and libsvtav1. The encoders are not bit-exact across versions, so the files are
# kept in the repository with their checksums (docs/THIRD_PARTY.md); rerun only to replace them deliberately.
set -eu
cd "$(dirname "$0")/../.."
out=Packages/DelosKit/Tests/DelosMediaTests/Fixtures
src="-f lavfi -i testsrc2=size=64x64:rate=30 -frames:v 2 -pix_fmt yuv420p"

ffmpeg -hide_banner -loglevel error -y $src -c:v libx264 -profile:v high -bsf:v h264_mp4toannexb -f h264 "$out/frames.h264"
ffmpeg -hide_banner -loglevel error -y $src -c:v libx265 -x265-params log-level=error -f hevc "$out/frames.hevc"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=64x64:rate=30 -frames:v 2 -pix_fmt yuv420p10le \
    -c:v libsvtav1 -svtav1-params loglevel=0 -f obu "$out/frames-10bit.obu"
ffmpeg -hide_banner -loglevel error -y $src -c:v libsvtav1 -svtav1-params loglevel=0 -f obu "$out/frames.obu"
shasum -a 256 "$out"/frames*
