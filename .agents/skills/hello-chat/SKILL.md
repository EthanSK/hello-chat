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
- Use injected transports and recorded fixtures for tests. Never automate real Codex Voice calls in tests. Recorded recognition and key-translation checks do not prove physical-microphone or live Voice acceptance.

## Voice and keyboard behavior

- Preserve an active Codex call on normal H Chat Quit: detach local listening/control work without sending End. Explicit spoken/button End remains separate. Inspect [GateModel.swift](../../../Sources/GateModel.swift), [NativeVoice.swift](../../../Sources/NativeVoice.swift), and [NativeVoiceTests.swift](../../../Tests/NativeVoiceTests.swift).
- User-requested — 2026-11-05: “just because I'm on a call” does not mean H Chat should be blocked from being closed and restarted. Build, install and restart H Chat when needed during a Codex Voice call; preserve the call and Agent Flow recording themselves. Do not ask Ethan to end them or treat their microphone activity as an update blocker. Finish H Chat's own in-flight operations and flush its files before replacement. Wake and end phrases also stay enabled while Agent Flow records.
- Default missing Voice chat hotkey to Command+Control+Shift+V and dedicated End to Ctrl+Alt+Shift+V. Preserve existing custom values and report collisions without overriding another command. Leave Toggle reset/custom values untouched.
- If Codex is closed, launch the installed app by its verified bundle identity, wait for actual window readiness, and send Start once. Use injected launch/readiness tests; never create live calls in an automated check.
- A wake sound acknowledges detection, not a sent shortcut. Preserve the fresh active-call check, which reuses a live call instead of blindly toggling it.
- Startup speech uses the private file mailbox and app-owned [Voice startup contract](../../../Resources/VoiceStartup.md), consumed by the local Voice skill. Normal app startup installs that exact contract as `hello-chat-voice-startup` in Codex's skills directory. Preserve app-ownership receipts and user edits when updating the skill, plus read-once speech receipts, partial-revision replacement and End cancellation. Do not restore composer navigation, paste, or Return delivery. Global Start needs no helper activation of Codex; End/unmute keep their existing app-scoped controls.
- [VoiceBridge.swift](../../../Sources/VoiceBridge.swift) owns required shortcut defaults, collision checks, per-send configuration reads and key delivery. Preserve custom bindings and unrelated settings. Do not change keyboard-layout handling or Karabiner/global keyboard settings without current authorization; first verify the actual delivered action.

## Shortcut diagnosis and explanations

- Before explaining or testing a shortcut, distinguish `realtimeVoice` (the desired **Voice chat hotkey**, system-wide Start), `composer.startVoiceMode` (**Toggle voice chat**, never configured or emitted by H Chat), and `realtimeVoice.endCall` (dedicated End). Do not treat Start, End and Toggle as interchangeable because of a displayed label.
- Inspect this machine's configured binding and the installed app's command registry/defaults, then resolve the active keyboard layout and modifiers. Compare the main and bedside Macs separately; a working binding on one does not prove the other uses it.
- Resolve character keys against the active native layout, retaining the full saved modifiers and matching Codex’s base-key registration; function/navigation keys keep their fixed key codes. This reads the current layout, never changes macOS keyboard settings.
- Preserve valid user-selected key combinations, including punctuation, aliases and complete modifier sets. `Ctrl+Shift+` followed by a backtick is one grave key plus two modifiers. Do not replace it or suggest a bare F17. Keep unsupported-key errors specific without inventing a new user preference.
- A keybinding file write skips Codex’s live apply routine. Keep own writes made during a running process marked pending until a new process can load them; show a restart message. Never claim registration or Voice acceptance from file readback alone. A successful End may outlive stale controls, so an expired confirmation is unknown, not proof of failure.
- Separate the configured/intended command, the physical key event actually delivered, and the observed app result. A documented default, wake sound, or emitted event does not prove Codex received or accepted the action. State uncertainty until the result is observed; do not describe a default Start binding as invalid merely because delivery failed.

## Installation and release

- Establish the exact source commit, bundle version and build before handing an artifact to an installer. Coordinate one installation owner; never race copies or change an artifact another task is signing/installing.
- Before an authorized restart or replacement, preserve preferences, startup settings and a recoverable old bundle. H Chat's normal detach/flush cleanup preserves external Voice and recording sessions; never end them to make installation possible.
- Retain signing identity `com.ethansk.HeyChat`, its Developer ID team, and the legacy instance lock. [AppPaths.swift](../../../Sources/AppPaths.swift) owns data migration. The microphone entitlement belongs to [HelloChat.entitlements](../../../Resources/HelloChat.entitlements).
- Follow [RELEASE.md](../../../RELEASE.md), [package-release.sh](../../../scripts/package-release.sh) and the [release workflow](../../../.github/workflows/release.yml). Preserve private signing keys; never commit/export them as a workaround. Distinguish a test signature, Developer ID signature, Apple notarisation and an actually published download.
- Do not overwrite a published version tag or asset. Verify the downloadable bytes, checksum, signature and installed version when release-based installation is requested. Report the exact credential or signing blocker if publication cannot complete.
- Keep [README.md](../../../README.md) and `docs/` installation/privacy claims aligned with verified artifacts. After appropriate checks, commit and push in-scope completed changes to the existing `EthanSK/hello-chat` origin, verify the remote commit, and report any failure. Preserve unrelated work.
