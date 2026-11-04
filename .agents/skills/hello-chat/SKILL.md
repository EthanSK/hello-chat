---
name: hello-chat
description: Implement, diagnose, test, install, or release this repository's native macOS wake-phrase app. Use for H Chat's local recognition, Codex Voice control, keyboard shortcuts, signing, and release artifacts. Does not control unrelated apps or authorize live Voice calls.
---

# H Chat project workflow

## Continuous improvement

Keep useful, verified project lessons in [LEARNINGS.md](../../../LEARNINGS.md). Update this skill when an established workflow changes, preserving user preferences and unrelated behavior. Keep historical incidents in the learnings file, not this operating contract; do not record secrets or private device details in public files.

## Skill usage announcement

Tell the user this project skill is active and why, unless they explicitly request silent use.

## Names and scope

Refer to it as **H Chat** so it doesn't trigger, in discussions and speech. Keep the actual HelloChat product, repository, bundle and UI names unchanged. This is Ethan's requested conversational name, not a product rename.

Read [LEARNINGS.md](../../../LEARNINGS.md) before fragile changes. Inspect the actual source and dirty/staged state before editing; preserve other work. The private preference link, if present beside this skill, is separate from this tracked workflow and is not shipped.

## Build and test

- Build with `zsh scripts/build.sh`; test with `zsh scripts/test.sh`, from the repository root. The canonical scripts are [build.sh](../../../scripts/build.sh) and [test.sh](../../../scripts/test.sh).
- Set `HELLOCHAT_BUILD_DIR` to task-owned `.noindex` scratch. Follow the host's scratch-disk instructions for large outputs. Do not clean or overwrite another task's build.
- Recognition and model assets stay local. Never silently add network transcription, voice identification, or background microphone behavior. Model pinning and downloads belong to [SpeechModels.json](../../../Resources/SpeechModels.json) and [fetch-speech-models.py](../../../scripts/fetch-speech-models.py).
- Use injected transports and recorded fixtures for tests. Never automate real Codex Voice calls as an incidental build/test side effect. Recorded recognition and key-translation checks do not prove physical-microphone or live Voice acceptance.

## Voice and keyboard behavior

- Preserve an active Codex call on normal H Chat Quit: detach local listening/control work without sending End. Explicit spoken/button End remains separate. Inspect [GateModel.swift](../../../Sources/GateModel.swift), [NativeVoice.swift](../../../Sources/NativeVoice.swift), and [NativeVoiceTests.swift](../../../Tests/NativeVoiceTests.swift).
- A wake sound acknowledges detection, not a sent shortcut. Preserve the fresh active-call check, which reuses a live call instead of blindly toggling it.
- [VoiceBridge.swift](../../../Sources/VoiceBridge.swift) owns required shortcut defaults, collision checks, per-send configuration reads and macOS keyboard-layout translation. Preserve custom bindings and unrelated settings. Use the built-in layout API; do not add per-layout tables or change Karabiner/global keyboard settings to fix app delivery.

## Installation and release

- Establish the exact source commit, bundle version and build before handing an artifact to an installer. Coordinate one installation owner; never race copies or change an artifact another task is signing/installing.
- Inspect current Voice and recording state before an authorized restart or replacement. Preserve preferences, startup settings and a recoverable old bundle. Never end a call to make installation possible.
- Retain signing identity `com.ethansk.HeyChat`, its Developer ID team, and the legacy instance lock. [AppPaths.swift](../../../Sources/AppPaths.swift) owns data migration. The microphone entitlement belongs to [HelloChat.entitlements](../../../Resources/HelloChat.entitlements).
- Follow [RELEASE.md](../../../RELEASE.md), [package-release.sh](../../../scripts/package-release.sh) and the [release workflow](../../../.github/workflows/release.yml). Preserve private signing keys; never commit/export them as a workaround. Distinguish a test signature, Developer ID signature, Apple notarisation and an actually published download.
- Do not overwrite a published version tag or asset. Verify the downloadable bytes, checksum, signature and installed version when release-based installation is requested. Report the exact credential or signing blocker if publication cannot complete.
- Keep [README.md](../../../README.md) and `docs/` installation/privacy claims aligned with verified artifacts. After appropriate checks, commit and push in-scope completed changes to the existing `EthanSK/hello-chat` origin, verify the remote commit, and report any failure. Preserve unrelated work.
