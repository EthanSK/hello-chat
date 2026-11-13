<p align="center"><img src="docs/icon.svg" width="112" height="112" alt="Hello Chat icon: a mint speech bubble with five dark waveform bars"></p>

# Hello Chat

Say **Hello Chat** to start Codex Voice, and **Bye Chat** to end it.

Hello Chat is a native macOS app that listens for both phrases with a local speech model, then opens or ends Voice in the Codex desktop app. Codex still runs the conversation.

**Website:** https://ethansk.github.io/hello-chat/

> [!NOTE]
> [Download Hello Chat for Apple Silicon](https://github.com/EthanSK/hello-chat/releases/latest). Release builds are signed and notarised, with automatic updates and **Check for Updates…** in the app menu and Settings. You can also [build from source](#build-from-source).

## How It Works

| Say | What happens |
| --- | --- |
| **Hello Chat** | Opens Voice in Codex. No need to turn it on first. Works after other speech, such as “I stopped the video, Hello Chat”. Clear mentions, such as “I said Hello Chat”, are ignored. |
| **Mute Chat** / **Unmute Chat** | Mutes or unmutes the active Voice microphone. Repeating a command keeps that state. |
| **Silent Chat**, **Silence Chat** / **Unsilence Chat** | Silences or restores Voice speaker audio. The microphone and call remain independent. |
| **Bye Chat** | Ends Voice, after checking Codex's End Voice control is showing. Also cancels Voice while it's opening, and ends a call you started yourself in Codex. |
| **Pause video** / **Play video** | Controls one Chrome video through [Agent Flow Bridge](https://github.com/EthanSK/AgentFlow/tree/main/companions/youtube-bridge#install). Works with YouTube and standard web video players. |

For safe conversation about the app, call the helper **H Chat** and its End command **B Chat**. These are discussion names, not extra voice commands. The default dictionary no longer accepts the old UI-name alias or B/Be/Bee spellings as End. End commands use the same mention and negation filter as the other controls, so discussing a command is not treated as issuing it. Matching and transcript highlighting share the dictionary.

Speech recognition runs on your Mac with a bundled Parakeet model through Core ML, using CPU and Neural Engine with GPU off. Hello Chat then drives Codex through its own Voice shortcut and End Voice control. There's no Agent Flow, proxy, server, account or API key involved in detection.

## Requirements

- A Mac with Apple Silicon. The Core ML speech models need a Neural Engine.
- macOS 15 or later. The optional Apple Speech model needs macOS 26.
- The Codex desktop app, signed in, with Voice available on your account. Hello Chat finds Codex by its bundle identifier, so both `Codex.app` and older installs named `ChatGPT.app` work.
- Internet for Codex Voice. Hello Chat's own detection doesn't need it.
- To build: Xcode 26 or later (Swift 6.2 toolchain) and Python 3. The first build downloads the pinned speech models, so it needs internet too.

## Recommended Setup

1. Open Codex, sign in and start Voice yourself once to check it works.
2. [Download Hello Chat](https://github.com/EthanSK/hello-chat/releases/latest), unzip it and move `HelloChat.app` to `/Applications`.
3. Open Hello Chat. It fills unset **Voice chat hotkey** (Command-Control-Shift-V) and **End voice chat** (Control-Option-Shift-V), preserving existing choices and leaving **Toggle voice chat** alone. If Codex is already running, restart it once to apply new shortcuts. If a default shortcut is already used, resolve the conflict in Codex settings. Allow **Microphone** for local listening and **Accessibility** for Codex's Voice shortcut and End Voice control. If macOS doesn't ask for Accessibility, add Hello Chat in System Settings → Privacy & Security → Accessibility.
4. Choose your microphone on the home page or in **Settings → Microphone**. **System default** follows macOS's default input. Codex Voice keeps its own input setting.
5. Turn on **Listen for wake phrase**. Hello Chat prepares the local model, then shows **Listening**.
6. Say **Hello Chat**. When you're done, say **Bye Chat**.

## Build From Source

```sh
git clone https://github.com/EthanSK/hello-chat.git
cd hello-chat
zsh scripts/build.sh
zsh scripts/test.sh
ditto .build.noindex/HelloChat.app /Applications/HelloChat.app
open /Applications/HelloChat.app
```

Release builds update through **Check for Updates…** or automatic updates. When replacing a source build manually, quit Hello Chat and move the old copy out of `/Applications` before copying the new build. `ditto` merges into an existing bundle rather than replacing it.

`scripts/build.sh`:

- resolves FluidAudio 0.17.7, pinned exactly in `Package.swift`;
- downloads each model file at its pinned Hugging Face revision, checks its SHA-256 against `Resources/SpeechModels.json` and bundles it, so the finished app is about 1.09 GB;
- generates the icon with `scripts/make-icon.swift`, and, when they're missing, two short test recordings with macOS's `say` (Daniel voice);
- copies the sounds, the FluidAudio licence and the third-party notices;
- signs and verifies `.build.noindex/HelloChat.app`, then prints its path.

| Variable | Effect |
| --- | --- |
| `HELLOCHAT_BUILD_DIR` | Absolute directory for all build output, models, recordings and test executables. Defaults to `.build.noindex` in the repository. |
| `HELLOCHAT_SIGNING_IDENTITY` | Code-signing identity. Defaults to your first Developer ID Application certificate, otherwise ad-hoc. |
| `HELLOCHAT_SPEECH_FIXTURES_DIR` | Directory containing existing `SpeechCheck.wav` and `SpeechNegative.wav` to reuse instead of generating new ones. |

macOS ties Microphone and Accessibility permission to the app's signature, so with ad-hoc signing it may ask again after a rebuild. The bundle identifier stays `com.ethansk.HeyChat` from the app's earlier name, so existing permissions carry over.

### Checks

- `zsh scripts/test.sh` compiles and runs unit tests for phrase matching, mention filtering, Codex discovery, Voice control logic, audio handling, the transcript archive and the backup script. They never use a microphone or start a Voice call.
- `.build.noindex/HelloChat.app/Contents/MacOS/HelloChat --check-speech` runs the bundled recordings through the real model and matcher. Add `--model parakeet160`, `--model nemotron560` or `--model appleLocal` to try another model. **Settings → Phrases → Check speech recognition** does the same from the app.
- The same executable with `--check-phrase-variants` runs text-only checks of the compiled phrase dictionary and mention filter. It never captures audio, writes a transcript or starts Voice.

These checks use fixed recordings and text. They don't show how well Hello Chat hears you in your room, or prove Voice works end to end.

## In the App

The main window has two sections:

- **Heard (local model)** comes first, with **Start chat** / **End chat**, Refresh and the local transcript. Its height stays bounded while the current recognition batch remains available to scroll back through. New batches replace old text using the existing recognition reset and quiet-period rules; the Heard panel does not accumulate the entire listening session. The panel follows new words while you are at the bottom and lets you scroll back without being pulled down. Exact matches are green and alternate spellings are orange. Highlighting identifies matching text, not proof an action ran.
- **Listening** comes below it, with the listening toggle, all seven editable phrase fields, **Speech model** and the microphone level. The same phrase fields appear in Settings and save immediately. Mute and Unmute control the microphone; Silent/Silence and Unsilence control Voice audio. Every action is directional and repeating it leaves the requested state unchanged.

For the current trial, commands run as soon as the complete phrase is recognised, without a deliberate post-phrase pause. The earlier 600 ms mode remains covered by tests for a requested reversal. Recognition and native shortcut delivery still take time. Mention and negation filters still apply. Recognition errors or delayed results can still affect detection; this is not a guarantee of intent. Default audio phrases allow a single verb spelling edit, such as the observed “unsilenced chat”, while retaining the directional prefix and the narrow Chat, Chad or Chatt name dictionary. Custom phrases match their exact saved wording, with normal capitalization, spacing and punctuation handling. Alternate spellings apply only to the seven default phrases. The info icon beside each default phrase on Home and in Settings opens its searchable dictionary. Edit or import a UTF-8 text file with one full spelling per line, then Save to replace that default’s built-in alternatives. The default phrase itself always works; an empty dictionary uses only that phrase. A spelling cannot reuse another command’s default phrase, except for Silent and Silence, which share one action. Restore built-in returns to the shipped dictionary. Editing a phrase disables its dictionary controls and keeps any saved dictionary dormant until you restore that default phrase.

Audio commands act only on an existing Voice chat. They do not open or activate Codex, start a call, or play an action sound when no Voice controls are found. The existing process-targeted shortcut is sent once, and confirmation observes the resulting state for up to two seconds instead of treating an immediate stale read as failure. Unknown state never authorizes a toggle; unconfirmed changes still report an error.

When Hello Chat starts a new call, it saves the locally recognised words heard after the wake while Voice was connecting in `~/Library/Application Support/HelloChat/VoiceStartup/pending.json`. On normal app startup, Hello Chat installs or updates its own `hello-chat-voice-startup` skill in the configured Codex skills directory (`~/.codex/skills` by default). The installed skill comes directly from the bundled [Voice startup instructions](Resources/VoiceStartup.md), which remain the single source of truth. It leaves unrelated skills and conflicting user-managed content untouched.

A new local Voice coordinator can read and clear the file through that skill, then say “I'm reading the start of your request from H Chat.” Recognition keeps extending the opening utterance after the Voice window opens. An early reader gets `capturing` with a provisional snapshot of the words recognised so far, labelled incomplete and left intact. The first coordinator to read owns the request. The request becomes ready at the recognizer's utterance end, or once Voice has opened, after some opening words beyond repeated wake greetings arrive and stay unchanged for 2 seconds, or at most 30 seconds of audio. Stability, limit and interrupted cutoffs are marked potentially incomplete. It never becomes ready at window confirmation alone. A recognizer context reset doesn't end the opening. Hello Chat's microphone has no echo cancellation, so on speakers this local text can still include the assistant's own reply if it starts within that pause. It does not paste, switch chats or press Return. The file is private, bounded, separate from transcript backups and replaced at the next new-call start. A reused call publishes nothing. A call started with the button captures new words after the button press. The startup reader merges any overlap with native Voice instead of treating it as a second request. This read needs a Codex work turn: installing the skill does not make the conversational Voice model wait for the file before its first reply.

Words within either command must be close together: no gap over 1.5 seconds, and a two-word phrase must fit within 3 seconds. Longer custom phrases have a proportionally larger total window. The app uses local model audio timestamps where available, with first-observed word times as a fallback. This does not limit the length of a Voice conversation or add a delay after a valid command.

By default, the listening toggle controls listening without requiring power or an external display. Its On/Off choice is remembered when the app restarts. Automatic Listening is optional; existing saved docking preferences are preserved.

Wake and end phrases keep working while Agent Flow is recording, using the same phrase-matching rules as normal listening.

If Core ML fails during recognition or a model reload, Hello Chat tries up to three local restarts without ending Codex Voice. After repeated failures it stops reloading until a power/display change, system wake or manual restart gives it another chance. Automatic listening still waits two minutes after docking. A Core ML operation already in progress must return before its model can be safely replaced.

The menu bar has **Start listening** / **Stop listening** and the same Voice controls. **Settings…** (⌘,) has:

| Section | Contents |
| --- | --- |
| Microphone | **System default** or a named input, which stays selected by device. If it's disconnected, listening stops with an error instead of switching microphones. |
| Automatic Listening | **Listen automatically when docked**, off by default. Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. Turning listening on yourself works with any display setup and stays on across restarts. |
| Phrases | The seven wake, end and audio phrase fields; **Alternate spellings for default phrases** (on by default), their dictionary editors and **Check speech recognition**. |
| Resources | Hello Chat's own CPU and memory, and Core ML's estimated encoder placement. |
| Sounds | **Sound effects** (on by default), with **Wake sound** and **End sound** previews. |
| Spotify | **Lower volume during chat**, off by default. Requires permission to control Spotify. |
| Transcript Archive | **Save transcripts** (on by default), the archive location, and this Mac’s optional backup configuration. |
| Updates | **Check for Updates…**, automatic checking and automatic downloads on release-configured builds. |
| Diagnostics | Timing, errors and startup request/revision metadata, which exclude recognised words. |
| Appearance | **Open windows on** remembers your display choice and uses an available display when disconnected. Zoom starts at 100%. **View → Zoom In / Zoom Out / Actual Size** works too. |

## Spotify volume during chat

Enable **Settings → Spotify → Lower volume during chat** to cap Spotify's own slider at 50% while a native call is on. A quieter setting stays quieter. **Allow Spotify control** requests macOS Automation permission; Spotify must already be open. This never starts playback or changes the Mac's output volume.

The original slider value is saved privately before it changes and restored after confirmed call end. If you change the slider yourself, that value wins for that call. Saved call identifiers keep a previous call's override from following you into a fresh call, including when End and Start happen between checks. Normal Hello Chat Quit restores immediately without ending the Codex call; an updater carries the saved value into the replacement app. After a crash, the next launch uses that receipt to recover. A helper that is no longer running cannot restore at a later call end.

Detection uses native Accessibility notifications and fresh call controls, including calls started or stopped directly in Codex and temporary chats. Saved call-boundary metadata is supplementary evidence during reconnects; Hello Chat does not subscribe to Codex's private server, read transcripts, or write its database. Incomplete control reads remain unknown. The private metadata format and UI can change across Codex versions; live manual-end and temporary-chat acceptance must be checked against the installed version.

## Updates

Release-configured builds use Sparkle 2.10.1. **Check for Updates…** is in the app menu and Settings. Automatic checks/downloads use Sparkle’s saved preferences; the app does not overwrite your choices on launch. Updates are signed with Ed25519, as well as the app’s Developer ID signature.

A requested update waits for Hello Chat's own in-flight actions and speech checks before relaunching. An active Codex Voice call or Agent Flow recording does not block the update. Normal Quit and update cleanup detach from Codex without ending its call. Development builds without the production public key leave update controls disabled. See [release setup and verification](RELEASE.md).

## Speech Models

| Model | Notes |
| --- | --- |
| Nemotron · 560 ms | Default. NVIDIA's larger Nemotron Speech Streaming EN 0.6B. |
| Parakeet EOU · 320 ms | NVIDIA's Parakeet Realtime EOU 120M, converted to Core ML by Fluid Inference. |
| Parakeet EOU · 160 ms | Lower latency, with more recognition mistakes in recorded checks, including a false wake on a phrase mention and a missed end phrase. Prefer 320 ms or Nemotron for reliability. |
| Apple Speech · local | macOS 26 only, using English speech assets already installed on your Mac. If they're missing, Hello Chat shows an error instead of downloading them. |

New installations select Nemotron first. Existing saved model choices are preserved.

The three Core ML models run with `cpuAndNeuralEngine`, so GPU is excluded. Before listening, Hello Chat requires a Neural Engine and checks that Core ML's compute plan puts most of the encoder there. That's a compiler estimate, not measured utilisation: the CPU still handles audio, decoding and part of the model, and there's no Neural Engine-only mode. Apple doesn't expose where Apple Speech runs, so its Neural Engine use is unverified, and its work happens in a system service outside Hello Chat's own CPU and memory figures.

## Privacy and Data

- **Audio** is never saved. Hello Chat captures input only from the microphone you choose, without changing system audio routing, gain or volume.
- **Transcripts** are saved locally by default in `~/Library/Application Support/HelloChat/Transcripts/YYYY-MM-DD/`, one JSON file per recognition context with the latest text, model, microphone name and rough phrase timestamps. Files are `0600` and folders `0700`. Turn off **Save transcripts** to stop; existing files stay.
- Hello Chat keeps listening while Voice is on, so it can hear Bye Chat. Transcripts can include your side of the conversation and anything else the microphone picks up.
- **Logs** in `~/Library/Logs/HelloChat/` (`events.jsonl` and `events.previous.jsonl`, each capped at 512 KiB) contain timings and errors, never recognised words.
- **Network**: listening makes no network requests, and models are never downloaded at runtime. The build, Sparkle update checks/downloads and the optional backup script use the network. Update checks do not include saved transcripts or audio.
- **Codex**: Hello Chat reads Codex's Voice shortcut from `~/.codex/keybindings.json` and inspects Codex's accessibility tree during Start, End, Refresh, or while a downloaded update is waiting to relaunch. Startup speech is handed to the local Voice skill through the private file above; Hello Chat does not navigate to a chat or submit a message. Start uses the global native shortcut without first activating Codex. The conversation, its audio, network connection and sign-in all belong to Codex.
- **Optional Spotify control**: when enabled, native window/control notifications trigger read-only call checks in the background. Hello Chat also reads only saved call-start/end metadata from Codex's local timeline. Its private `SpotifyVolume/restore.json` receipt stores the original/applied volume values and an opaque call identifier. macOS Automation permission permits Spotify volume access; tracks and library contents are not read.

### Optional Google Drive Backup

Transcripts stay on your Mac unless you install this separate script. It isn't installed by the build and needs [rclone](https://rclone.org/drive/) with your own Google Drive remote.

The Transcript Archive pane checks this Mac’s LaunchAgent before saying backup is configured. A configuration file is not proof that a recent upload succeeded.

```sh
# Print the LaunchAgent without installing it
python3 scripts/install-transcript-backup.py

# Install it with a dedicated rclone configuration and destination
python3 scripts/install-transcript-backup.py --install \
  --rclone-config /path/to/rclone.conf \
  --destination 'remote:HelloChat Backup/Transcripts'
```

The job runs daily at 05:45 local time, only while the Mac is on power; it does not start at login. If the Mac is asleep at the scheduled time, macOS starts the job after it wakes. It uploads one immutable JSON snapshot per changed UTC day with `rclone copy`, so it never deletes remote files, and it never uploads audio. With `--rclone-config`, it uses only that file and fails if it's missing. On a first installation without route options, it uses rclone's default configuration and `gdrive:HelloChat Backup/Transcripts`. Reinstalling preserves an existing dedicated configuration and destination unless you explicitly replace them. Consider your own Google client ID, following [rclone's guidance](https://rclone.org/drive/#making-your-own-client-id), to avoid shared quota errors.

### Start at Login

After copying Hello Chat to `/Applications`, quit it and run:

```sh
python3 scripts/install-startup.py
```

This adds a `com.ethansk.hello-chat` LaunchAgent that opens Hello Chat at login and reopens it after a crash. Quit still quits. A Sparkle relaunch returns to this existing job before opening the UI, preserving crash recovery. No job is added for users who have not installed one. Use `--dry-run` to print it first. To remove it:

```sh
launchctl bootout "gui/$(id -u)/com.ethansk.hello-chat"
rm ~/Library/LaunchAgents/com.ethansk.hello-chat.plist
```

## How Codex Control Works

- Hello Chat identifies Codex by the bundle identifier `com.openai.codex` and checks that the running executable belongs to that bundle. It doesn't depend on one install path.
- **Start** sends the **Voice chat hotkey** (`realtimeVoice`) through macOS’s global shortcut path. The default is Command-Control-Shift-V. **Toggle voice chat** (`composer.startVoiceMode`) is separate and is never configured or sent by Hello Chat. Custom letters, digits, punctuation (including grave/tilde), F1–F20 and navigation keys are preserved, including their modifiers. Unsupported keys or multi-step sequences produce a setup error.
- If Codex is closed, Hello Chat launches the registered Codex app, waits for its native window to be ready, then sends Start once. Opening/reopening gets a five-second minimum and up to ten seconds for interactive readiness; an explicitly unready window never becomes ready just because time passes. A replacement process gets one fresh bounded window. An already-open call is reused without the launch delay.
- An existing muted call is unmuted through its configured microphone shortcut after checking its current state.
- Start requires an unlocked, active macOS desktop. A wake heard while locked is not queued for later. After unlocking, say the wake phrase again; old recognition and pending opening state are cleared without ending an existing call.
- **End** sends the dedicated `realtimeVoice.endCall` shortcut after a fresh Voice-control check. A retry presses the exact End control itself. If closure cannot be confirmed, Hello Chat says the status is unknown instead of claiming the End action failed.
- Shortcut writes are marked as saved, not proof of live registration. If Hello Chat adds bindings while Codex is running, it shows a restart message. Voice confirmation still depends on the actual call controls.
- New Voice chats use Codex's normal new-chat model and speed defaults.

This isn't an official Codex wake-word API. A Codex update can change the shortcut or controls; Hello Chat then shows an error instead of guessing.

### ChatGPT and Codex presentations

Hello Chat already uses the same dedicated Start command for the ChatGPT and Codex presentations of the `com.openai.codex` desktop app. Its implementation is not restricted to Codex mode. It preserves the user's selected presentation: it does not switch modes or rewrite the app's turn-detail preference to make a call start.

[OpenAI documents Voice in Chat, Work, and Codex](https://learn.chatgpt.com/docs/features/voice), subject to account, rollout, and workspace availability. Both presentations use the dedicated **Voice chat hotkey** in **Settings → Voice**. Hello Chat uses that same configured `realtimeVoice` command; **Toggle voice chat** is not a fallback.

The shared command path does not establish native Voice availability or successful calls in both presentations. Verify each presentation separately; a successful Codex call alone does not verify ChatGPT-mode compatibility.

If a wake is acknowledged but Voice does not open, first test the configured Voice chat hotkey manually in that same presentation, after the current call has finished. A shortcut that also fails manually is not evidence of a Hello Chat key-delivery failure. Check native Voice availability and its shortcut registration before changing the sender. Hello Chat cannot enable a Voice feature that the desktop app has not made available.

The app's shortcut editor can also look different between presentations. The saved `conversationDetailMode` preference, account policy, and current route influence that view. Its configured value is not proof of the live effective value or Voice availability. Keep the selected mode and unrelated preferences intact during diagnosis.

## Limits

- It isn't speaker-locked or voice-identified: anyone the microphone can hear, including a video, can wake or end Voice.
- Matching leans towards waking, so it can hear a phrase nobody said, or miss one.
- Listening always uses some CPU. Resources in Settings shows Hello Chat's share; Neural Engine use isn't measured.
- Detection is local, but Hello Chat isn't an offline assistant: Codex Voice needs internet.
- So far it's been used on Ethan's own Mac, not tested across a range of fresh setups.

## Upgrading From Hey Chat

On first launch, Hello Chat moves `~/Library/Application Support/Hey Chat` and `~/Library/Logs/Hey Chat` to `~/Library/Application Support/HelloChat` and `~/Library/Logs/HelloChat`. Files already in the new folders win; anything that would collide stays at its old path. The bundle identifier and single-instance lock are unchanged, so permissions carry over and the old and new apps can't run at the same time.

## History

Hello Chat started as Hey Chat, a private project. It was renamed because “Hey” was often missed by the recogniser.

This repository previously held [HeyBoy](https://github.com/EthanSK/hello-chat/tree/archive/heyboy-before-hellochat), an older, unrelated Vosk and Deepgram voice assistant. Hello Chat replaces it; HeyBoy's history is preserved at the `archive/heyboy-before-hellochat` tag. HeyBoy's install instructions don't apply to Hello Chat.

## Licence

Hello Chat's first-party source is under [Apache 2.0 + Commons Clause v1.0](LICENSE). FluidAudio is under the Apache License 2.0, and the Parakeet and Nemotron models are under the NVIDIA Open Model License; see [`Resources/THIRD-PARTY-NOTICES.txt`](Resources/THIRD-PARTY-NOTICES.txt). Hello Chat isn't affiliated with OpenAI. Codex and ChatGPT are OpenAI's.

## Maintaining the Website

The static GitHub Pages site lives in `docs/`. After changing its CSS, JavaScript, or the app icon, run `python3 scripts/prepare-site.py` on macOS to regenerate the sharing image and content-derived asset cache keys. `python3 scripts/prepare-site.py --check` verifies freshness without changing files.


## License

Source-available under [Apache License 2.0 with Commons Clause v1.0](LICENSE). You may use and modify the covered software, including internally at work, and redistribute it under these terms. Commons Clause restricts selling products or services whose value derives entirely or substantially from the software's functionality; it does not prohibit every commercial use. Earlier licenses and third-party rights remain in force. See [scope and release policy](LICENSING.md).

### Microphone and Voice audio shortcuts

Missing microphone and Voice audio bindings use Command–Control–Shift–M and Command–Control–Shift–O, respectively. Existing custom bindings are preserved. Mute and Unmute use the microphone shortcut; Silent, Silence and Unsilence use the Voice audio shortcut. Shortcuts saved while Codex is running may still need applying in its native Keyboard shortcuts settings or a later restart. A saved key alone does not confirm live registration.
