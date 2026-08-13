#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_dir="$project_dir/UsageBar.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$project_dir"
swift build -c "$configuration" --product UsageBar
binary_path=$(swift build -c "$configuration" --show-bin-path)/UsageBar

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp "$binary_path" "$macos_dir/UsageBar"
cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/LICENSE" "$resources_dir/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

plutil -lint "$contents_dir/Info.plist"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
