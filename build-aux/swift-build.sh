#!/bin/sh
# Builds both programs with SwiftPM and copies them to where Meson expects them.
# Usage: swift-build.sh <swift> <source dir> <scratch dir> <output dir> [swift build arguments...]
set -eu
swift=$1 source=$2 scratch=$3 output=$4
shift 4
"$swift" build --package-path "$source" --scratch-path "$scratch" -c release "$@"
bin=$("$swift" build --package-path "$source" --scratch-path "$scratch" -c release "$@" --show-bin-path)
cp "$bin/spacestate-desktop" "$bin/spacestate-settings" "$output/"
