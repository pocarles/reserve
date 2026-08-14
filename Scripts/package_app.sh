#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${CONFIGURATION:-release}
app_dir="$project_dir/Reserve.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

cd "$project_dir"
swift build -c "$configuration" --product UsageBar
binary_path=$(swift build -c "$configuration" --show-bin-path)/UsageBar
resource_bundle=$(swift build -c "$configuration" --show-bin-path)/UsageBar_UsageBar.bundle

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"
cp "$binary_path" "$macos_dir/UsageBar"
if [[ -d "$resource_bundle" ]]; then
  cp -R "$resource_bundle" "$resources_dir/"
fi
cp "$project_dir/Support/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Support/Reserve.icns" "$resources_dir/Reserve.icns"
cp "$project_dir/LICENSE" "$resources_dir/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/THIRD_PARTY_NOTICES.md"

cp "$project_dir/Support/PrivacyInfo.xcprivacy" "$resources_dir/PrivacyInfo.xcprivacy"

plutil -lint "$contents_dir/Info.plist"
plutil -lint "$resources_dir/PrivacyInfo.xcprivacy"

# Signing.
#
# RESERVE_SIGN_IDENTITY selects a Developer ID Application certificate. Without
# it the bundle is ad-hoc signed, which is fine for running the app on this Mac
# and useless for distributing it: Gatekeeper refuses an ad-hoc bundle on any
# other machine, and an ad-hoc binary has no hardened runtime, so it can be
# injected into with DYLD_INSERT_LIBRARIES.
#
# `--deep` is deliberately not used. Apple treats it as an anti-pattern because
# it re-signs nested code with the outer options; the inner bundle is signed
# first, then the app.
sign_identity=${RESERVE_SIGN_IDENTITY:-}
entitlements="$project_dir/Support/Reserve.entitlements"

# A SwiftPM resource bundle carries no Mach-O, so it is not separately
# signable; the app's own signature seals it as a resource. Only nested code
# with an executable is signed, and it is signed before the outer bundle.
sign_nested() {
  local identity_args=("$@")
  for nested in "$resources_dir"/*.bundle(N); do
    if [[ -d "$nested/Contents/MacOS" ]]; then
      codesign "${identity_args[@]}" "$nested"
    fi
  done
}

if [[ -n "$sign_identity" ]]; then
  sign_nested --force --timestamp --options runtime --sign "$sign_identity"
  codesign --force --timestamp --options runtime \
    --entitlements "$entitlements" \
    --sign "$sign_identity" "$app_dir"
  codesign --verify --strict --verbose=2 "$app_dir"

  if [[ -n "${RESERVE_NOTARY_PROFILE:-}" ]]; then
    ditto -c -k --keepParent "$app_dir" "$project_dir/Reserve.zip"
    xcrun notarytool submit "$project_dir/Reserve.zip" \
      --keychain-profile "$RESERVE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    rm -f "$project_dir/Reserve.zip"
  else
    echo "warning: signed but NOT notarized (set RESERVE_NOTARY_PROFILE)." >&2
    echo "         Gatekeeper will still warn on other Macs." >&2
  fi
else
  sign_nested --force --sign -
  codesign --force --sign - "$app_dir"
  echo "warning: ad-hoc signed — for local use only." >&2
  echo "         Do not distribute this bundle. Set RESERVE_SIGN_IDENTITY to a" >&2
  echo "         Developer ID Application identity, and RESERVE_NOTARY_PROFILE" >&2
  echo "         to a notarytool keychain profile, to build a releasable app." >&2
fi

echo "$app_dir"
