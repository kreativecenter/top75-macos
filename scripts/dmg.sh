#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! -f "$1/Contents/Info.plist" ]]; then
  printf 'Usage: %s <path-to-TOP75.app> [path-to-output.dmg]\n' "$0" >&2
  exit 2
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$(cd "$1" && pwd)"
output="${2:-$project_dir/dist/TOP75-macOS.dmg}"
mkdir -p "$(dirname "$output")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/top75-dmg.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT

mkdir "$stage/volume"
ditto "$app" "$stage/volume/TOP75.app"
ln -s /Applications "$stage/volume/Applications"
hdiutil create -srcfolder "$stage/volume" -volname TOP75 -format UDZO "$stage/TOP75-macOS.dmg"
hdiutil verify "$stage/TOP75-macOS.dmg"
mv "$stage/TOP75-macOS.dmg" "$output"
(
  cd "$(dirname "$output")"
  name="$(basename "$output")"
  shasum -a 256 "$name" > "$name.sha256"
  cat "$name.sha256"
)
