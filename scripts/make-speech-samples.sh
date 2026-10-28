#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
destination="${1:?Pass the bundle resource directory}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
mkdir -p "$build_dir/SpeechSamples" "$destination"
make_sample() {
  /usr/bin/say -v Daniel -o "$build_dir/SpeechSamples/$1.aiff" "$2"
  /usr/bin/afconvert "$build_dir/SpeechSamples/$1.aiff" "$destination/$1.wav" -f WAVE -d LEF32@48000 -c 1
}
make_sample SpeechCheck 'Hello chat can you help me check local speech recognition, and now I will say bye chat because the test is finished.'
make_sample SpeechNegative 'Hey Janet. This is a local speech recognition test. Please check the weather tomorrow.'

shasum -a 256 "$0" | awk '{print $1}' > "$destination/SpeechFixtures.sha256"
