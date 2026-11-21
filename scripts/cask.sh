#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf 'Usage: %s <version> [path-to-homebrew-tap]\n' "$0" >&2
  exit 2
fi

version="${1#v}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
tap="${2:-$(dirname "$project_dir")/homebrew-tap}"
cask="$tap/Casks/top75.rb"
url="https://github.com/kreativecenter/top75-macos/releases/download/v$version/TOP75-macOS.dmg"
sha="$(curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')"

sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
grep -E '^  (version|sha256) ' "$cask"
