#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_dir="$project_dir/UsageBar.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

cd "$project_dir"
swift build -c "$configuration" --product UsageBar
binary_path=$(swift build -c "$configuration" --show-bin-path)/UsageBar

rm -rf "$app_dir"
mkdir -p "$macos_dir"
cp "$binary_path" "$macos_dir/UsageBar"
cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"

plutil -lint "$contents_dir/Info.plist"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
