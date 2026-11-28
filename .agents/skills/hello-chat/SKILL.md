---
name: hello-chat
description: Implement, diagnose, test, install, or release this repository's native macOS wake-phrase app. Use for H Chat's local recognition, Codex Voice control, keyboard shortcuts, signing, and release artifacts. Does not control unrelated apps or authorize live Voice calls.
---

# H Chat project workflow

## Continuous improvement

Keep useful, verified project lessons in [LEARNINGS.md](../../../LEARNINGS.md). Update this skill when an established workflow changes, preserving user preferences and unrelated behavior. Keep historical incidents in the learnings file, not this operating contract; do not record secrets or private device details in public files. Mark agent-initiated guidance with a dated Self-improved note and verified reason; distinguish explicit user preferences.

## Skill usage announcement

Tell the user this project skill is active and why, unless they explicitly request silent use.

Private preference evidence: [user-preferences.md](user-preferences.md); read only when an unsettled decision needs its history.

## Names and scope

Refer to the helper as **H Chat** so it doesn't trigger, in discussions and speech. Refer to its End command as **B Chat**. Ethan wants to discuss these safely without accidentally starting or ending Voice. Never say or quote the actual spoken End phrase or its former unsafe alias in voice-facing output, including speech reminders. Keep actual internal identifiers and configured phrases where implementation requires them; this is conversational naming, not a product rename. B Chat is not a new trigger. User-requested — 2026-11-08.

The shared matcher excludes the former unsafe alias and B/Be/Bee discussion spellings. End detection uses the same direct-address, mention, negation, timing and occurrence rules as the other commands. Test genuine End acceptance with injected/recorded inputs; never say the trigger aloud or end a live call just to test it.

Read [LEARNINGS.md](../../../LEARNINGS.md) before fragile changes. Inspect the actual source and dirty/staged state before editing; preserve other work. The private preference link, if present beside this skill, is separate from this tracked workflow and is not shipped.

## Build and test

- Build with `zsh scripts/build.sh`; test with `zsh scripts/test.sh`, from the repository root. The canonical scripts are [build.sh](../../../scripts/build.sh) and [test.sh](../../../scripts/test.sh).
- Set `HELLOCHAT_BUILD_DIR` to task-owned `.noindex` scratch. Follow the host's scratch-disk instructions for large outputs. Do not clean or overwrite another task's build.
- Recognition and model assets stay local. Never silently add network transcription, voice identification, or background microphone behavior. Model pinning and downloads belong to [SpeechModels.json](../../../Resources/SpeechModels.json) and [fetch-speech-models.py](../../../scripts/fetch-speech-models.py).
- Use injected transports and recorded fixtures for tests. Never automate real Codex Voice calls in tests. Recorded recognition and key-translation checks do not prove physical-microphone or live Voice acceptance.

## Home and settings design


- Ethan wants “a settings cog icon button where you can configure each one” and an info icon beside each Home title. Keep one Home entry per distinct command. Combine interchangeable app prefixes and the single configurable rewind action. Keep directional commands distinct. Use Codex Voice in brackets for call controls and make Mac output selection distinguishable.
- Put what H Chat heard under **Live transcription** and the most recent command outcome directly below it, with access to command history. A highlighted phrase means it was heard. Show “sent”, confirmed effects, failures and uncertain results accurately.
- Keep one editable home for each setting. Show the current value once. Use a custom number for an amount like rewind seconds. Do not make the user add a phrase to choose a duration. Keep existing custom phrases, spellings, sounds and explicit distances when simplifying.
- Hide a Home phrase caption when its only text repeats the command title. Keep custom phrases, multiple alternatives, empty states and speaker destinations visible. Use the same spelling-count control below each phrase, including speaker prefixes.
- Count the same alternate spellings the editor shows. Keep the main phrase separate from its alternatives. Remove duplicate lists, floating labels and instructions that repeat the controls. Use simple language for microphone scope, device availability and real loading.
- Give each command its own gear and sound control. Use a consistent way to finish editing. If a group of fields must be validated together, let the user safely discard an unfinished edit. Keep long menus scrollable when the pointer is over a control.
- For a full UI pass, audit Home, every gear, individual phrase and spelling editors, speaker names and destinations, app spellings, effects, Settings, diagnostics and the menu-bar menu. Capture and inspect the actual rendered screens with representative saved values, including scrolled content. Exercise loading, editing and scrolling with live transcription updates. Identify any surfaces or physical interactions still unverified.
- Work with Opus before settling taste decisions for this project, using Ethan’s existing subscription. Treat his questions about a visible inconsistency as requests to fix it when inspection confirms a problem.
- Floating notification-reply feedback must not obstruct the user’s work. Ethan wants to “drag this around to get out of the way”. Keep a movable header, preserve placement through updates, provide immediate cancellation, and keep the complete reference compact and scrollable. Stream the reply words from the existing shared capture so he can see what is being picked up; short content should fit its actual size. Display-only checks must be finite, confined to the task display, and clear every owned panel on close or expiry. User-requested — 2026-11-24.

- Every command should support a trailing repeat count by default through the shared reservation/scheduler path, including future actions. Keep the default-on checkbox and explanatory tooltip in each command’s settings. Preserve explicit numeric arguments, one execution without a count, action-time checks, one utterance receipt and revised-transcript totals. Never turn one repeated request into competing fallback actions. User-requested — 2026-11-23.

## Voice and keyboard behavior

- Preserve the user’s saved Spotify maximum rather than resetting it to a factory value. Keep prior-volume restoration, already-quieter volume and manual adjustments. The implementation and UI share the policy in [SpotifyVolumeSession.swift](../../../Sources/SpotifyVolumeSession.swift); private preference history records personal values. User-requested — 2026-11-07; corrected 2026-11-22.

- Preserve an active Codex call on normal H Chat Quit: detach local listening/control work without sending End. Explicit spoken/button End remains separate. Inspect [GateModel.swift](../../../Sources/GateModel.swift), [NativeVoice.swift](../../../Sources/NativeVoice.swift), and [NativeVoiceTests.swift](../../../Tests/NativeVoiceTests.swift).
- User-requested — 2026-11-05: “just because I'm on a call” does not mean H Chat should be blocked from being closed and restarted. Build, install and restart H Chat when needed during a Codex Voice call; preserve the call and Agent Flow recording themselves. Do not ask Ethan to end them or treat their microphone activity as an update blocker. Finish H Chat's own in-flight operations and flush its files before replacement. Wake and end phrases also stay enabled while Agent Flow records.
- Default missing Voice chat hotkey to Command+Control+Shift+V and dedicated End to Ctrl+Alt+Shift+V. Preserve existing custom values and report collisions without overriding another command. Leave Toggle reset/custom values untouched.
- If Codex is closed, launch the installed app by its verified bundle identity, wait for actual window readiness, and send Start once. Use injected launch/readiness tests; never create live calls in an automated check.
- A wake sound acknowledges detection, not a sent shortcut. Preserve the fresh active-call check, which reuses a live call instead of blindly toggling it.
- User-requested — 2026-11-13, clarified 2026-11-15: every phrase, current and future, needs its own short, non-speech sound so Ethan can learn commands by ear. These sounds can be playful and quite different from the original chimes. When adding a phrase slot, give it a cue in the exhaustive `PhraseSlot.cue` in [FeedbackSounds.swift](../../../Sources/FeedbackSounds.swift). Generate its asset with [make-feedback-sounds.py](../../../scripts/make-feedback-sounds.py), and keep the existing chimes byte-identical. Play each cue once at that command's real boundary: detection for Wake/End, confirmed state for video, and accepted dispatch for explicit audio/app/zoom. A confirmed call End from Codex itself also gets one End cue, using the existing call observer and deduplicating the spoken/button cue. Keep cue gain separate from system volume and routing. Never use a cue as proof of the effect or human audibility. Ignored, unresolved, blocked and cancelled commands stay silent.
- User-requested — 2026-11-14:
  - Switch app and Open app are interchangeable launch-or-activate commands.
  - Every phrase section can list extra phrases, added with + rows or "a / b" slash entry.
  - Keep one store: main phrase keys plus `phraseAliases`, resolved by `PhraseConfiguration` in [GateCore.swift](../../../Sources/GateCore.swift).
  - Detection, highlighting, cancellation and startup capture all read that store. Don't add a second phrase store or let a new row take over another command's phrase.
- Startup speech uses the private file mailbox and app-owned [Voice startup contract](../../../Resources/VoiceStartup.md), consumed by the local Voice skill. Normal app startup installs that exact contract as `hello-chat-voice-startup` in Codex's skills directory. Preserve app-ownership receipts and user edits when updating the skill, plus read-once speech receipts, partial-revision replacement and End cancellation. Do not restore composer navigation, paste, or Return delivery. Global Start, explicit microphone commands and existing-call unmute need no helper activation of Codex; End keeps its existing app-scoped controls.
- User-requested — 2026-11-24: explicit microphone mute/unmute and speaker silence/restore commands each send the configured native toggle once. Do not read Voice controls, recover focus, wait for state confirmation or send retry toggles for these commands. Report the shortcut as sent, with its actual audio effect unverified. Keep command occurrence/repeat ownership, desktop availability, process identity and native shortcut configuration checks. This replaces the 13 November read-first speaker policy; Start, End and call observation keep their existing behavior.
- Native Voice opening is not recognition completion. Keep collecting the opening through its recognition utterance end or the startup-only post-open pause/limit in `StartupSpeechBuffer`; never end it at connection alone or at a recognizer context reset. A `capturing` read may return a labelled provisional snapshot to its owning coordinator, but never consume a `capturing` mailbox merely because its text is nonempty. Don't solve startup timing by changing the global quiet threshold. Do not claim this capture fix supplies the conversational model's first reply without a verified connection to that live session.
- User-requested — 2026-11-08: microphone mute/unmute should send the keyboard shortcut, like the other commands. Keep microphone input and Voice audio output on separate native commands, preserve valid custom bindings, and check collisions before assigning missing ones. A saved JSON binding is not proof of live application.
- [VoiceBridge.swift](../../../Sources/VoiceBridge.swift) owns required shortcut defaults, collision checks, per-send configuration reads and key delivery. Preserve custom bindings and unrelated settings. Do not change keyboard-layout handling or Karabiner/global keyboard settings without current authorization; first verify the actual delivered action.

## Shortcut diagnosis and explanations

- Before explaining or testing a shortcut, distinguish `realtimeVoice` (the desired **Voice chat hotkey**, system-wide Start), `composer.startVoiceMode` (**Toggle voice chat**, never configured or emitted by H Chat), and `realtimeVoice.endCall` (dedicated End). Do not treat Start, End and Toggle as interchangeable because of a displayed label.
- Inspect this machine's configured binding and the installed app's command registry/defaults, then resolve the active keyboard layout and modifiers. Compare the main and bedside Macs separately; a working binding on one does not prove the other uses it.
- Resolve character keys against the active native layout, retaining the full saved modifiers and matching Codex’s base-key registration; function/navigation keys keep their fixed key codes. This reads the current layout, never changes macOS keyboard settings.
- Preserve valid user-selected key combinations, including punctuation, aliases and complete modifier sets. `Ctrl+Shift+` followed by a backtick is one grave key plus two modifiers. Do not replace it or suggest a bare F17. Keep unsupported-key errors specific without inventing a new user preference.
- A keybinding file write skips Codex’s live apply routine. Keep own writes made during a running process marked pending until a new process can load them; show a restart message. Never claim registration or Voice acceptance from file readback alone. A successful End may outlive stale controls, so an expired confirmation is unknown, not proof of failure.
- Separate the configured/intended command, the physical key event actually delivered, and the observed app result. A documented default, wake sound, or emitted event does not prove Codex received or accepted the action. State uncertainty until the result is observed; do not describe a default Start binding as invalid merely because delivery failed.

## Installation and release

- User-requested — 2026-11-28: Before making any H Chat changes, check for updates from another machine. Fetch Git and check the relevant peer checkout and its owner for unpublished work. Pull the latest `origin/main` with `--ff-only` when possible. If the histories diverge, reconcile them through the existing `development-workflow/references/worktrees.md` Git procedure before editing. Preserve both Macs’ work and each Mac’s settings. Install and verify the signed local build first, then push the common source and its build floor so GitHub Actions can publish the update. Verify the running build’s source separately using [RELEASE.md](../../../RELEASE.md).

- User-corrected — 2026-11-14: for Ethan’s authorized local updates, follow the shared `development-workflow/references/local-installation.md` local-first rule. Review and build a viable local batch, preserve the existing Developer ID identity, entitlements and updater trust, then install it through H Chat’s safe detach/flush path. Full tests, Apple notarisation, public release and download verification follow local use unless a specific demonstrated platform restriction requires otherwise. `RELEASE.md` owns public qualification, not a blanket gate before local installation. Do not use an ad-hoc replacement or end an external Voice call to hurry an update.

- Establish the exact source commit, bundle version and build before handing an artifact to an installer. Coordinate one installation owner; never race copies or change an artifact another task is signing/installing.
- Before an authorized restart or replacement, preserve preferences, startup settings and a recoverable old bundle. H Chat's normal detach/flush cleanup preserves external Voice and recording sessions; never end them to make installation possible.
- Retain signing identity `com.ethansk.HeyChat`, its Developer ID team, and the legacy instance lock. [AppPaths.swift](../../../Sources/AppPaths.swift) owns data migration. The microphone entitlement belongs to [HelloChat.entitlements](../../../Resources/HelloChat.entitlements).
- After installed-runtime qualification, the installing agent owns bounded recovery-copy cleanup under the host's `development-workflow/references/macos-app-artifacts.md` policy. Prevent obsolete agent-created app copies from accumulating; preserve active recovery needs, parent metadata and source. User-requested — 2026-11-14.
- Follow [RELEASE.md](../../../RELEASE.md), [package-release.sh](../../../scripts/package-release.sh) and the [release workflow](../../../.github/workflows/release.yml). Public releases are fully GitHub-hosted and use encrypted Actions secrets with a temporary signing Keychain. Preserve the established Developer ID and Sparkle keys when provisioning secrets; never commit them or include them in release artifacts or logs. Do not restore a personal runner as a workaround. Distinguish a test signature, Developer ID signature, Apple notarisation and an actually published download. User-requested — 2026-11-24.
- Do not overwrite a published version tag or asset. Verify the downloadable bytes, checksum, signature and installed version when release-based installation is requested. Report the exact credential or signing blocker if publication cannot complete.
- Keep [README.md](../../../README.md) and `docs/` installation/privacy claims aligned with verified artifacts. After appropriate checks, commit and push in-scope completed changes to the existing `EthanSK/hello-chat` origin, verify the remote commit, and report any failure. Preserve unrelated work.
