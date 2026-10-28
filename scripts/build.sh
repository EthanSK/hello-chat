#!/bin/zsh
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
swift build --scratch-path "$build_dir" -c release --jobs 3
bin_dir="$(swift build --scratch-path "$build_dir" -c release --show-bin-path)"
cp "$bin_dir/HelloChat" "$app/Contents/MacOS/HelloChat"
python3 scripts/fetch-speech-models.py --output "$build_dir/models"
mkdir -p "$app/Contents/Resources/LocalSpeech"
cp -R "$build_dir/models/." "$app/Contents/Resources/LocalSpeech/"
cp -R "$bin_dir/FluidAudio_FluidAudio.bundle" "$app/Contents/Resources/"
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
  codesign --force --options runtime --timestamp --sign "$identity" --identifier com.ethansk.HeyChat "$app"
else
  codesign --force --sign - --identifier com.ethansk.HeyChat "$app"
fi
codesign --verify --deep --strict "$app"
echo "$app"
