#!/usr/bin/env bash
# Export the approved Icon Composer artwork for About's Any/Dark image assets.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
developer_dir="$(xcode-select -p)"
icon_tool="$developer_dir/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$icon_tool" ]]; then
  echo "error: Icon Composer's ictool is required; select a full Xcode installation." >&2
  exit 1
fi

resources="$repo_root/apps/native/WolfWave/Resources"
for icon in AppIcon AppIcon-Dev; do
  for rendition in Default Dark; do
    output_file="$resources/Assets.xcassets/About-$icon.imageset/$rendition.png"
    "$icon_tool" "$resources/$icon.icon" --export-image \
      --output-file "$output_file" \
      --platform macOS --rendition "$rendition" --width 256 --height 256 --scale 1
    test -s "$output_file"
  done
done
