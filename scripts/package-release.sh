#!/bin/zsh
# Package only a verified Developer ID build. Notarization never exports a key.
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
app="$build_dir/HelloChat.app"
profile="${HELLOCHAT_NOTARY_PROFILE:?Set HELLOCHAT_NOTARY_PROFILE to a notarytool keychain profile}"
tools="${HELLOCHAT_SPARKLE_TOOLS:?Set HELLOCHAT_SPARKLE_TOOLS to the verified Sparkle bin directory}"
account="${HELLOCHAT_SPARKLE_ACCOUNT:-com.ethansk.HelloChat}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ "$version" == <->.<->.<-> ]] || { echo 'Invalid release version' >&2; exit 1; }
[[ "${HELLOCHAT_RELEASE_TAG:-v$version}" == "v$version" ]] || { echo 'Release tag differs from app version' >&2; exit 1; }
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> "$build_dir/signature.txt"
grep -q '^Authority=Developer ID Application:' "$build_dir/signature.txt"
grep -q '^TeamIdentifier=T34G959ZG8$' "$build_dir/signature.txt"
grep -q '^Identifier=com.ethansk.HeyChat$' "$build_dir/signature.txt"
grep -q 'flags=.*runtime' "$build_dir/signature.txt"
[[ "$(lipo -archs "$app/Contents/MacOS/HelloChat")" == arm64 ]]
codesign -d --entitlements :- "$app" > "$build_dir/entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print com.apple.security.device.audio-input' "$build_dir/entitlements.plist")" == true ]]
zip_path="$build_dir/HelloChat-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
xcrun notarytool submit "$zip_path" --keychain-profile "$profile" --wait --output-format json > "$build_dir/notarization.json"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["status"] == "Accepted", "Notarization was not accepted"' "$build_dir/notarization.json"
# Accepted submissions can take a little longer to propagate to the ticket service.
for attempt in {1..6}; do
  if xcrun stapler staple "$app"; then break; fi
  [[ "$attempt" -lt 6 ]] || exit 1
  sleep 15
done
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
# Ship the stapled app, not the pre-notarization archive.
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
# Sign the final stapled bytes, not the earlier notarization submission. Only
# public signatures leave the Keychain; the private signing key is never exported.
public_key=$("$tools/generate_keys" --account "$account" -p)
[[ "$public_key" == "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$app/Contents/Info.plist")" ]]
"$tools/sign_update" --account "$account" -p "$zip_path" > "$build_dir/update-signature.txt"
python3 scripts/create-appcast.py --plist "$app/Contents/Info.plist" --archive "$zip_path" \
  --signature-file "$build_dir/update-signature.txt" \
  --url "https://github.com/EthanSK/hello-chat/releases/download/v$version/HelloChat-macOS-arm64.zip" \
  --output "$build_dir/appcast.xml"
(cd "$build_dir" && shasum -a 256 HelloChat-macOS-arm64.zip appcast.xml > SHA256SUMS)
echo "$zip_path"
