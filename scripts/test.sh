#!/bin/zsh
# Compile and run the local regression suites with injected transports, never live Voice calls.
set -euo pipefail
cd "${0:A:h:h}"
speed_sources=(Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/SpotifyVolumeSession.swift Sources/VoiceCallMonitor.swift Sources/Diagnostics.swift Sources/VoicePeerPriority.swift Sources/VoicePeerMailbox.swift Sources/CodexChatSpeed.swift Tests/CodexChatSpeedTests.swift)
build_dir="${HELLOCHAT_BUILD_DIR:-$PWD/.build.noindex}"
mkdir -p "$build_dir"
swiftc -swift-version 5 -parse-as-library Sources/CommandRepetition.swift Tests/CommandRepetitionTests.swift -o "$build_dir/CommandRepetitionTests"
"$build_dir/CommandRepetitionTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpokenCommandJournal.swift Tests/SpokenCommandJournalTests.swift -o "$build_dir/SpokenCommandJournalTests"
"$build_dir/SpokenCommandJournalTests"
swiftc -swift-version 5 -parse-as-library $speed_sources -o "$build_dir/CodexChatSpeedTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -lsqlite3
"$build_dir/CodexChatSpeedTests"
swiftc -swift-version 5 -parse-as-library Sources/AppShortcuts.swift Tests/AppShortcutTests.swift -o "$build_dir/AppShortcutTests" -framework AppIntents
"$build_dir/AppShortcutTests"
swiftc -swift-version 5 -parse-as-library Sources/SettingsNumberBinding.swift Sources/SpotifyVolumeSession.swift Tests/SpotifyVolumeTests.swift -o "$build_dir/SpotifyVolumeTests"
"$build_dir/SpotifyVolumeTests" "$build_dir/SpotifyVolumeChecks.noindex"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/SpotifyVolumePhrase.swift Tests/SpotifyVolumePhraseTests.swift -o "$build_dir/SpotifyVolumePhraseTests"
"$build_dir/SpotifyVolumePhraseTests"
swiftc -swift-version 5 -parse-as-library Sources/SpotifyVolumeSession.swift Sources/VoiceStatusRefresh.swift Tests/VoiceStatusRefreshTests.swift -o "$build_dir/VoiceStatusRefreshTests"
"$build_dir/VoiceStatusRefreshTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/SpotifyVolumeSession.swift Sources/VoiceCallMonitor.swift Tests/VoiceTimelineTests.swift -o "$build_dir/VoiceTimelineTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -lsqlite3
"$build_dir/VoiceTimelineTests" "$build_dir/SpotifyVolumeChecks.noindex/timeline.sqlite"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/SpotifyVolumeSession.swift Sources/VoiceCallMonitor.swift Sources/Diagnostics.swift Sources/VoicePeerPriority.swift Sources/VoicePeerMailbox.swift Sources/ShowVoiceCommand.swift Tests/VoicePeerPriorityTests.swift -o "$build_dir/VoicePeerPriorityTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -lsqlite3
"$build_dir/VoicePeerPriorityTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StartupSpeech.swift Tests/StartupSpeechTests.swift -o "$build_dir/StartupSpeechTests"
"$build_dir/StartupSpeechTests" "$build_dir/StartupSpeechChecks.noindex"
swiftc -swift-version 5 -parse-as-library Sources/SpeechModel.swift Tests/SpeechModelTests.swift -o "$build_dir/SpeechModelTests" -framework AVFoundation
"$build_dir/SpeechModelTests"
swiftc -swift-version 5 -parse-as-library Sources/TranscriptViewport.swift Tests/TranscriptViewportTests.swift -o "$build_dir/TranscriptViewportTests"
"$build_dir/TranscriptViewportTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/AgentFlowRecordingMonitor.swift Tests/AgentFlowRecordingTests.swift -o "$build_dir/AgentFlowRecordingTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/AgentFlowRecordingTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/AppInstanceLock.swift Tests/AppInstanceTests.swift -o "$build_dir/AppInstanceTests"
"$build_dir/AppInstanceTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Tests/CoreTests.swift -o "$build_dir/CoreTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/CoreTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/SpeechPCM.swift Tests/SpeechPCMTests.swift -o "$build_dir/SpeechPCMTests" -framework AVFoundation
"$build_dir/SpeechPCMTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/Diagnostics.swift Sources/SpotifyVolumeSession.swift Sources/VoiceCallMonitor.swift Sources/CodexVoiceSpeed.swift Sources/NativeVoice.swift Tests/NativeVoiceTests.swift -o "$build_dir/NativeVoiceTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -lsqlite3
# Keep the real configuration protocol's diagnostics in the fixture's home.
mkdir -p "$build_dir/native-test-home"
CFFIXED_USER_HOME="${build_dir:A}/native-test-home" "$build_dir/NativeVoiceTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/MicrophoneInputs.swift Sources/MicrophoneCapture.swift Sources/DockMonitor.swift Sources/ResourceUsage.swift Tests/InputPolicyTests.swift -o "$build_dir/InputPolicyTests" -framework AppKit -framework ApplicationServices -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework IOKit
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
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Tests/StandaloneWakeTests.swift -o "$build_dir/StandaloneWakeTests"
"$build_dir/StandaloneWakeTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/StartupSpeech.swift Sources/SpokenCommandJournal.swift Sources/SpeakerOutput.swift Tests/SpeakerOutputTests.swift -o "$build_dir/SpeakerOutputTests"
"$build_dir/SpeakerOutputTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/StartupSpeech.swift Tests/PhraseListTests.swift -o "$build_dir/PhraseListTests"
"$build_dir/PhraseListTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/VideoBridge.swift Tests/VideoBridgeTests.swift -o "$build_dir/VideoBridgeTests" -framework Combine
"$build_dir/VideoBridgeTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/DesktopSession.swift Sources/AppCommands.swift Sources/DesktopCommands.swift Sources/Diagnostics.swift Tests/DesktopCommandTests.swift -o "$build_dir/DesktopCommandTests" -framework AppKit -framework ApplicationServices
"$build_dir/DesktopCommandTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/AppCommands.swift Tests/AppSpellingTests.swift -o "$build_dir/AppSpellingTests"
"$build_dir/AppSpellingTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/StandaloneWake.swift Sources/VideoBridge.swift Sources/AppCommands.swift Sources/Diagnostics.swift Sources/SpotifyVolumeSession.swift Sources/FeedbackSounds.swift Tests/FeedbackSoundTests.swift -o "$build_dir/FeedbackSoundTests" -framework AppKit -framework Combine -framework AVFoundation
"$build_dir/FeedbackSoundTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/PhraseHighlights.swift Tests/PhraseHighlightTests.swift -o "$build_dir/PhraseHighlightTests"
"$build_dir/PhraseHighlightTests"

swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Tests/AppPathsTests.swift -o "$build_dir/AppPathsTests"
"$build_dir/AppPathsTests"
swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Tests/CodexDiscoveryTests.swift -o "$build_dir/CodexDiscoveryTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/CodexDiscoveryTests"
python3 scripts/test-transcript-backup.py
python3 scripts/test-release.py
python3 scripts/test-fetch-speech-models.py
python3 scripts/test-prepare-site.py
swiftc -swift-version 5 -parse-as-library Sources/GateCore.swift Sources/CommandRepetition.swift Sources/UpdateSafety.swift Tests/UpdateSafetyTests.swift -o "$build_dir/UpdateSafetyTests" -framework ApplicationServices
"$build_dir/UpdateSafetyTests"
swiftc -swift-version 5 -parse-as-library Sources/StartupOwnership.swift Tests/StartupOwnershipTests.swift -o "$build_dir/StartupOwnershipTests"
"$build_dir/StartupOwnershipTests"
swiftc -swift-version 5 -parse-as-library Sources/UpdateInstallation.swift Tests/UpdateInstallationTests.swift -o "$build_dir/UpdateInstallationTests"
"$build_dir/UpdateInstallationTests"

swiftc -swift-version 5 -parse-as-library Sources/DesktopSession.swift Tests/DesktopSessionTests.swift -o "$build_dir/DesktopSessionTests" -framework AppKit
"$build_dir/DesktopSessionTests"

swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/PhraseHighlights.swift Sources/HeardTranscript.swift Tests/TranscriptRenderingTests.swift -o "$build_dir/TranscriptRenderingTests" -framework SwiftUI
"$build_dir/TranscriptRenderingTests"

swiftc -swift-version 5 -parse-as-library Sources/AppPaths.swift Sources/GateCore.swift Sources/CommandRepetition.swift Sources/DesktopSession.swift Sources/VoiceBridge.swift Sources/StandaloneWake.swift Sources/PhraseHighlights.swift Tests/PhraseDictionaryTests.swift -o "$build_dir/PhraseDictionaryTests" -framework AppKit -framework ApplicationServices -framework CoreAudio
"$build_dir/PhraseDictionaryTests"

python3 scripts/prepare-command-help.py --check
