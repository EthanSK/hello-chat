<p align="center"><img src="docs/icon.svg" width="112" height="112" alt="Hello Chat icon"></p>

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
| **Mute Chat**, **Mute mic** / **Unmute Chat** | Sends the Voice microphone toggle once. Mute and Unmute both toggle, so repeating either reverses the previous change. |
| **Silence Chat**, **Silent Chat**, **Mute speakers**, **Silent speaker(s)** / **Unsilence Chat**, **Unsilent speaker(s)**, **Unmute speaker(s)** | Sends the Voice speaker toggle once. Silence and Unsilence both toggle. Standalone **Unmute** and **Unsilence** wait for the utterance to end, so **Unmute Chat** keeps its microphone meaning. The microphone remains independent. |
| **Bye Chat** | Ends Voice, after checking Codex's End Voice control is showing. Also cancels Voice while it's opening, and ends a call you started yourself in Codex. |
| **Pause music** / **Play music** | Each sends one hardware Play/Pause press to the current system media session. Both are toggles, so either phrase can pause or resume. H Chat does not choose or launch an app; macOS routes the key. |
| **Call Dot** / **Hang up** | Starts or ends a call with Your dot in ChatGPT. These commands are separate from Codex Voice and meetings. Both have native Shortcuts actions and their own phrase, spelling, repeat and sound settings. |
| **Spotify volume 40**, **Spotify volume forty percent** | Sets the running Spotify player to a volume from 0 to 100. Spoken numbers work too; “forty five” sets 45. Keeps system volume, playback and your saved Maximum volume setting unchanged. A deliberate volume choice stays in place after the call. |
| **Pause video** / **Play video** | Controls one Chrome video through [Agent Flow Bridge](https://github.com/EthanSK/AgentFlow/tree/main/companions/youtube-bridge#install). Works with YouTube and standard web video players. |
| **Switch app Chrome** / **Open app Chrome** | Both bring the app forward, opening it if it isn't running. Accepts common names and clear mishearings such as “BS Code” for VS Code. Say the full app name when two apps sound similar. |
| **Show me Codex**, **Show Codex**, **Show app Codex** / **Open Safari** | Brings the named app forward. Short forms accept an exact name or a saved spelling. |
| **Show voice** | Opens the current Voice conversation in Codex, or the most recent saved Voice chat after a call. |
| **Rewind video** | Moves the selected browser video back through Agent Flow Bridge, keeping its paused or playing state. Defaults to ten seconds; change the amount in Rewind video’s gear on Home. Explicit five- and ten-second phrases keep their distances. |
| **Zoom in** / **Zoom out** | Sends the standard zoom shortcut to the front app. The app decides what its zoom shortcut does. |
| **Zoom in three times**, **Zoom in 3** | Runs a command that many times, up to 100. Repeat count is on for every command by default. Say the number after the whole command, including any app or speaker name. Without a number, it runs once. For rewind, always include “times”, since a number alone can be a distance. For Spotify volume, separate the value with “percent”: “Spotify volume forty percent three times”. For music, each run is another Play/Pause press, so an even number can leave playback as it was. Turn off **Repeat count** in a command’s gear on Home. |

Each Voice, video, music, app and zoom phrase has its own short sound. Wake and End play at detection. Ending a call directly in Codex also plays the End sound, without repeating one already played for that call. Voice audio commands play a short detection tone when Codex is available, followed by their phrase sound when the shortcut is sent. The sound does not confirm the audio state. Video sounds acknowledge a confirmed pause/play result; music, app and zoom sounds acknowledge dispatch. Check the status in the app for the outcome.

For safe conversation about the app, call the helper **H Chat** and its End command **B Chat**. These are discussion names, not extra voice commands. The default dictionary no longer accepts the old UI-name alias or B/Be/Bee spellings as End. End commands use the same mention and negation filter as the other controls, so discussing a command is not treated as issuing it. Matching and transcript highlighting share the dictionary.

Speech recognition runs on your Mac, by default with the bundled Nemotron model through Core ML, using CPU and Neural Engine with GPU off. Hello Chat then drives Codex through its own Voice shortcut and End Voice control. There's no Agent Flow, proxy, server, account or API key involved in detection.

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
4. Choose your microphone on Home. **System default** follows macOS's default input. Codex Voice keeps its own input setting.
5. Turn on **Listening enabled**. Hello Chat prepares the local model, then shows the live microphone level. Listening status is also in the menu bar.
6. Say **Hello Chat**. When you're done, say **Bye Chat**.

## Agent Bridge

A paired agent can discover H Chat's native actions and edit its settings on the receiving Mac. Read the [agent control protocol](docs/agent-control.md) for discovery, arguments, call identities and receipts.

## Siri and Apple Vocal Shortcuts

Hello Chat provides ten native actions in Apple's Shortcuts app: Start chat, End chat, Mute chat microphone, Unmute chat microphone, Silence chat speakers, Restore chat speakers, Set Voice to Ultrafast, Get chat status, Call Dot and Hang up Dot. They use the same controls as the app. Dot actions target Your dot; the other call actions target Codex Voice. Start can work while local listening is off; it does not turn the local speech model on. Get chat status only reads the current state.

**Set Voice to Ultrafast**, also in Settings and the menu bar, opens the current local Voice chat and selects Ultrafast in Codex’s native Speed menu. It keeps that chat’s model, reasoning and draft. The selection applies to its next turn; it does not change a running turn or the realtime speaking voice. If Voice is off, the chat name is ambiguous, more than one chat pane is open or you start interacting during selection, the action refuses rather than guessing. This control does not change new-chat defaults.

On a supported Mac, **System Settings → Accessibility → Vocal Shortcuts** can map a personally trained phrase to one of those actions or a saved shortcut containing it. Apple processes Vocal Shortcuts audio on the device. Train it with your own voice; this app cannot supply your enrollment. Siri is another way to invoke the preconfigured app shortcuts.

Vocal Shortcuts is optional. It does not automatically replace Hello Chat's detector, and enabling both means both can hear the same request. Compare them separately before choosing. Fixed trained phrases also do not replace the variable app-name commands, ongoing transcripts or startup speech capture. Apple does not publish a head-to-head accuracy or energy comparison with Nemotron. See [Apple's Vocal Shortcuts guide](https://support.apple.com/en-mt/guide/mac-help/mchlf4548bb6/27/mac/27).

## Build From Source

```sh
git clone https://github.com/EthanSK/hello-chat.git
cd hello-chat
zsh scripts/build.sh
zsh scripts/test.sh
open .build.noindex
```

Copy `HelloChat.app` from the opened build folder into `/Applications`, then open it. Quit an existing H Chat copy and move its old bundle out of `/Applications` before copying the replacement. Normal Quit preserves an independent Codex call.

Normal builds update through **Check for Updates…** or automatic updates.

`scripts/build.sh`:

- resolves FluidAudio 0.17.7, pinned exactly in `Package.swift`;
- downloads each model file at its pinned Hugging Face revision, checks its SHA-256 against `Resources/SpeechModels.json` and bundles it, so the finished app is about 1.09 GB;
- renders `Resources/AppIcon.svg` at every required size with `scripts/make-icon.swift`, and, when they're missing, two short test recordings with macOS's `say` (Daniel voice);
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
- `.build.noindex/HelloChat.app/Contents/MacOS/HelloChat --check-speech` runs the bundled recordings through the real model and matcher. Add `--model parakeet160`, `--model nemotron560` or `--model appleLocal` to try another model. **Settings → Recognition → Check speech recognition** does the same from the app.
- The same executable with `--check-phrase-variants` runs text-only checks of the compiled phrase dictionary and mention filter. It never captures audio, writes a transcript or starts Voice.

These checks use fixed recordings and text. They don't show how well Hello Chat hears you in your room, or prove Voice works end to end.

## In the App

The Help menu links to setup instructions and issue reporting. The main window has two sections:

- **Live transcription** comes first, with the configured wake or end phrase as its call button, Refresh and the local transcript. Last command below it shows the outcome; the history button opens recent command results. Its height stays bounded while the current recognition batch remains available to scroll back through. New batches replace old text using the existing recognition reset and quiet-period rules; the Heard panel does not accumulate the entire listening session. The panel follows new words while you are at the bottom and lets you scroll back without being pulled down. Exact matches are green and alternate spellings are orange. Highlighting identifies matching text, not proof an action ran.
- **Commands** comes below it, with the listening toggle, preparation or waiting messages when needed, editable Voice, music, browser and desktop phrases, **Speech model** and the microphone level. Home is the only editing location for these phrases and the microphone. Settings keeps advanced options and a link back to Home. Mute and Unmute control the microphone, and Silent, Silence and Unsilence control Voice audio. Repeating an audio command sends another toggle.

The **Switch app** panel combines the saved Switch and Open rows. Its defaults include **Switch app**, **Open app**, **Switch up**, **Switch to**, **Switch**, **Show app**, **Show me**, **Show** and **Open**, followed by an app name. Existing custom rows and dictionaries stay saved. **Add phrase** in a command’s panel adds another trigger for that command. Typing phrases separated by **/**, such as “Open app / Launch app”, adds them as separate rows when you press Return or leave the field. Extra phrases match exactly and highlight like the main phrase. Default Wake rows include **Hey Chat**, and default End rows include **Goodbye Chat**. The new rows are added once to unchanged default sections; custom main phrases are preserved, and deleted extra rows are not added again. A phrase another command already uses is ignored for the new one, and its row says which command has it. Main phrases take priority, then extra rows in list order.

Say **Show voice** to open the current call’s chat in Codex. When no call is running, H Chat opens the most recent available Voice chat on this Mac. If the current call is unclear or there’s no saved Voice chat, it leaves the window alone.

**Switch speakers…** on Home configures spoken prefixes and speaker names. Say a prefix followed by a saved name, such as “Switch speakers to Kitchen”. The default prefixes are Switch speaker, Switch speakers, Switch audio and Change audio; edit or add lines in the editor. Speaker names and prefixes match exactly, ignoring capitalization and punctuation. Conflicting commands are disabled rather than choosing an output ambiguously.

This optional integration requires the separately installed local audio-switch helper at `~/.codex/skills/live-voice-mode/scripts/switch-output.py`; it is not bundled with Hello Chat. The editor lists connected CoreAudio outputs plus the helper’s saved Bluetooth speakers, including known disconnected ones. Duplicate device names are excluded rather than selected ambiguously. The helper’s known Bose and Soundcore routes protect the existing computer/interface microphone; an app’s own input choice remains separate. If the helper is missing, the list is empty and no switch runs. Its reported status includes failures and microphone warnings. It preserves the system-alert output by default. A system output switch does not prove every app follows the system route.

**App spellings…** inside Switch app lists installed apps and their recognized spellings. Select an app and edit one spelling per line. Examples include Codec, Codecs and Kodaks for Codex, BS Code for VS Code, Agent Floor for Agent Flow and Record books for Rekordbox. Saving replaces that app's built-in alternatives; an empty list uses app names only. Restore built-in removes the override. Spellings stay attached to the app's bundle identity, and Switch and Open read the same saved configuration. Native app names always work, independently of phrase dictionaries and their alternate-spelling switch. The editor checks other installed apps' names and spellings for conflicts; ambiguous matches never choose an arbitrary app.

Switch and Open wait for a brief speech pause so the model can finish the app name. Exact running names and the existing legacy aliases keep their fast route. New and custom spellings compare running apps and the cached Applications catalog together, so a running alias cannot hide a closed app's real name. The running copy is preferred, and an installed app opens if it isn't running. The short **Open**, **Show** and **Show me** forms need an exact name or a known alias. The full **Switch app** and **Open app** forms also accept clear mishearings. Zoom works in the front app on an unlocked desktop with Accessibility access.

Complete phrases run as soon as they are recognised, without a deliberate post-phrase pause. App-name commands wait for a brief speech pause so recognition can finish the name. Recognition and native shortcut delivery still take time. Mention and negation filters still apply. Recognition errors or delayed results can still affect detection; this is not a guarantee of intent. Built-in alternatives are a short list of plausible real-word mishearings, including the observed “unsilenced chat”. They do not generate arbitrary letter edits or accept every word beginning with “ch”. Audio directions stay separate, with Chat or Chad as the address. Custom phrases match their exact saved wording, with normal capitalization, spacing and punctuation handling. Alternate spellings apply to default phrases; custom phrases match exactly. Each command’s gear on Home opens its settings. Each default trigger has one alternate-spellings editor showing the same effective list used for recognition. The info button beside every Home title explains the action. Play and Pause keep separate settings and directional browser actions; music still uses the system media toggle. Edit or import a UTF-8 text file with one full spelling per line, then Save to replace that default’s built-in alternatives. The default phrase itself always works; an empty dictionary uses only that phrase. A spelling cannot reuse another command’s default phrase, except for phrases sharing one action, such as Silent/Silence or Switch/Open. Restore built-in returns to the shipped dictionary. Editing a phrase disables its dictionary controls and keeps any saved dictionary dormant until you restore that default phrase.

Microphone and speaker commands send their configured Codex toggle once, without reading buttons, changing focus or waiting for confirmation. This works when another chat is selected. The app reports the shortcut as sent; the audio state remains unverified. Mute and Unmute send the same microphone toggle. Silence and Unsilence send the same speaker toggle. These commands do not start a call.

When Hello Chat starts a new call, it saves the locally recognised words heard after the wake while Voice was connecting in `~/Library/Application Support/HelloChat/VoiceStartup/pending.json`. On normal app startup, Hello Chat installs or updates its own `hello-chat-voice-startup` skill in the configured Codex skills directory (`~/.codex/skills` by default). The installed skill comes directly from the bundled [Voice startup instructions](Resources/VoiceStartup.md), which remain the single source of truth. It leaves unrelated skills and conflicting user-managed content untouched.

This temporary startup file is independent of Save transcripts. A new local Voice coordinator can read and clear the file through that skill, then say “I'm reading the start of your request from H Chat.” Recognition keeps extending the opening utterance after the Voice window opens. An early reader gets `capturing` with a provisional snapshot of the words recognised so far, labelled incomplete and left intact. The first coordinator to read owns the request. The request becomes ready at the recognizer's utterance end, or once Voice has opened, after some opening words beyond repeated wake greetings arrive and stay unchanged for 2 seconds, or at most 30 seconds of audio. Stability, limit and interrupted cutoffs are marked potentially incomplete. It never becomes ready at window confirmation alone. A recognizer context reset doesn't end the opening. Hello Chat's microphone has no echo cancellation, so on speakers this local text can still include the assistant's own reply if it starts within that pause. It does not paste, switch chats or press Return. The file is private, bounded, separate from transcript backups and replaced at the next new-call start. A reused call publishes nothing. A call started with the button captures new words after the button press. The startup reader merges any overlap with native Voice instead of treating it as a second request. This read needs a Codex work turn: installing the skill does not make the conversational Voice model wait for the file before its first reply.

Words within either command must be close together: no gap over 1.5 seconds, and a two-word phrase must fit within 3 seconds. Longer custom phrases have a proportionally larger total window. The app uses local model audio timestamps where available, with first-observed word times as a fallback. This does not limit the length of a Voice conversation or add a delay after a valid command.

By default, the listening toggle controls listening without requiring power or an external display. Its On/Off choice is remembered when the app restarts. Automatic Listening is optional; existing saved docking preferences are preserved.

Wake and end phrases keep working while Agent Flow is recording, using the same phrase-matching rules as normal listening.

If Core ML fails during recognition or a model reload, Hello Chat tries up to three local restarts without ending Codex Voice. After repeated failures it stops reloading until a power/display change, system wake or manual restart gives it another chance. Automatic listening still waits two minutes after docking. A Core ML operation already in progress must return before its model can be safely replaced.

The menu bar has **Start listening** / **Stop listening** and the same Voice controls. **Settings…** (⌘,) has:

| Section | Contents |
| --- | --- |
| Notification Replies | Optional spoken replies after Codex notifications. Edit the **Reply** and **End reply** spellings here. **Enabled**, **Cancel after silence (seconds)** and **Maximum reply (seconds)** use the existing speech model and microphone. |
| Automatic Listening | **Listen automatically when docked**, off by default. Starts listening 2 minutes after connecting power and an external display. Unplug either to stop automatic listening. Turning listening on yourself works with any display setup and stays on across restarts. |
| Recognition | **Alternate spellings for default phrases** and **Check speech recognition**. Phrase and microphone editors are on Home. |
| Resources | Hello Chat's own CPU and memory, and Core ML's estimated encoder placement. |
| Sounds | **Sound effects** (on by default), **Volume**, and a preview button for each phrase's short sound. Volume changes only H Chat's cues. |
| Spotify | **Lower volume during chat**, off by default. Requires permission to control Spotify. |
| Transcript Archive | **Save transcripts** (on by default), the archive location, and this Mac’s optional backup configuration. |
| Updates | **Check for Updates…**, automatic checking and automatic downloads on release-configured builds. |
| Diagnostics | Timing, errors and startup request/revision metadata, which exclude recognised words. |
| Appearance | **Bring Home forward when a phrase is heard** is on by default. Detected commands raise Home without taking keyboard focus from the app you’re using. **Open H Chat windows on** remembers your display choice and uses an available display when disconnected. Zoom starts at 100%. **View → Zoom In / Zoom Out / Actual Size** works too. |

## Notification replies

Enable **Settings → Notification Replies** with the shared Codex notification-speech integration installed. After a notification finishes, say **Reply** within two seconds, then speak your answer. Say **End reply** to send it to the exact chat that produced the notification. Pauses keep listening; the safety limits cancel without sending. The compact floating display streams the reply words and keeps the complete original notification in a scroll area. Short content fits without filling the maximum height. Drag its header to move it, or use its close button to cancel an unsent reply. Last command keeps the outcome. Queue acceptance is separate from a reply appearing in that chat.

Edit the notification controls’ alternate spellings in the same Settings section. **And reply** is a built-in alternate for **End reply**. An empty spelling list keeps only the main phrase; **Recognize alternate spellings** applies to these controls too. A send spelling must finish the command: ordinary wording such as “read that and reply tomorrow” stays in the answer.

This uses H Chat's existing microphone and selected local speech model. It adds no second recognizer and saves no audio. Codex Voice, manual Agent Flow recording, disabled listening and newer input in the original chat cancel an unsent reply. The reply body cannot execute ambient H Chat commands. The ordinary Save transcripts preference still applies to the shared listener.

The app reads the exact originating chat's saved user-message boundary and optional open-question state to reject stale replies, then sends once through the running Codex Desktop's supported `queue --thread` command. It never pastes into the foreground or resumes a second writer. The shared notification integration keeps its own speech provider, voice, queue and media ownership. See the [app/client contract](docs/notification-replies.md) for installation and verification boundaries.

## Spotify volume during chat

Enable **Settings → Spotify → Lower volume during chat** to cap Spotify's own slider at 50% while a native call is on. A quieter setting stays quieter. **Allow Spotify control** requests macOS Automation permission; Spotify must already be open. This never starts playback or changes the Mac's output volume.

With Lower volume during chat enabled and a known active call, the microphone mute phrase still restores your previous Spotify volume, and the unmute phrase reapplies the cap. This follows the requested phrase direction, not a readback of Codex's microphone. Repeated phrases toggle Codex again while keeping the requested Spotify volume behavior. Manual slider protection and call-end restoration remain unchanged.

Say **Spotify volume** followed by a number from 0 to 100 to set Spotify directly, even when automatic lowering is off. Spotify must already be running. The phrase has its own settings gear on Home. Spoken values can be corrected as transcription completes a number; no extra wait for silence is added. This deliberate choice survives the current call ending and leaves your saved Maximum volume unchanged.

The original slider value is saved privately before it changes and restored after confirmed call end. If you change the slider yourself, that value wins for that call. Saved call identifiers keep a previous call's override from following you into a fresh call, including when End and Start happen between checks. Normal Hello Chat Quit restores immediately without ending the Codex call; an updater carries the saved value into the replacement app. After a crash, the next launch uses that receipt to recover. A helper that is no longer running cannot restore at a later call end.

Detection uses native Accessibility notifications and fresh call controls, including calls started or stopped directly in Codex and temporary chats. Saved call-boundary metadata is supplementary evidence during reconnects; Hello Chat does not subscribe to Codex's private server, read transcripts, or write its database. Incomplete control reads remain unknown. The private metadata format and UI can change across Codex versions; live manual-end and temporary-chat acceptance must be checked against the installed version.

## Paired Macs and Codex Voice

H Chat can keep one Codex Voice call when two paired Macs have active calls. Either Mac can detect the overlap, including calls opened directly in Codex or already active when H Chat starts. Configure opposite roles and the exact names the Macs use to reach each other in Agent Bridge. Leave both unconfigured for independent calls.

```sh
# On the Mac that normally keeps its call
defaults write com.ethansk.HeyChat voicePeerPriority -dict machine '<secondary bridge name>' role primary
# On the Mac that has priority during the optional scheduled hours
defaults write com.ethansk.HeyChat voicePeerPriority -dict machine '<primary bridge name>' role secondary
```

Both machines need H Chat running from `/Applications/HelloChat.app` with Accessibility access and [Agent Bridge](https://github.com/EthanSK/agent-bridge) at `~/bin/agent-bridge`. Install Agent Bridge separately and restart H Chat after configuring the pair. A single call works on either Mac. When both calls are verified, H Chat uses the native End control for the losing session. Its chat and work stay open.

For daily priority, add the same integer `secondaryStartHour` and `secondaryEndHour` (0–23) and named `timeZone` to each Mac's `voicePeerPriority` dictionary. With `2`, `11` and `Europe/London`, the secondary keeps its call from 02:00 until 11:00 UK time. The primary keeps its call from 11:00 until 02:00, or all day when the pair has no schedule.

The primary records the local time when H Chat first resolves each verified overlap. Either call can have started first or been running for hours. Both Macs use the same decision through delayed replies, retries and clock changes. If a peer check fails, H Chat checks again while the call remains active. Update both apps together. Automatic handoff requires matching protocol versions and schedules.

For read-only diagnosis, run `/Applications/HelloChat.app/Contents/MacOS/HelloChat --voice-peer-status` locally or over the paired bridge. The command returns a status and, when verified, the current thread and session identifiers. To remove the pairing, delete the `voicePeerPriority` preference on both Macs and restart H Chat.

## Updates

Release-configured builds use Sparkle 2.10.1. **Check for Updates…** is in the app menu and Settings. Automatic checks/downloads use Sparkle’s saved preferences; the app does not overwrite your choices on launch. Updates are signed with Ed25519, as well as the app’s Developer ID signature.

A requested update waits for Hello Chat's own in-flight actions and speech checks before relaunching. An active Codex Voice call or Agent Flow recording does not block the update. Normal Quit and update cleanup detach from Codex without ending its call. Source builds retain the public update key and feed by default and can update to a newer public release. A change from an ad-hoc signature to the public Developer ID may require Microphone or Accessibility permission again. Builds with that key deliberately removed leave update controls disabled. See [release setup and verification](RELEASE.md).

### Microphone and Voice audio shortcuts

Missing microphone and Voice audio bindings use Command–Control–Shift–M and Command–Control–Shift–O, respectively. Existing custom bindings are preserved. Mute and Unmute use the microphone shortcut; Silent, Silence and Unsilence use the Voice audio shortcut. Shortcuts saved while Codex is running may still need applying in its native Keyboard shortcuts settings or a later restart. A saved key alone does not confirm live registration.

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
- **Codex controls and call monitoring**: Hello Chat reads Codex's shortcuts in `~/.codex/keybindings.json` and fills missing Voice control bindings, preserving custom choices. It inspects native call controls for commands and, while sound effects, Spotify control or paired-Mac priority are enabled, observes call changes and reads saved call-start/end metadata. This supports the End cue when a call closes directly in Codex. It does not read conversation text or subscribe to a private server. Disable all three optional features to stop background call monitoring. Startup speech is handed to the local Voice skill through the private file above; Hello Chat does not navigate to a chat or submit a message. Start uses the global native shortcut without first activating Codex. The conversation, its audio, network connection and sign-in all belong to Codex.
- **Optional Spotify control**: when enabled, native window/control notifications trigger read-only call checks in the background. Hello Chat also reads only saved call-start/end metadata from Codex's local timeline. Its private `SpotifyVolume/restore.json` receipt stores the original/applied volume values and an opaque call identifier. macOS Automation permission permits Spotify volume access; tracks and library contents are not read.
- **Optional notification replies**: separately reads the specified chat's saved message boundary and open-question state, then sends the completed spoken reply only to that chat. Private status files contain no speech text. The existing transcript-saving choice still applies. This feature requires the shared notification-speech integration and is off by default for new installations.

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
- An End button can appear before Voice connects. Hello Chat waits for the microphone control or corroborating activity before confirming the call. If confirmation times out, it reports that and leaves any pending Codex call alone.
- An existing muted call is unmuted through its configured microphone shortcut after checking its current state.
- Start requires an unlocked, active macOS desktop. A wake heard while locked is not queued for later. After unlocking, say the wake phrase again; old recognition and pending opening state are cleared without ending an existing call.
- **End** sends the dedicated `realtimeVoice.endCall` shortcut after a fresh Voice-control check. A retry presses the exact End control itself. If closure cannot be confirmed, Hello Chat says the status is unknown instead of claiming the End action failed.
- Shortcut writes are marked as saved, not proof of live registration. If Hello Chat adds bindings while Codex is running, it shows a restart message. Voice confirmation still depends on the actual call controls.
- **Prepare GPT-6.2 Sol, High and Ultrafast** temporarily selects those defaults when H Chat opens a new Voice chat. H Chat then restores the previous values. An already-running Codex window can reuse its own cached selection. The setting prepares the launch and the first agent turn records which choices took effect.

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

## Maintaining the Website

The Website workflow regenerates the command and Settings tables from README and renders the icon/preview artwork before every Pages deployment. README-only changes update the site automatically without building the app or downloading speech models. The checked-in HTML is a generated preview, not a second editable reference.

The static GitHub Pages site lives in `docs/`. The command and Settings references are generated from this README by `scripts/prepare-site.py`; do not edit those marked HTML blocks separately. After changing these tables, CSS, JavaScript, or the app icon, run `python3 scripts/prepare-site.py` on macOS to regenerate the sharing image and content-derived asset cache keys. `python3 scripts/prepare-site.py --check` verifies freshness without changing files. The Website workflow runs it after generation; the general test suite checks the generator itself without requiring the committed preview to be current.


## License

Source-available under [Apache License 2.0 with Commons Clause v1.0](LICENSE). You may use and modify the covered software, including internally at work, and redistribute it under these terms. Commons Clause restricts selling products or services whose value derives entirely or substantially from the software's functionality; it does not prohibit every commercial use. Earlier licenses and third-party rights remain in force. FluidAudio uses Apache 2.0, and the Parakeet and Nemotron models use the NVIDIA Open Model License; see [third-party notices](Resources/THIRD-PARTY-NOTICES.txt) and [scope and release policy](LICENSING.md). Hello Chat is not affiliated with OpenAI; Codex and ChatGPT belong to OpenAI.
