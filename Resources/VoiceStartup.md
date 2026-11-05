# H Chat startup speech

Use this only at the startup of an actual new local Codex Voice coordinator, after its normal self-pinning. Do not consume this mailbox from an ordinary text chat, a subagent, a maintenance task, or an already-running unrelated call.

This runs on the Voice agent's first tool-capable handoff. It does not force the frontend to delegate a turn merely because the audio connection opened; if Codex supplies no handoff, the file remains unread until it does.

H Chat writes locally recognized words spoken after the accepted wake while the native call opens to:

`~/Library/Application Support/HelloChat/VoiceStartup/pending.json`

This replaces text delivery by bringing Codex forward, switching chats, or pasting. Keep native Start/End controls separate. H Chat uses the existing microphone/model; no extra audio recorder or transcription service is involved.

1. Resolve this Voice coordinator's exact thread ID and `createdAt` Unix timestamp with the supported chat metadata tool (`read_thread` in Codex). Do not substitute the newest chat or the current wall-clock time. If that metadata is unavailable, leave the mailbox untouched and report the handoff as unverified.
2. Run the installed app's consumer, substituting those two verified metadata values:

   ```sh
   /Applications/HelloChat.app/Contents/MacOS/HelloChat --consume-startup-speech --voice-thread-id THREAD_UUID --voice-created-at UNIX_SECONDS
   ```

3. On `status: "speech"`, read `request.text` as the beginning of the user's current request. Say **“I'm reading the start of your request from H Chat.”** Then address it together with the live request. Local recognition can include background speech or spelling errors. It may overlap what Voice heard: merge that overlap and perform each requested action once. If `truncated` is true, treat it as a partial beginning, not a complete request.
4. The consumer atomically clears the speech and leaves a small consumed receipt. Do not delete or edit the file yourself: a queued recognizer update must not resurrect it, and an old reader must not delete the next request. H Chat replaces it at the next actual new-call Start. A reused existing call does not publish a new startup request; explicit End/cancel clears the producer's pending speech.
5. `empty` or `unrelated` means continue normally without announcing a handoff. `capturing` means no words have arrived yet: check once more before answering the first substantive request, rather than polling or sleeping. On `busy`, one immediate retry may resolve the actual file transaction; otherwise leave the handoff unverified and continue the live conversation. `unavailable` is a file/format error: report it briefly without guessing the missing words or falling back to UI paste.

The reader matches the request time to this newly created coordinator (up to 30 seconds before its creation, or two seconds after it for timestamp precision). This is a single latest-start mailbox, not desktop call addressing. Never claim it proves which session produced ambiguous concurrent manual calls. Speech remains private on this Mac until the Voice agent reads it; this temporary mailbox is separate from the transcript archive and its backup.
