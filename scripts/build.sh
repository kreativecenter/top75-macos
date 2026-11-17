#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/release-bundle"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/TOP75.app"
mkdir -p "$build_dir" "$app_dir/Contents/MacOS"

intent_protocols="$build_dir/intent-protocols.json"
intent_sources="$build_dir/intent-sources.txt"
intent_values="$build_dir/intent-values.txt"
printf '%s\n' '["AppIntent", "AppEnum", "AppShortcutsProvider"]' > "$intent_protocols"
printf '%s\n' "$project_dir"/Sources/TOP75/*.swift > "$intent_sources"
printf '%s\n' "$build_dir/TOP75.swiftconstvalues" > "$intent_values"

for architecture in arm64 x86_64; do
  intent_flags=()
  if [[ "$architecture" == arm64 ]]; then
    intent_flags=(
      -whole-module-optimization
      -emit-const-values-path "$build_dir/TOP75.swiftconstvalues"
      -Xfrontend -const-gather-protocols-list -Xfrontend "$intent_protocols"
    )
  fi
  xcrun swiftc -O -swift-version 6 -parse-as-library -module-name TOP75 \
    -target "$architecture-apple-macos14.0" \
    -module-cache-path "$build_dir/cache-$architecture" \
    ${intent_flags[@]+"${intent_flags[@]}"} \
    "$project_dir"/Sources/TOP75/*.swift -o "$build_dir/TOP75-$architecture"
done

xcrun lipo -create "$build_dir/TOP75-arm64" "$build_dir/TOP75-x86_64" \
  -output "$app_dir/Contents/MacOS/TOP75"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources"
xcrun appintentsmetadataprocessor \
  --output "$app_dir/Contents/Resources" \
  --toolchain-dir "$(dirname "$(dirname "$(xcrun --find swiftc)")")" \
  --module-name TOP75 --sdk-root "$(xcrun --show-sdk-path)" \
  --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
  --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
  --source-file-list "$intent_sources" --swift-const-vals-list "$intent_values"
intent_metadata="$app_dir/Contents/Resources/Metadata.appintents/extract.actionsdata"
grep -q '"SelectTOP75Profile"' "$intent_metadata"
grep -q '"SetTOP75Lighting"' "$intent_metadata"
for language in en tr; do
  ditto "$project_dir/Sources/TOP75/Resources/$language.lproj" "$app_dir/Contents/Resources/$language.lproj"
done
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/Sources/TOP75/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
"$app_dir/Contents/MacOS/TOP75" --verify

archive="$dist_dir/TOP75-macOS.zip"
temp_archive="$build_dir/TOP75-macOS.zip"
rm -f "$temp_archive"
ditto -c -k --keepParent "$app_dir" "$temp_archive"
mv "$temp_archive" "$archive"
unzip -tq "$archive"
shasum -a 256 "$archive"
