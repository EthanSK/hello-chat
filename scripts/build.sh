#!/bin/zsh
# Build the app bundle, embed pinned libraries, then sign inside-out.
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
export HELLOCHAT_BUILD_DIR="$build_dir"
app="$build_dir/HelloChat.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_dir/HelloChat.iconset"
swift scripts/make-icon.swift "$build_dir/icons"
for spec in '16 16' '16@2x 32' '32 32' '32@2x 64' '128 128' '128@2x 256' '256 256' '256@2x 512' '512 512' '512@2x 1024'; do
  parts=(${=spec})
  cp "$build_dir/icons/icon-${parts[2]}.png" "$build_dir/HelloChat.iconset/icon_${parts[1]%%@*}x${parts[1]%%@*}${parts[1]#${parts[1]%%@*}}.png"
done
iconutil -c icns "$build_dir/HelloChat.iconset" -o "$app/Contents/Resources/HelloChat.icns"
swift build --scratch-path "$build_dir" --arch arm64 -c release --jobs 3
bin_dir="$(swift build --scratch-path "$build_dir" --arch arm64 -c release --show-bin-path)"
cp "$bin_dir/HelloChat" "$app/Contents/MacOS/HelloChat"
framework=$(python3 - "$build_dir/artifacts" <<'PY'
from pathlib import Path
import sys
matches = list(Path(sys.argv[1]).glob('**/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'))
assert len(matches) == 1, 'Expected one pinned Sparkle framework'
print(matches[0])
PY
)
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$framework" "$app/Contents/Frameworks/Sparkle.framework"
install -m 644 "$build_dir/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
python3 scripts/fetch-speech-models.py --output "$build_dir/models"
mkdir -p "$app/Contents/Resources/LocalSpeech"
cp -R "$build_dir/models/." "$app/Contents/Resources/LocalSpeech/"
# SwiftPM marks some resource files read-only. Replace this owned bundle as a
# unit so a second build works and removed upstream resources cannot linger.
resource_bundle="$app/Contents/Resources/FluidAudio_FluidAudio.bundle"
if [[ -d "$resource_bundle" ]]; then
  chmod -R u+w "$resource_bundle"
  rm -rf "$resource_bundle"
fi
ditto "$bin_dir/FluidAudio_FluidAudio.bundle" "$resource_bundle"
install -m 644 "$build_dir/checkouts/FluidAudio/LICENSE" "$app/Contents/Resources/FluidAudio-LICENSE.txt"
cp Resources/THIRD-PARTY-NOTICES.txt "$app/Contents/Resources/"
rm -f "$app/Contents/Resources/Voice.html"
if [[ -n "${HELLOCHAT_SPEECH_FIXTURES_DIR:-}" ]]; then
  cp "$HELLOCHAT_SPEECH_FIXTURES_DIR/SpeechCheck.wav" "$HELLOCHAT_SPEECH_FIXTURES_DIR/SpeechNegative.wav" "$app/Contents/Resources/"
elif [[ ! -s "$app/Contents/Resources/SpeechCheck.wav" || ! -s "$app/Contents/Resources/SpeechNegative.wav" || ! -f "$app/Contents/Resources/SpeechFixtures.sha256" || "$(cat "$app/Contents/Resources/SpeechFixtures.sha256")" != "$(shasum -a 256 scripts/make-speech-samples.sh | awk '{print $1}')" ]]; then
  zsh scripts/make-speech-samples.sh "$app/Contents/Resources"
fi
mkdir -p "$app/Contents/Resources/Sounds"
cp Resources/Sounds/*.wav "$app/Contents/Resources/Sounds/"
cp Info.plist "$app/Contents/Info.plist"
identity="${HELLOCHAT_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/{print $2; exit}')"
fi
# Keep the original signing identifier so installed users retain privacy grants.
if [[ -n "$identity" ]]; then
  # Nested executables must use the same Developer ID as the host app so
  # hardened runtime library validation can load Sparkle without exceptions.
  for component in "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
      "$app/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --sign "$identity" "$component"
  done
  codesign --force --options runtime --timestamp --sign "$identity" --identifier com.ethansk.HeyChat --entitlements Resources/HelloChat.entitlements "$app"
else
  for component in "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
      "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
      "$app/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign - "$component"
  done
  codesign --force --sign - --identifier com.ethansk.HeyChat --entitlements Resources/HelloChat.entitlements "$app"
fi
codesign --verify --deep --strict "$app"
echo "$app"
