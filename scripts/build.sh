#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/release-bundle"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/TOP75.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS"

for architecture in arm64 x86_64; do
  xcrun swiftc -O -swift-version 6 -parse-as-library \
    -target "$architecture-apple-macos14.0" \
    -module-cache-path "$build_dir/cache-$architecture" \
    "$project_dir"/Sources/TOP75/*.swift -o "$build_dir/TOP75-$architecture"
done

xcrun lipo -create "$build_dir/TOP75-arm64" "$build_dir/TOP75-x86_64" \
  -output "$app_dir/Contents/MacOS/TOP75"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
codesign --force --sign "${TOP75_SIGNING_IDENTITY:--}" "$app_dir"
codesign --verify --strict "$app_dir"
"$app_dir/Contents/MacOS/TOP75" --verify

archive="$dist_dir/TOP75-macOS.zip"
temp_archive="$build_dir/TOP75-macOS.zip"
rm -f "$temp_archive"
ditto -c -k --keepParent "$app_dir" "$temp_archive"
mv "$temp_archive" "$archive"
unzip -tq "$archive"
shasum -a 256 "$archive"
