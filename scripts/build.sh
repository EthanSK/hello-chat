#!/bin/zsh
# Build a release bundle, allocate its version, embed libraries and sign inside-out. — GPT-6.1 Sol
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
export HELLOCHAT_BUILD_DIR="$build_dir"
app="$build_dir/HelloChat.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build_dir/HelloChat.iconset"
# A native file lock serializes local signed builds and releases itself after a crash.
# CI already owns its release lock and allocation. — GPT-6.1 Sol
if [[ -z "${HELLOCHAT_RELEASE_TAG:-}" && "${HELLOCHAT_RELEASE_LOCKED:-}" != "$PWD" ]]; then
  exec python3 - "${0:A}" "$PWD" <<'PY'
import fcntl, os, subprocess, sys
script, root = sys.argv[1:]
lock_path = subprocess.check_output(['git', 'rev-parse', '--git-path', 'hello-chat-release.lock'], text=True).strip()
with open(lock_path, 'a') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit('Another local release is building; leave its version allocation alone.')
    environment = dict(os.environ, HELLOCHAT_RELEASE_LOCKED=root)
    sys.exit(subprocess.call(['zsh', script], env=environment, pass_fds=(lock.fileno(),)))
PY
fi
# Local signed releases use the shared allocator, and only record a successful
# build as the new source floor. Found and fixed by GPT-6.1 Sol.
local_release=false
if [[ -z "${HELLOCHAT_RELEASE_TAG:-}" ]]; then
  source_commit="$(python3 - <<'PY'
from pathlib import Path
import runpy
verify = runpy.run_path('scripts/prepare-release.py')['verify_local_release_source']
print(verify(Path.cwd(), Path('/Applications/HelloChat.app/Contents/Info.plist')))
PY
)"
  cp Info.plist "$build_dir/SourceInfo.plist"
  local_release=true
fi
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
install -m 644 Resources/VoiceStartup.md "$app/Contents/Resources/VoiceStartup.md"
python3 scripts/prepare-command-help.py
install -m 644 Resources/CommandRepetitionHelp.json "$app/Contents/Resources/CommandRepetitionHelp.json"
rm -f "$app/Contents/Resources/Voice.html"
if [[ -n "${HELLOCHAT_SPEECH_FIXTURES_DIR:-}" ]]; then
  cp "$HELLOCHAT_SPEECH_FIXTURES_DIR/SpeechCheck.wav" "$HELLOCHAT_SPEECH_FIXTURES_DIR/SpeechNegative.wav" "$app/Contents/Resources/"
elif [[ ! -s "$app/Contents/Resources/SpeechCheck.wav" || ! -s "$app/Contents/Resources/SpeechNegative.wav" || ! -f "$app/Contents/Resources/SpeechFixtures.sha256" || "$(cat "$app/Contents/Resources/SpeechFixtures.sha256")" != "$(shasum -a 256 scripts/make-speech-samples.sh | awk '{print $1}')" ]]; then
  zsh scripts/make-speech-samples.sh "$app/Contents/Resources"
fi
mkdir -p "$app/Contents/Resources/Sounds"
cp Resources/Sounds/*.wav "$app/Contents/Resources/Sounds/"
cp Info.plist "$app/Contents/Info.plist"
if $local_release; then
  python3 scripts/prepare-release.py --local --plist "$app/Contents/Info.plist" \
    --installed-plist /Applications/HelloChat.app/Contents/Info.plist \
    --commit "$source_commit" --output "$build_dir/local-release-manifest.json"
else
  [[ "$HELLOCHAT_RELEASE_TAG" == "v$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")" ]] || { echo 'Allocated release tag differs from source version.' >&2; exit 1; }
fi
# Finder localizes the on-disk name through InfoPlist.strings. Derive the
# English display name from the same bundle name used for public releases.
display_name=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$app/Contents/Info.plist")
localized_info="$app/Contents/Resources/en.lproj/InfoPlist.strings"
mkdir -p "${localized_info:h}"
plutil -create xml1 "$localized_info"
plutil -insert CFBundleName -string "$display_name" "$localized_info"
plutil -insert CFBundleDisplayName -string "$display_name" "$localized_info"
python3 scripts/build-app-shortcuts.py "$app" "$build_dir"
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
if $local_release; then
  [[ "$(git rev-parse HEAD)" == "$source_commit" ]] || { echo 'H Chat source changed during compilation. Rebuild before installing.' >&2; exit 1; }
  [[ -z "$(git status --porcelain --untracked-files=normal -- Info.plist Package.swift Package.resolved Sources Resources scripts)" ]] ||
    { echo 'H Chat build inputs changed during compilation. Rebuild before installing.' >&2; exit 1; }
  python3 - Info.plist "$build_dir/SourceInfo.plist" "$app/Contents/Info.plist" <<'PY'
from pathlib import Path
import runpy, sys
runpy.run_path('scripts/prepare-release.py')['record_local_release'](*map(Path, sys.argv[1:]))
PY
fi
echo "$app"
