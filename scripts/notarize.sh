#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  printf 'Usage: %s <Developer ID Application identity> <notarytool Keychain profile>\n' "$0" >&2
  exit 2
fi

identity="$1"
profile="$2"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
dist_dir="$project_dir/dist"
source_app="$dist_dir/TOP75.app"

if [[ ! -d "$source_app" ]]; then
  printf 'Run ./scripts/build.sh first.\n' >&2
  exit 1
fi

stage="$(mktemp -d "$dist_dir/.notarization.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/TOP75.app"
submission="$stage/submission.zip"
notarized_archive="$dist_dir/TOP75-macOS-notarized.zip"

ditto "$source_app" "$app"
codesign --force --sign "$identity" --options runtime --timestamp "$app"
codesign --verify --strict "$app"
if ! codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
  printf 'The app must be signed with a Developer ID Application certificate.\n' >&2
  exit 1
fi

ditto -c -k --keepParent "$app" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait --output-format json > "$stage/result.json"
cat "$stage/result.json"
if [[ "$(plutil -extract status raw "$stage/result.json")" != Accepted ]]; then
  submission_id="$(plutil -extract id raw "$stage/result.json")"
  xcrun notarytool log "$submission_id" --keychain-profile "$profile" >&2
  exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
"$app/Contents/MacOS/TOP75" --verify

ditto -c -k --keepParent "$app" "$stage/TOP75-macOS-notarized.zip"
unzip -tq "$stage/TOP75-macOS-notarized.zip"
mv "$stage/TOP75-macOS-notarized.zip" "$notarized_archive"
(cd "$dist_dir" && shasum -a 256 TOP75-macOS-notarized.zip > TOP75-macOS-notarized.zip.sha256)
cat "$notarized_archive.sha256"
