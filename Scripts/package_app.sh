#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
mode=local
configuration=${CONFIGURATION:-release}
version=${RESERVE_VERSION:-1.0.0}
build_number=${RESERVE_BUILD_NUMBER:-1}
bundle_id=com.pocarles.reserve
product=Reserve
output_dir=${RESERVE_OUTPUT_DIR:-$project_dir}
overwrite=${RESERVE_OVERWRITE:-0}

usage() {
  cat <<'EOF'
Usage: Scripts/package_app.sh [--mode local|dry-run|release]

Modes:
  local     Current-architecture, ad-hoc signed Reserve.app for this Mac.
  dry-run   Universal 2, ad-hoc signed DMG and checksum for CI validation.
  release   Universal 2 Developer ID signed, notarized, stapled release DMG.

Release mode requires:
  RESERVE_SIGN_IDENTITY        Developer ID Application certificate name
  RESERVE_TEAM_ID              10-character Apple Developer Team ID
  APPLE_API_KEY_PATH           path to an App Store Connect API private key
  APPLE_API_KEY_ID             App Store Connect API key ID
  APPLE_API_ISSUER_ID          App Store Connect API issuer UUID
  RESERVE_VERSION              release version without the leading v
  RESERVE_BUILD_NUMBER         positive integer bundle build number
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --mode)
      (( $# >= 2 )) || { echo "error: --mode requires a value" >&2; exit 64; }
      mode=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$mode" in
  local|dry-run|release) ;;
  *) echo "error: unsupported package mode: $mode" >&2; exit 64 ;;
esac

[[ "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' ]] || {
  echo "error: RESERVE_VERSION must be a release version such as 1.0.0" >&2
  exit 64
}
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || {
  echo "error: RESERVE_BUILD_NUMBER must be a positive integer" >&2
  exit 64
}

for command_name in swift plutil codesign ditto; do
  command -v "$command_name" >/dev/null || {
    echo "error: required command is unavailable: $command_name" >&2
    exit 69
  }
done

if [[ "$mode" != local ]]; then
  for command_name in xcodebuild xcrun lipo hdiutil shasum osascript; do
    command -v "$command_name" >/dev/null || {
      echo "error: Universal 2 packaging requires full Xcode and $command_name" >&2
      exit 69
    }
  done
  developer_dir=$(xcode-select -p 2>/dev/null || true)
  # GitHub-hosted runners select versioned bundles such as Xcode_16.4.app;
  # local installations commonly use the unversioned Xcode.app name.
  [[ "$developer_dir" == *.app/Contents/Developer ]] || {
    echo "error: Universal 2 packaging requires full Xcode selected with xcode-select" >&2
    exit 69
  }
fi

sign_identity=${RESERVE_SIGN_IDENTITY:-}
team_id=${RESERVE_TEAM_ID:-}
api_key_path=${APPLE_API_KEY_PATH:-}
api_key_id=${APPLE_API_KEY_ID:-}
api_issuer_id=${APPLE_API_ISSUER_ID:-}

if [[ "$mode" == release ]]; then
  [[ "$sign_identity" == 'Developer ID Application:'* ]] || {
    echo "error: release mode requires a named Developer ID Application identity" >&2
    exit 78
  }
  [[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || {
    echo "error: release mode requires a valid RESERVE_TEAM_ID" >&2
    exit 78
  }
  [[ -n "$api_key_path" && -f "$api_key_path" ]] || {
    echo "error: release mode requires APPLE_API_KEY_PATH" >&2
    exit 78
  }
  [[ -n "$api_key_id" && -n "$api_issuer_id" ]] || {
    echo "error: release mode requires APPLE_API_KEY_ID and APPLE_API_ISSUER_ID" >&2
    exit 78
  }
  available_identities=$(security find-identity -v -p codesigning)
  grep -Fq "\"$sign_identity\"" <<< "$available_identities" || {
    echo "error: requested Developer ID Application identity is not available" >&2
    exit 78
  }
fi

mkdir -p "$output_dir"
if [[ "$mode" != local && "$overwrite" != 1 \
  && ( -e "$output_dir/Reserve.dmg" || -e "$output_dir/Reserve.dmg.sha256" ) ]]; then
  echo "error: release outputs already exist in $output_dir" >&2
  exit 73
fi
temp_root=$(mktemp -d "${TMPDIR:-/tmp}/reserve-package.XXXXXX")
stage_app="$temp_root/Reserve.app"
contents_dir="$stage_app/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
frameworks_dir="$contents_dir/Frameworks"
staged_dmg="$temp_root/Reserve.dmg"
layout_dmg="$temp_root/Reserve-layout.dmg"
staged_checksum="$temp_root/Reserve.dmg.sha256"
completed=0
created_app=0
created_dmg=0
mounted_dmg=0
mount_dir="$temp_root/mounted-dmg"

cleanup() {
  if (( mounted_dmg != 0 )); then
    hdiutil detach -quiet "$mount_dir" 2>/dev/null || true
  fi
  rm -rf "$temp_root"
  if (( completed == 0 )); then
    if (( created_app != 0 )); then
      rm -rf "$output_dir/Reserve.app"
    fi
    if (( created_dmg != 0 )); then
      rm -f "$output_dir/Reserve.dmg" "$output_dir/Reserve.dmg.sha256"
    fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

copy_resource_bundle() {
  local bin_dir=$1
  local bundle="$bin_dir/Reserve_Reserve.bundle"
  if [[ -d "$bundle" ]]; then
    ditto "$bundle" "$resources_dir/${bundle:t}"
  fi
}

copy_sparkle_framework() {
  local bin_dir=$1
  local license_path=$2
  local source_framework="$bin_dir/Sparkle.framework"
  [[ -d "$source_framework" && -f "$license_path" ]] || {
    echo "error: SwiftPM did not provide the complete Sparkle distribution" >&2
    exit 65
  }
  ditto "$source_framework" "$frameworks_dir/Sparkle.framework"
  cp "$license_path" "$resources_dir/Sparkle-LICENSE.txt"
  # Reserve is not sandboxed, so Sparkle's sandbox-only services are unused.
  # Omitting them keeps the menu-bar app and its signing surface smaller.
  rm -rf "$frameworks_dir/Sparkle.framework/Versions/B/XPCServices"
}

smoke_test_packaged_app() {
  local app=$1
  local stdout_log="$temp_root/package-smoke.stdout"
  local stderr_log="$temp_root/package-smoke.stderr"
  local app_pid

  "$app/Contents/MacOS/Reserve" --package-smoke-test -SUEnableAutomaticChecks NO \
    >"$stdout_log" 2>"$stderr_log" &
  app_pid=$!
  for _ in {1..20}; do
    sleep 0.25
    if ! kill -0 "$app_pid" 2>/dev/null; then
      wait "$app_pid" || true
      echo "error: packaged app exited during launch smoke test" >&2
      sed -n '1,120p' "$stderr_log" >&2
      exit 65
    fi
  done
  kill -TERM "$app_pid"
  wait "$app_pid" 2>/dev/null || true
}

cd "$project_dir"
mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"

if [[ "$mode" == local ]]; then
  swift build -c "$configuration" --product "$product"
  bin_dir=$(swift build -c "$configuration" --show-bin-path)
  cp "$bin_dir/$product" "$macos_dir/$product"
  copy_resource_bundle "$bin_dir"
  copy_sparkle_framework "$bin_dir" \
    "$project_dir/.build/artifacts/sparkle/Sparkle/LICENSE"
else
  arm_build="$temp_root/build-arm64"
  intel_build="$temp_root/build-x86_64"
  sdk_path=$(xcrun --sdk macosx --show-sdk-path)

  swift build --scratch-path "$arm_build" -c release \
    --triple arm64-apple-macosx14.0 --sdk "$sdk_path" --product "$product"
  arm_bin_dir=$(swift build --scratch-path "$arm_build" -c release \
    --triple arm64-apple-macosx14.0 --sdk "$sdk_path" --show-bin-path)
  swift build --scratch-path "$intel_build" -c release \
    --triple x86_64-apple-macosx14.0 --sdk "$sdk_path" --product "$product"
  intel_bin_dir=$(swift build --scratch-path "$intel_build" -c release \
    --triple x86_64-apple-macosx14.0 --sdk "$sdk_path" --show-bin-path)

  lipo -create "$arm_bin_dir/$product" "$intel_bin_dir/$product" \
    -output "$macos_dir/$product"
  copy_resource_bundle "$arm_bin_dir"
  copy_sparkle_framework "$arm_bin_dir" \
    "$arm_build/artifacts/sparkle/Sparkle/LICENSE"
  # Keep the compiled-in SwiftPM development fallback paths unavailable for
  # the launch check so it proves the staged app is self-contained.
  mv "$arm_bin_dir/Reserve_Reserve.bundle" "$temp_root/arm64-build-resource-bundle"
  mv "$intel_bin_dir/Reserve_Reserve.bundle" "$temp_root/x86_64-build-resource-bundle"
fi

cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Support/Reserve.icns" "$resources_dir/Reserve.icns"
cp "$project_dir/Support/PrivacyInfo.xcprivacy" "$resources_dir/PrivacyInfo.xcprivacy"
cp "$project_dir/LICENSE" "$resources_dir/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

# Versioning is applied only to the staged bundle. The tracked plist remains a
# stable template and release jobs cannot accidentally dirty the repository.
plutil -replace CFBundleExecutable -string "$product" "$contents_dir/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$contents_dir/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$contents_dir/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$contents_dir/Info.plist"
plutil -lint "$contents_dir/Info.plist"
plutil -lint "$resources_dir/PrivacyInfo.xcprivacy"

# Sign every nested Mach-O before the outer app. SwiftPM's resource bundle has
# no executable today, but this remains correct if a nested helper is added.
sign_nested_code() {
  local identity=$1
  local candidate
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$macos_dir/$product" ]] && continue
    file "$candidate" | grep -q 'Mach-O' || continue
    if [[ "$identity" == - ]]; then
      codesign --force --sign - "$candidate"
    else
      codesign --force --timestamp --options runtime --sign "$identity" "$candidate"
    fi
  done < <(find "$contents_dir" -type f -print0)
}

# Sparkle's executable helpers are nested bundles, so sign them from the
# inside out before signing the framework and finally Reserve.app. `--deep`
# signing is deliberately avoided because these components have distinct
# signing requirements.
sign_sparkle() {
  local identity=$1
  local sparkle="$frameworks_dir/Sparkle.framework"
  local autoupdate="$sparkle/Versions/B/Autoupdate"
  local updater_app="$sparkle/Versions/B/Updater.app"
  [[ -f "$autoupdate" && -d "$updater_app" ]] || {
    echo "error: Sparkle installer helpers are missing" >&2
    exit 65
  }
  if [[ "$identity" == - ]]; then
    codesign --force --sign - "$autoupdate"
    codesign --force --sign - "$updater_app"
    codesign --force --sign - "$sparkle"
  else
    codesign --force --timestamp --options runtime --sign "$identity" "$autoupdate"
    codesign --force --timestamp --options runtime --sign "$identity" "$updater_app"
    codesign --force --timestamp --options runtime --sign "$identity" "$sparkle"
  fi
}

if [[ "$mode" == release ]]; then
  sign_nested_code "$sign_identity"
  sign_sparkle "$sign_identity"
  codesign --force --timestamp --options runtime \
    --entitlements "$project_dir/Support/Reserve.entitlements" \
    --sign "$sign_identity" "$stage_app"
else
  sign_nested_code -
  sign_sparkle -
  codesign --force --sign - "$stage_app"
fi

"$project_dir/Scripts/verify_package.sh" --mode "$mode" \
  --version "$version" --build "$build_number" "$stage_app"

if [[ "$mode" != local ]]; then
  smoke_test_packaged_app "$stage_app"
fi

if [[ "$mode" == local ]]; then
  final_app="$output_dir/Reserve.app"
  rm -rf "$final_app"
  ditto "$stage_app" "$final_app"
  created_app=1
  "$project_dir/Scripts/verify_package.sh" --mode local \
    --version "$version" --build "$build_number" "$final_app"
  completed=1
  echo "$final_app"
  exit 0
fi

dmg_root="$temp_root/dmg-root"
mkdir -p "$dmg_root"
ditto "$stage_app" "$dmg_root/Reserve.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -quiet -volname Reserve -srcfolder "$dmg_root" \
  -format UDRW "$layout_dmg"
mkdir -p "$mount_dir"
hdiutil attach -quiet -nobrowse -readwrite -mountpoint "$mount_dir" "$layout_dmg"
mounted_dmg=1

# The install gesture should read naturally from left to right: drag Reserve
# onto Applications. Finder stores icon positions in the volume's .DS_Store,
# so arrange a writable image first and only then compress the finished image.
/usr/bin/osascript - "$mount_dir" <<'APPLESCRIPT'
on run argv
  set targetFolder to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    activate
    open targetFolder
    delay 1
    set current view of front Finder window to icon view
    set toolbar visible of front Finder window to false
    set statusbar visible of front Finder window to false
    set bounds of front Finder window to {100, 100, 660, 430}
    tell icon view options of front Finder window
      set arrangement to not arranged
      set icon size to 96
      set text size to 13
    end tell
    set position of item "Reserve.app" of targetFolder to {150, 150}
    set position of item "Applications" of targetFolder to {410, 150}
    update targetFolder without registering applications
    delay 2
    close front Finder window
    delay 1
  end tell
end run
APPLESCRIPT
[[ -f "$mount_dir/.DS_Store" ]] || {
  echo "error: Finder did not save the DMG layout" >&2
  exit 65
}
hdiutil detach -quiet "$mount_dir"
mounted_dmg=0
hdiutil convert -quiet "$layout_dmg" -format UDZO -o "$staged_dmg"

if [[ "$mode" == release ]]; then
  codesign --force --timestamp --sign "$sign_identity" "$staged_dmg"
  codesign --verify --strict --verbose=2 "$staged_dmg"
  xcrun notarytool submit "$staged_dmg" \
    --key "$api_key_path" \
    --key-id "$api_key_id" \
    --issuer "$api_issuer_id" \
    --wait
  xcrun stapler staple "$staged_dmg"
  xcrun stapler validate "$staged_dmg"
  spctl --assess --type open --context context:primary-signature \
    --verbose=2 "$staged_dmg"
fi

hash=$(shasum -a 256 "$staged_dmg" | awk '{print $1}')
printf '%s  Reserve.dmg\n' "$hash" > "$staged_checksum"

final_dmg="$output_dir/Reserve.dmg"
final_checksum="$output_dir/Reserve.dmg.sha256"
if [[ -e "$final_dmg" || -e "$final_checksum" ]]; then
  [[ "$overwrite" == 1 ]] || {
    echo "error: release outputs already exist in $output_dir" >&2
    exit 73
  }
  rm -f "$final_dmg" "$final_checksum"
fi
mv "$staged_dmg" "$final_dmg"
created_dmg=1
mv "$staged_checksum" "$final_checksum"

(cd "$output_dir" && shasum -a 256 -c Reserve.dmg.sha256)
if [[ "$mode" == release ]]; then
  codesign --verify --strict --verbose=2 "$final_dmg"
  xcrun stapler validate "$final_dmg"
  spctl --assess --type open --context context:primary-signature \
    --verbose=2 "$final_dmg"
fi

mkdir -p "$mount_dir"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount_dir" "$final_dmg"
mounted_dmg=1
[[ -d "$mount_dir/Reserve.app" && -L "$mount_dir/Applications" \
  && "$(readlink "$mount_dir/Applications")" == /Applications ]] || {
  echo "error: DMG is missing Reserve or its Applications shortcut" >&2
  exit 65
}
layout_positions=$(/usr/bin/osascript - "$mount_dir" <<'APPLESCRIPT'
on run argv
  set targetFolder to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    return ((position of item "Reserve.app" of targetFolder as text) & "|" & (position of item "Applications" of targetFolder as text))
  end tell
end run
APPLESCRIPT
)
[[ "$layout_positions" == "150150|410150" ]] || {
  echo "error: DMG icons are not arranged as Reserve then Applications" >&2
  exit 65
}
if [[ "$mode" == release ]]; then
  "$project_dir/Scripts/verify_package.sh" --mode release \
    --version "$version" --build "$build_number" "$mount_dir/Reserve.app"
  spctl --assess --type execute --verbose=2 "$mount_dir/Reserve.app"
fi
hdiutil detach -quiet "$mount_dir"
mounted_dmg=0

completed=1
printf '%s\n%s\n' "$final_dmg" "$final_checksum"
