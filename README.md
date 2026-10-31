<p align="center"><img src="docs/icon.svg" width="112" height="112" alt="HelloChat icon: a mint speech bubble with five dark waveform bars"></p>

# HelloChat

Say **Hello Chat** to start Codex Voice, and **Bye Chat** to end it.

HelloChat is a native macOS app that listens for both phrases with a local speech model, then opens or ends Voice in the Codex desktop app. Codex still runs the conversation.

**Website:** https://ethansk.github.io/hello-chat/

> [!NOTE]
> Source only for now. There's no signed, notarised download yet, so [build it yourself](#build-from-source).

## How It Works

| Say | What happens |
| --- | --- |
| **Hello Chat** | Opens Voice in Codex. No need to turn it on first. Works after other speech, such as “I stopped the video, Hello Chat”. Clear mentions, such as “I said Hello Chat”, are ignored. |
| **Bye Chat** | Ends Voice, after checking Codex's End Voice control is showing. Also cancels Voice while it's opening, and ends a call you started yourself in Codex. |
| *Nothing* | Voice ends after 1 minute without new words. Choose 30 seconds, 1 minute or 2 minutes with **End Voice after silence**. |

Speech recognition runs on your Mac with a bundled Parakeet model through Core ML, using CPU and Neural Engine with GPU off. HelloChat then drives Codex through its own Voice shortcut and End Voice control. There's no Agent Flow, proxy, server, account or API key involved in detection.

## Requirements

- A Mac with Apple Silicon. The Core ML speech models need a Neural Engine.
- macOS 15 or later. The optional Apple Speech model needs macOS 26.
- The Codex desktop app, signed in, with Voice available on your account. HelloChat finds Codex by its bundle identifier, so both `Codex.app` and older installs named `ChatGPT.app` work.
- Internet for Codex Voice. HelloChat's own detection doesn't need it.
- To build: Xcode 26 or later (Swift 6.2 toolchain) and Python 3. The first build downloads the pinned speech models, so it needs internet too.

## Recommended Setup

1. Open Codex, sign in and start Voice yourself once to check it works.
2. [Build HelloChat](#build-from-source) and copy it to `/Applications`.
3. Open HelloChat and allow **Microphone** for local listening and **Accessibility** for Codex's Voice shortcut and End Voice control. If macOS doesn't ask for Accessibility, add HelloChat in System Settings → Privacy & Security → Accessibility.
4. In **Settings → Microphone**, choose your microphone. **System default** follows macOS's default input. Codex Voice keeps its own input setting.
5. Turn on **Listen for wake phrase**. HelloChat prepares the local model, then shows **Listening**.
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

To update, quit HelloChat and move the old copy out of `/Applications` before copying the new build. `ditto` merges into an existing bundle rather than replacing it.

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

These checks use fixed recordings and text. They don't show how well HelloChat hears you in your room, or prove Voice works end to end.

## In the App

The main window has three sections:

- **Listening**: **Listen for wake phrase**, editable **Start Voice** and **End Voice** phrases, the current status, **Speech model** and the microphone level. Phrase edits save immediately and stay in sync with Settings.
- **Heard (local model)**: the latest local transcript. A wake phrase match is green when exact, orange for a known mishearing and purple for another small spelling difference. Highlighting shows text matches, not that Voice started.
- **Codex Voice**: Voice status, the latest event and **Start Voice in Codex** / **End Voice in Codex**.

By default, the listening toggle controls listening without requiring power or an external display. Its On/Off choice is remembered when the app restarts. Temporary playback pauses do not erase that choice. Automatic Listening is optional; existing saved docking preferences are preserved.

The menu bar has **Start listening** / **Stop listening** and the same Voice controls. **Settings…** (⌘,) has:

| Section | Contents |
| --- | --- |
| Microphone | **System default** or a named input, which stays selected by device. If it's disconnected, listening stops with an error instead of switching microphones. |
| Automatic Listening | **Listen automatically when docked**, off by default. Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. Turning listening on yourself works with any display setup and stays on across restarts. |
| Phrases | **Start Voice** and **End Voice** phrases, **Allow small spelling differences** (on by default), **End Voice after silence** and **Check speech recognition**. |
| Resources | HelloChat's own CPU and memory, and Core ML's estimated encoder placement. |
| Sounds | **Sound effects** (on by default), with **Wake sound** and **End sound** previews. |
| Transcript Archive | **Save transcripts** (on by default) and the archive location. |
| Diagnostics | Timing and error logs, which exclude recognised words. |
| Appearance | Zoom. **View → Zoom In / Zoom Out / Actual Size** works too. |

## Speech Models

| Model | Notes |
| --- | --- |
| Parakeet EOU · 320 ms | Default. NVIDIA's Parakeet Realtime EOU 120M, converted to Core ML by Fluid Inference. |
| Parakeet EOU · 160 ms | Lower latency. It missed more words in earlier recorded checks. |
| Nemotron · 560 ms | NVIDIA's larger Nemotron Speech Streaming EN 0.6B. |
| Apple Speech · local | macOS 26 only, using English speech assets already installed on your Mac. If they're missing, HelloChat shows an error instead of downloading them. |

The three Core ML models run with `cpuAndNeuralEngine`, so GPU is excluded. Before listening, HelloChat requires a Neural Engine and checks that Core ML's compute plan puts most of the encoder there. That's a compiler estimate, not measured utilisation: the CPU still handles audio, decoding and part of the model, and there's no Neural Engine-only mode. Apple doesn't expose where Apple Speech runs, so its Neural Engine use is unverified, and its work happens in a system service outside HelloChat's own CPU and memory figures.

## Privacy and Data

- **Audio** is never saved. HelloChat captures input only from the microphone you choose, without changing system audio routing, gain or volume.
- **Transcripts** are saved locally by default in `~/Library/Application Support/HelloChat/Transcripts/YYYY-MM-DD/`, one JSON file per recognition context with the latest text, model, microphone name and rough phrase timestamps. Files are `0600` and folders `0700`. Turn off **Save transcripts** to stop; existing files stay.
- HelloChat keeps listening while Voice is on, so it can hear Bye Chat. Transcripts can include your side of the conversation and anything else the microphone picks up.
- **Logs** in `~/Library/Logs/HelloChat/` (`events.jsonl` and `events.previous.jsonl`, each capped at 512 KiB) contain timings and errors, never recognised words.
- **Network**: listening makes no network requests, and models are never downloaded at runtime. Only the build and the optional backup script use the network.
- **Codex**: HelloChat reads Codex's Voice shortcut from `~/.codex/keybindings.json` and inspects Codex's accessibility tree only while starting or ending Voice. The conversation, its audio, network connection and sign-in all belong to Codex.

### Optional Google Drive Backup

Transcripts stay on your Mac unless you install this separate script. It isn't installed by the build and needs [rclone](https://rclone.org/drive/) with your own Google Drive remote.

The Transcript Archive pane's backup text describes this optional job; it doesn't detect whether you've installed it.

```sh
# Print the LaunchAgent without installing it
python3 scripts/install-transcript-backup.py

# Install it with a dedicated rclone configuration and destination
python3 scripts/install-transcript-backup.py --install \
  --rclone-config /path/to/rclone.conf \
  --destination 'remote:HelloChat Backup/Transcripts'
```

The job runs at login and then daily, only while the Mac is on power. It uploads one immutable JSON snapshot per changed UTC day with `rclone copy`, so it never deletes remote files, and it never uploads audio. With `--rclone-config`, it uses only that file and fails if it's missing. Without options, it uses rclone's default configuration and `gdrive:HelloChat Backup/Transcripts`. Consider your own Google client ID, following [rclone's guidance](https://rclone.org/drive/#making-your-own-client-id), to avoid shared quota errors.

### Start at Login

After copying HelloChat to `/Applications`, quit it and run:

```sh
python3 scripts/install-startup.py
```

This adds a `com.ethansk.hello-chat` LaunchAgent that opens HelloChat at login and reopens it after a crash. Quit still quits. Use `--dry-run` to print it first. To remove it:

```sh
launchctl bootout "gui/$(id -u)/com.ethansk.hello-chat"
rm ~/Library/LaunchAgents/com.ethansk.hello-chat.plist
```

## How Codex Control Works

- HelloChat identifies Codex by the bundle identifier `com.openai.codex` and checks that the running executable belongs to that bundle. It doesn't depend on one install path.
- **Start** sends Codex's `composer.startVoiceMode` shortcut from `~/.codex/keybindings.json` to the Codex process. The default is Control-Shift-V. A custom shortcut needs to end in V, F16, F17, F19 or F20.
- **End** first looks for Codex's live End Voice control, then sends the same shortcut once and checks Voice closed. A retry presses the End control itself. It never sends a second toggle that could reopen Voice, and it never treats dictation as a Voice call.
- New Voice chats use Codex's normal new-chat model and speed defaults.

This isn't an official Codex wake-word API. A Codex update can change the shortcut or controls; HelloChat then shows an error instead of guessing.

## Limits

- It isn't speaker-locked or voice-identified: anyone the microphone can hear, including a video, can wake or end Voice.
- Matching leans towards waking, so it can hear a phrase nobody said, or miss one.
- Listening always uses some CPU. Resources in Settings shows HelloChat's share; Neural Engine use isn't measured.
- Detection is local, but HelloChat isn't an offline assistant: Codex Voice needs internet.
- Listening pauses while a Bose Flex 2 SoundLink is the selected playback output. That's a rule for Ethan's own speaker.
- So far it's been used on Ethan's own Mac, not tested across a range of fresh setups.

## Upgrading From Hey Chat

On first launch, HelloChat moves `~/Library/Application Support/Hey Chat` and `~/Library/Logs/Hey Chat` to their HelloChat equivalents. Files already in the new folders win; anything that would collide stays at its old path. The bundle identifier and single-instance lock are unchanged, so permissions carry over and the old and new apps can't run at the same time.

## History

HelloChat started as Hey Chat, a private project. It was renamed because “Hey” was often missed by the recogniser.

This repository previously held [HeyBoy](https://github.com/EthanSK/hello-chat/tree/archive/heyboy-before-hellochat), an older, unrelated Vosk and Deepgram voice assistant. HelloChat replaces it; HeyBoy's history is preserved at the `archive/heyboy-before-hellochat` tag. HeyBoy's install instructions don't apply to HelloChat.

## Licence

HelloChat's first-party source is under [the no-sale terms](LICENSE). FluidAudio is under the Apache License 2.0, and the Parakeet and Nemotron models are under the NVIDIA Open Model License; see [`Resources/THIRD-PARTY-NOTICES.txt`](Resources/THIRD-PARTY-NOTICES.txt). HelloChat isn't affiliated with OpenAI. Codex and ChatGPT are OpenAI's.

## Maintaining the Website

The static GitHub Pages site lives in `docs/`. After changing its CSS, JavaScript, or the app icon, run `python3 scripts/prepare-site.py` on macOS to regenerate the sharing image and content-derived asset cache keys. `python3 scripts/prepare-site.py --check` verifies freshness without changing files.


## License

Source-available under [Ethan Source-Available No-Sale Terms 1.0](LICENSE). You can use and modify the covered code, including internally at work, and share it without charge. Selling the software, modified versions, paid access, or bundles requires a separate commercial license. Earlier licenses and third-party rights remain in force. See [scope and release policy](LICENSING.md).
