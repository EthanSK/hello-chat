---
name: hello-chat-voice-startup
description: Read H Chat's pending startup speech only when a new actual local Voice coordinator starts, after its normal self-pinning. Do not use for text chats, dictation, maintenance, subagents, or an existing Voice call.
---

# H Chat startup speech

H Chat owns this skill and installs it from its bundled `VoiceStartup.md`. Keep that file as the single source of truth. Preserve useful corrections in the H Chat project for a future app update; do not edit this installed copy or change unrelated personal skills. Follow the host's skill-use announcement rules.

Use this only at the startup of an actual new local Codex Voice coordinator, after its normal self-pinning. Do not consume this mailbox from an ordinary text chat, a subagent, a maintenance task, or an already-running unrelated call.

This runs on the Voice agent's first tool-capable handoff. It does not force the frontend to delegate a turn merely because the audio connection opened, and it cannot give the native Voice frontend's earlier replies these words; if Codex supplies no handoff, the file remains unread until it does.

H Chat writes locally recognized words spoken after the accepted wake while the native call opens to:

`~/Library/Application Support/HelloChat/VoiceStartup/pending.json`

This replaces text delivery by bringing Codex forward, switching chats, or pasting. Keep native Start/End controls separate. H Chat uses the existing microphone/model; no extra audio recorder or transcription service is involved.

1. Resolve this Voice coordinator's exact thread ID and `createdAt` Unix timestamp with the supported chat metadata tool (`read_thread` in Codex). Do not substitute the newest chat or the current wall-clock time. If that metadata is unavailable, leave the mailbox untouched and report the handoff as unverified.
2. Run the installed app's consumer, substituting those two verified metadata values:

   ```sh
   /Applications/HelloChat.app/Contents/MacOS/HelloChat --consume-startup-speech --voice-thread-id THREAD_UUID --voice-created-at UNIX_SECONDS
   ```

3. Act on `status`:
   - `capturing`: H Chat is still recognizing the opening. When `request` is present, `request.text` is a provisional snapshot of what it has heard so far. This read does not consume it, and its last words may still change or continue. You may use it to understand and start answering, but call it what H Chat has heard so far, never the complete request. Don't take an irreversible or externally visible action based only on provisional words unless the live conversation confirms it.
   - `speech`: the final captured prefix. This read consumed it; final capture does not necessarily mean the user finished speaking. `request.boundary` says why capture ended: `utterance` is the recognizer's end signal. `pause` means the text stayed unchanged for 2 seconds; it can still be an unfinished sentence. `limit` is the 30-second bound after Voice opened, and `interrupted` means listening stopped, a new wake started, or the consumer finished a capture abandoned by a stopped app. With `pause`, `limit` or `interrupted`, `truncated` is true because the end may be missing. Older H Chat builds omit `boundary`. Merge a partial prefix with the live conversation rather than inventing its missing end.
   - `empty` or `unrelated`: continue normally without announcing a handoff. An empty consumed receipt cannot recover cleared words.
   - `claimed`: another coordinator read this request first and owns it. Continue normally without announcing a handoff.
   - `busy`: one immediate retry may resolve the actual file transaction; otherwise leave the handoff unverified and continue the live conversation.
   - `unavailable`: a file/format error. Report it briefly without guessing the missing words or falling back to UI paste.
4. Treat `request.text` as the beginning of the user's current request and address it together with the live request. Say **“I'm reading the start of your request from H Chat.”** only the first time you receive text for a `request.id`. Every read of the same opening returns the same `request.id`; `request.revision` changes when its text changes. Treat later text for an id you've already seen as a revised version of the same opening. Merge it, act only on new or corrected content, and never repeat an action you've already taken or announced. Local recognition can include background speech or spelling errors and may overlap what Voice heard: merge that overlap and perform each requested action once. H Chat's microphone has no echo cancellation, so on speakers its text can include your own spoken replies or later conversation. Never treat words matching what you or the native Voice already said as a new request from the user.
5. Before the first substantive reply, check again even if an earlier read returned words. After `capturing`, check again on each later tool-capable turn of this coordinator until you receive a final status (`speech`, `empty`, `unrelated` or `claimed`). Don't sleep or poll in a loop. Once Voice has opened and some opening words beyond repeated wake greetings exist, H Chat finishes capture after 2 seconds without new recognized opening words, or after at most 30 seconds of audio even if no words arrive. A repeated wake greeting alone is not a finished request. A capture still unfinished 2 minutes after its request is considered stale; the next read delivers it as `interrupted`. Do not claim complete context while the status is `capturing` or `truncated` is true.
6. The final consumer read atomically clears the speech and leaves a small consumed receipt. Do not delete or edit the file yourself: a queued recognizer update must not resurrect it, and an old reader must not delete the next request. H Chat replaces it at the next actual new-call Start. A reused existing call does not publish a new startup request; explicit End/cancel clears the producer's pending speech.

The reader matches the request time to this newly created coordinator (up to 30 seconds before its creation, or two seconds after it for timestamp precision). This is a single latest-start mailbox, not desktop call addressing. Never claim it proves which session produced ambiguous concurrent manual calls. Speech remains private on this Mac until the Voice agent reads it; this temporary mailbox is separate from the transcript archive and its backup.
