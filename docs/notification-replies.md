# Notification replies owned by H Chat

H Chat owns the selected speech listener, microphone, recognition model, finite reply session,
floating feedback, settings, stale-origin checks and single Desktop queue dispatch. The shared
notification-speech skill owns synthesis, its FIFO turn, and any media pause it made. Its client
only connects the existing speaker to this app contract. It starts no recognizer or microphone.

## Version 1 handoff

Use the existing signed app's `--agent-control-v1` JSON-stdin connection. Read capabilities first.
The normal control envelope, request UUID, expiry, response correlation and no-replay policy apply.
Each valid notification lifecycle callback returns `state:confirmed` with its authoritative event
snapshot. This confirms the app applied/read that transition, not physical playback or chat arrival.
The snapshot phase retains preparing/releasing/queued/delivered distinctions. A generic deferred
`accepted` receipt without a confirmed event snapshot is not a successful notification callback.
The protocol below is the notification feature, not the new-Voice startup speech mailbox.

Read the installed integer `HChatNotificationReplyProtocol` (1) as well as the generic control
protocol. Never start the app from the hook. Missing app/protocol returns unavailable and preserves
ordinary speech. All operations after prepare also require the returned `instance` UUID.
If prepare's response is lost and no audioStarted arrives, the app cancels that unsent attempt and
closes its feedback after ten seconds; it does not leave an abandoned microphone session or HUD.
The instance-bound client acknowledges ownership through its existing one-second status polling.
During preparing, each valid status call renews a ten-second liveness lease, within a hard
180-second setup bound. This permits the existing speaker's bounded rendering/bridge startup
without moving the spoken opportunity: that still begins at the actual successful audio exit.

Operations, all scoped to one notification UUID:

- `notificationReply.prepare`: `eventID`, `threadID`, `turnID`, `questionID`, `spokenText`.
  IDs are strings; optional turn/question IDs use an empty string. The thread UUID is mandatory.
  H Chat captures the exact origin's new-user-message boundary and validates an open question.
  It returns its authoritative settings, maximum post-audio hold, current disposition, app-instance
  token, and a private status-file path. An unavailable reply attempt must not fail ordinary TTS.
- `notificationReply.audioStarted`: `eventID`, `startedUptime`, `startedWall` from the actual
  parked audio child's admission/unpark, not synthesis completion or process launch. This is not
  verified physical speaker/DAC onset; command opportunity is anchored to actual child exit below.
- `notificationReply.audioEnded`: `eventID`, `endedUptime`, `endedWall`, `completed` from that
  same audio child's exit. A failed, stale or discontinuous-clock exit cancels without sending.
  The spoken command must start in the following two seconds. Recognition can arrive later;
  H Chat uses the captured audio/word timeline and bounded recognition confirmation.
- `notificationReply.cancel`: `eventID`, `reason`. Idempotent cancellation never sends.
- `notificationReply.mediaReleased`: `eventID`, `released`. Call only after the original speaker
  has actually completed its balanced media/FIFO cleanup. A false/unknown release cancels.
  This acknowledges release; it is not permission to submit arbitrary text. Only an app-owned,
  nonempty capture finished by End reply can proceed to dispatch.
- `notificationReply.status`: `eventID`. Metadata only; no recognized reply body.

The private status file is an app-published view, not another settings store or command input.
It contains protocol version, event/thread/instance identity, phase, reason and `releaseRequested`;
it never contains notification or reply text. The client watches it to release its existing hold
once. The status path and limits come from prepare; do not maintain independent capture settings.

When release is requested, the thin client writes the existing speaker's release receipt once.
After the speaker exits and its cleanup is complete AND the original FIFO turn has been finalized,
the client sends mediaReleased once. The existing speech hook's finish callback is inside that FIFO
turn, so finish alone cannot acknowledge release. Register the acknowledgement with the existing
FIFO finalizer. A forced kill or a still-live original child cannot report released:true. H Chat
then revalidates origin, question, desktop and recording/call priority immediately before reserving
one dispatch through the running Desktop's supported `codex queue --thread`. Unknown submission
is never retried. Queue acceptance is reported as queued, not proof of arrival. Exact-chat arrival
is checked separately against the originating chat's subsequent saved event.

H Chat admits at most one listening/composing notification at a time. After its decision, it freezes
the old event's body/origin and stops feeding it speech; the old event may await release acknowledgement
while the next FIFO owner's prepare is admitted. The new attempt cannot overwrite the old event's
token, body, status or dispatch reservation. This small pending-delivery record is not another listener.
Thus an acknowledgement racing the next prepare after FIFO unlock does not lose either event.
The acknowledgement establishes cleanup completion, not proof that playback audibly resumed.

The prepare response's normal control `result` contains `protocolVersion:1`, `eventID`, `threadID`,
`instance`, `statusFile`, `phase`, `reason`, `releaseRequested`, `maxSetupSeconds`,
`maxAnnouncementSeconds`, `maxHoldSeconds`, and `limits`.
Setup is bounded by the app's 180 seconds, announcement playback by 45 seconds from audio start,
and the existing post-audio hold from actual audio exit. The metadata worker and feature-enabled
speaker parent use the sum of these returned allowances; the ordinary no-feature speaker keeps
its existing deadline. A late valid setup/announcement cannot shorten the permitted reply.
`limits` contains `commandSeconds`, `idleSeconds`, `replySeconds`, `confirmationSeconds`,
`commandDrainSeconds`, and `maxHoldSeconds`, plus `endConfirmationSeconds` for native End finalization.
Initial confirmation stays 1.5 seconds and initial drain 2.1 seconds; only End has a 3.5-second
confirmation allowance for Nemotron's existing two-second quiet boundary plus decoding. The maximum
hold is 191.6 seconds with a 180-second reply. These are read from the app, not settings imported
from the temporarily disabled standalone pilot. The corresponding status result/file repeats the
identity and phase/reason/releaseRequested fields. Status never returns captured text.

## Recognition and lifecycle

H Chat's current SpeechListener supplies both commands and reply text. Existing model and input
choices are unchanged. Disabled listening is unavailable, not silently enabled. Codex Voice and
manual Agent Flow capture take priority; they cancel only the notification reply, leaving ordinary
H Chat commands available. During an admitted finite attempt, its speech is consumed before ambient
command matching, so a dictated reply cannot launch apps, switch audio or start/end a call.

Reply starts composition; End reply is the only normal send. Pauses never submit. Defaults are
60 seconds without recognized speech and 120 seconds of reply, with a configurable maximum of
180 seconds. No command, empty content, cancellation, stale origin, listener failure or a safety
limit sends nothing. Remove only the timed control words, preserving a genuine body-leading reply.

Native nonactivating feedback is visible throughout preparation, announcement, waiting and
composition on every display/Space. The exact original spoken text remains visible while composing.
The native header can be dragged without taking keyboard focus. Each display remembers its own
position; phase/text updates preserve that placement. Original text scrolls inside a compact panel
instead of growing across the working screen. The visible close control cancels an unsent attempt
and releases its hold, hiding every panel for that event; it cannot retract a queued message.
Cancelled/unavailable feedback clears after three seconds, with its outcome retained in Last command.
Display-only previews are confined to the built-in display and clear every owned panel on window
close or their finite expiry. They start no recognizer, microphone, audio or queue message.
Only accepted Reply plays the quiet cue. Closing H Chat cancels unsent work and releases the existing
speaker's hold; it never ends an external Voice call or stops Agent Flow.

## Reuse and verification boundary

The earlier `speak-action-reminder/reply-companion/handsfree_core.py`, `reply_context.py` and
`handsfree_reply.py` provide command-time, stale-origin and exact-target delivery behavior to preserve.
The H Chat integration replaces their standalone capture/command recognizer and cloud transcription.
Old tests and HUD screenshots are historical evidence, not verification of this new shared pipeline.
