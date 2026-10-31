#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
mkdir -p "$build_dir"
swiftc -swift-version 5 -parse-as-library Sources/SpeechModel.swift Tests/SpeechModelTests.swift -o "$build_dir/SpeechModelTests" -framework AVFoundation
"$build_dir/SpeechModelTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/AppInstanceLock.swift Tests/AppInstanceTests.swift -o "$build_dir/AppInstanceTests"
"$build_dir/AppInstanceTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/VoiceBridge.swift Tests/CoreTests.swift -o "$build_dir/CoreTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/CoreTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpeechPCM.swift Tests/SpeechPCMTests.swift -o "$build_dir/SpeechPCMTests" -framework AVFoundation
"$build_dir/SpeechPCMTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/VoiceBridge.swift Sources/Diagnostics.swift Sources/NativeVoice.swift Tests/NativeVoiceTests.swift -o "$build_dir/NativeVoiceTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/NativeVoiceTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/VoiceBridge.swift Sources/MicrophoneInputs.swift Sources/MicrophoneCapture.swift Sources/DockMonitor.swift Sources/ResourceUsage.swift Tests/InputPolicyTests.swift -o "$build_dir/InputPolicyTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework IOKit
"$build_dir/InputPolicyTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpeechContinuity.swift Tests/SpeechContinuityTests.swift -o "$build_dir/SpeechContinuityTests"
"$build_dir/SpeechContinuityTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpeechPreparationGate.swift Tests/SpeechPreparationTests.swift -o "$build_dir/SpeechPreparationTests"
"$build_dir/SpeechPreparationTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/Diagnostics.swift Tests/DiagnosticsTests.swift -o "$build_dir/DiagnosticsTests"
"$build_dir/DiagnosticsTests" "$build_dir/DiagnosticChecks.noindex"

swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpeechResampler.swift Tests/SpeechResamplerTests.swift -o "$build_dir/SpeechResamplerTests" -framework AVFoundation
"$build_dir/SpeechResamplerTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/TranscriptArchive.swift Tests/TranscriptArchiveTests.swift -o "$build_dir/TranscriptArchiveTests"
"$build_dir/TranscriptArchiveTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/StandaloneWake.swift Tests/StandaloneWakeTests.swift -o "$build_dir/StandaloneWakeTests"
"$build_dir/StandaloneWakeTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/PhraseHighlights.swift Tests/PhraseHighlightTests.swift -o "$build_dir/PhraseHighlightTests"
"$build_dir/PhraseHighlightTests"

swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Tests/AppPathsTests.swift -o "$build_dir/AppPathsTests"
"$build_dir/AppPathsTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/VoiceBridge.swift Tests/CodexDiscoveryTests.swift -o "$build_dir/CodexDiscoveryTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/CodexDiscoveryTests"
python3 scripts/test-transcript-backup.py
