#!/bin/zsh
set -euo pipefail

mode=local
expected_version=1.0.0
expected_build=1

usage() {
  echo "Usage: Scripts/verify_package.sh [--mode local|dry-run|release] [--version X.Y.Z] [--build N] Reserve.app" >&2
}

while (( $# > 0 )); do
  case "$1" in
    --mode) mode=${2:?}; shift 2 ;;
    --version) expected_version=${2:?}; shift 2 ;;
    --build) expected_build=${2:?}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "error: unknown argument: $1" >&2; usage; exit 64 ;;
    *) break ;;
  esac
done

(( $# == 1 )) || { usage; exit 64; }
app=$1
[[ "$mode" == local || "$mode" == dry-run || "$mode" == release ]] || {
  echo "error: invalid verification mode: $mode" >&2
  exit 64
}
[[ -d "$app" ]] || { echo "error: app bundle not found: $app" >&2; exit 66; }

plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/Reserve"
privacy="$app/Contents/Resources/PrivacyInfo.xcprivacy"
provider_logos="$app/Contents/Resources/Reserve_Reserve.bundle/ProviderLogos"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -f "$plist" && -x "$binary" && -f "$privacy" \
  && -d "$sparkle" && -x "$sparkle/Versions/B/Autoupdate" \
  && -d "$sparkle/Versions/B/Updater.app" \
  && -f "$app/Contents/Resources/Sparkle-LICENSE.txt" \
  && -f "$provider_logos/openAI.svg" \
  && -f "$provider_logos/anthropic.svg" \
  && -f "$provider_logos/grok.svg" \
  && -f "$provider_logos/cursor.svg" ]] || {
  echo "error: package is missing required app files" >&2
  exit 65
}

expect_equal() {
  local label=$1
  local actual=$2
  local expected=$3
  [[ "$actual" == "$expected" ]] || {
    echo "error: $label is '$actual', expected '$expected'" >&2
    exit 65
  }
}

plutil -lint "$plist" "$privacy"
otool -L "$binary" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
expect_equal CFBundleExecutable \
  "$(plutil -extract CFBundleExecutable raw "$plist")" Reserve
expect_equal CFBundleIdentifier \
  "$(plutil -extract CFBundleIdentifier raw "$plist")" com.pocarles.reserve
expect_equal CFBundleShortVersionString \
  "$(plutil -extract CFBundleShortVersionString raw "$plist")" "$expected_version"
expect_equal CFBundleVersion \
  "$(plutil -extract CFBundleVersion raw "$plist")" "$expected_build"
expect_equal LSMinimumSystemVersion \
  "$(plutil -extract LSMinimumSystemVersion raw "$plist")" 14.0
expect_equal SUFeedURL \
  "$(plutil -extract SUFeedURL raw "$plist")" \
  "https://github.com/pocarles/reserve/releases/latest/download/appcast.xml"
expect_equal SUPublicEDKey \
  "$(plutil -extract SUPublicEDKey raw "$plist")" \
  "u5A0oU1W4GI181ZhpdgiHp67L3accNISf8oJD9kNMbk="
expect_equal SUScheduledCheckInterval \
  "$(plutil -extract SUScheduledCheckInterval raw "$plist")" 86400
expect_equal SUAllowsAutomaticUpdates \
  "$(plutil -extract SUAllowsAutomaticUpdates raw "$plist")" false
expect_equal SUAutomaticallyUpdate \
  "$(plutil -extract SUAutomaticallyUpdate raw "$plist")" false
expect_equal SUEnableAutomaticChecks \
  "$(plutil -extract SUEnableAutomaticChecks raw "$plist")" true
expect_equal SUSendProfileInfo \
  "$(plutil -extract SUSendProfileInfo raw "$plist")" false
expect_equal SUVerifyUpdateBeforeExtraction \
  "$(plutil -extract SUVerifyUpdateBeforeExtraction raw "$plist")" true
[[ ! -e "$sparkle/Versions/B/XPCServices" ]] || {
  echo "error: unused Sparkle XPC services were bundled" >&2
  exit 65
}

codesign --verify --deep --strict --verbose=2 "$app"

if [[ "$mode" != local ]]; then
  archs=" $(lipo -archs "$binary") "
  [[ "$archs" == *' arm64 '* && "$archs" == *' x86_64 '* ]] || {
    echo "error: Reserve is not Universal 2 (found:${archs})" >&2
    exit 65
  }
  sparkle_archs=" $(lipo -archs "$sparkle/Versions/B/Sparkle") "
  [[ "$sparkle_archs" == *' arm64 '* && "$sparkle_archs" == *' x86_64 '* ]] || {
    echo "error: Sparkle is not Universal 2 (found:${sparkle_archs})" >&2
    exit 65
  }
fi

if [[ "$mode" == release ]]; then
  details=$(codesign -d --verbose=4 "$app" 2>&1)
  grep -Eq '^Authority=Developer ID Application:' <<< "$details"
  grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$details"
  grep -Eq 'flags=.*runtime' <<< "$details"
  actual_team_id=$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$details")
  [[ -n "${RESERVE_TEAM_ID:-}" && "$actual_team_id" == "$RESERVE_TEAM_ID" ]] || {
    echo "error: signed TeamIdentifier does not match RESERVE_TEAM_ID" >&2
    exit 65
  }
  sparkle_details=$(codesign -d --verbose=4 "$sparkle" 2>&1)
  sparkle_team_id=$(awk -F= '/^TeamIdentifier=/{print $2}' <<< "$sparkle_details")
  [[ "$sparkle_team_id" == "$RESERVE_TEAM_ID" ]] || {
    echo "error: Sparkle TeamIdentifier does not match RESERVE_TEAM_ID" >&2
    exit 65
  }
fi

echo "verified $mode package: $app"
