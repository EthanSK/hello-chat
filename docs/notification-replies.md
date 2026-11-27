# Notification replies owned by H Chat

H Chat owns the selected speech listener, microphone, recognition model, finite reply session,
floating feedback, settings, stale-origin checks and single exact-origin relay delivery. The shared
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

New clients opt into `manualFinish:true` only when their calling queue and all existing watchdogs
support the app-owned composing lease. Missing/false retains the legacy bounded reply policy.
The app echoes `manualFinish`, `ownerLeaseSeconds:10` and `ownerLeaseExpiresUptime` (null outside
manual composition). A genuine timely initial Reply remains visibly confirming through its real
native final decode. Once accepted, ordinary pauses and the legacy idle/total values do not end
manual capture: End reply sends; Cancel reply discards. These controls use the same selected
recognizer, native timed-prefix confirmation and shared spelling editor. The original exact
notification reference remains in every displayed phase, with End/Cancel hints after Reply starts.

The existing instance-bound status requests renew one app lease, never beyond current uptime+10.
The app checks expiry BEFORE renewal; a late call or cached receipt cannot revive an attempt.
The client relays only confirmed exact-event/instance status into its private owner-lease file.
Native hold, metadata watch, visual join and speaker parent consume that same expiry, replacing
the old fixed deadline only after manual composing is observed. Missing owner renewal, genuine
recognition loss, Voice priority, disabled listening, stale origin or dismissal still cancels.
No new listener/poller is introduced. End/Cancel/guard decisions stop renewal and get one finite
seven-second cleanup allowance from that first decision, followed by actual FIFO finalization.
Legacy/no-feature deadlines and the finite five-second initial opportunity stay unchanged.

Clients may also opt into `stopSpeaking:true` when the app advertises that optional Boolean and
the calling queue, client and native speaker all support the exact-instance stop receipt. The first
supported client requires negotiated manual composition as well, so an old speaker cannot promise
a stop it cannot perform. Missing/false leaves ordinary speech unchanged. Snapshots echo the flag.
Only an actually announcing attempt accepts the configured Shut up form through the existing
timed, native-confirmed listener. It cancels unsent with `user-stop-speaking`: no new Reply window,
fallback, send or navigation. Partial recognition requests the existing native final without a
post-command quiet wait. Negated, mentioned, quoted and revised-away controls are refused. If the
original notification contains that exact form, it is conservatively ignored because recognition
cannot distinguish a human repetition from the announcement. Other configured forms remain usable.

The existing private app status carries the exact event/instance and this explicit reason.
Only its negotiated native speaker checks that authoritative file during the existing playback
pump and terminates its own admitted child, even if a status IPC call is still waiting. The derived
release receipt remains the hold/cleanup signal. Generic cancellation or unavailable reply
admission never stops ordinary TTS.
The speaker then follows its existing bounded reap, balanced media cleanup and FIFO finalizer.
Its private `stoppedSpeaking` proof confirms only that cleanup; the app's terminal cancelled state
can never grant body-send permission. Physical detection and audible-stop latency need separate
acceptance evidence; a requested stop alone is not proof that playback stopped.

Operations, all scoped to one notification UUID:

- `notificationReply.prepare`: `eventID`, `threadID`, `turnID`, `questionID`, `spokenText`, optional Booleans `manualFinish` and `stopSpeaking`.
  IDs are strings; optional turn/question IDs use an empty string. The thread UUID is mandatory.
  H Chat captures the exact origin's new-user-message boundary and validates an open question.
  It returns its authoritative settings, maximum post-audio hold, current disposition, app-instance
  token, and a private status-file path. An unavailable reply attempt must not fail ordinary TTS.
- `notificationReply.audioStarted`: `eventID`, `startedUptime`, `startedWall` from the actual
  parked audio child's admission/unpark, not synthesis completion or process launch. This is not
  verified physical speaker/DAC onset; command opportunity is anchored to actual child exit below.
- `notificationReply.audioEnded`: `eventID`, `endedUptime`, `endedWall`, `completed` from that
  same audio child's exit. A failed, stale or discontinuous-clock exit cancels without sending.
  The spoken command must start in the following five seconds. Recognition can arrive later;
  H Chat uses the captured audio/word timeline and bounded recognition confirmation.
- `notificationReply.fallbackReady`: `eventID`, `instance`, `deliveredUptime`, `deliveredWall`,
  `skipReason`. This optional capability opens a visual-only opportunity for intended speech that
  definitively never started. The supported classifications are `agent-flow-speech-denied`: the
  speaker's Agent Flow admission refused before any audio child launch. Initial denial happens
  before media coordination; a final refresh can instead be refused after bridge setup.
  That later route requires an explicit `refresh-before-child` stage, `audioChildLaunched:false`
  and `audioAdmitted:false` in both skip and cleanup receipts, followed by balanced cleanup
  classified as no-media, acknowledged or disconnected. It must finish media cleanup before
  opening this first fallback opportunity; the same FIFO stays held until the app's decision.
  Do not call an earlier bridge pause no-media. A parked/failed child or unknown cleanup cannot
  fall back, even if no audio-start receipt exists. After actual audio exits, the speaker balances its browser-video pause before waiting for Reply.
  The same FIFO and reply lease stay owned through End or Cancel; the final acknowledgement still
  follows actual cleanup and FIFO release.
  This classification includes unavailable recording admission; it is not proof of actual capture. `audio-unavailable-before-start` is the other eligible refusal: neither provider rendered audio, with no interruption, lease, media pause or child admission.
  A forced kill, unknown outcome, Voice refusal or started/failed audio is
  not eligible. The client must prove the exact native notification was delivered and bind its
  native ID/origin/turn/question to this event. No latest-notification lookup or banner resend.
  Both original delivery clocks must be finite, agree with the continuous app clock, and be no
  older than the existing 180-second setup bound. The current exact session must still be
  preparing, with a valid origin and no audio start or prior opportunity. After revalidation,
  the app synchronously presents Say Reply and anchors its FIRST five-second window to that
  readiness transition. An older banner timestamp is retained separately, never called fresh.
  Audio exit and visual readiness are mutually exclusive; an identical duplicate returns the
  original anchor, while conflicting facts are invalid. Cancelled/stale sessions never reopen.
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
then revalidates origin, question, desktop and Voice priority before reserving one durable event
handoff. The original three-second callback must still be valid at that reservation. The admitted
relay then owns the existing sixty-second arrival bound and gets a fresh guarded send request;
it does not reuse an expired client callback.

The app asks the documented stdio protocol for the source's authoritative first turn with
`thread/turns/list`, ascending order, then forks BEFORE that turn. It requires an ordinary,
non-ephemeral, unpinned idle fork, an independently empty turns page with no next cursor, and a
persisted metadata-only rollout after orderly creator EOF. It never copies user history or starts
a headless model turn. Goal continuation is deferred; any inherited goal is cleared ONLY on the
new owned relay and re-read absent before wake. The source goal and selected model stay unchanged.

Only a fixed broker prompt containing identifiers is queued to that temporary chat. No microphone
body is included. `codex://threads/wake/<relayUUID>` asks the running Desktop to resume that broker
without navigation, using its normal host tools. A broker queue receipt does not establish that
the target chat accepted or received the reply.

The broker must use ONE `functions.exec` orchestration with a fresh request UUID to call
`notificationReply.claimRelaySend` through the existing signed app mailbox. Required arguments are
`eventID`, `instance` and `relayThreadID`. The app rechecks the exact registered relay, final FIFO
acknowledgement, End-finished body, current Voice/readiness, lease, dismissal, desktop PID/executable,
expiry, question and newer-user boundary before disclosing a data-only exact envelope once.
A durable second claim refuses a duplicate even with a different request UUID. The result contains
`eventID`, `instance`, `relayThreadID`, `threadID`, `message` and `sendBeforeWall`. Without another
model step or intervening tool, the same exec verifies the finite deadline and calls the native
`send_message_to_thread` once, passing message as opaque data. Missing tools, refused/accepted-only
receipts, expiry and unknown outcomes cannot cause a resend or an original-queue fallback.

Saved arrival requires ONLY the expected native `response_item/function_call_output` from
`codex_app/send_message_to_thread`, the exact registered relay UUID and the complete canonically
escaped envelope's byte length/digest. Human copies, quoted markers, extra text and mixed content
remain newer input. Actual arrival can open the exact originating chat once through its existing
native deep link, bound to the same Desktop process. New input, dismissal, process replacement or
revoked readiness suppresses navigation. A navigation failure never resends or changes delivery.
Delivery may arrive between the origin agent's actions; this cannot cancel an in-flight tool or
promise zero latency.

The existing file-watcher mechanism observes the relay's matching terminal turn before archiving ONLY
that app-owned chat. A private metadata-only cleanup record permits a later app startup/prepare to
finish an interrupted archive; it contains no reply body and can never authorize a send. Failed
cleanup stays unconfirmed and never retries delivery. The broker is explicitly unpinned, silent,
has an empty final response and performs no other work. Live microphone and natural relay acceptance
remain distinct from protocol fixtures and the separately recorded synthetic host-tool proof.

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
confirmation allowance for the selected recognizer's actual native final result. Nemotron explicitly finishes its existing SDK stream between input frames; it does not wait for whole-room quiet. An unchanged timed End prefix completes before any later captured words, while changed or late results cannot send. The maximum
hold is 194.6 seconds with a 180-second reply. These are read from the app, not settings imported
from the temporarily disabled standalone pilot. The corresponding status result/file repeats the
identity and phase/reason/releaseRequested fields. Status never returns captured text.

## Recognition and lifecycle

H Chat's current SpeechListener supplies both commands and reply text. Existing model and input
choices are unchanged. Disabled listening is unavailable, not silently enabled. Codex Voice and
Agent Flow recording have separate policies. Active or unknown Codex Voice cancels only the notification reply. Agent Flow recording may continue while H Chat uses its existing selected listener for Reply; notification speech remains suppressed by the speaker’s existing guard. Ordinary H Chat commands remain available outside the bounded reply attempt. During an admitted finite attempt, its speech is consumed before ambient
command matching, so a dictated reply cannot launch apps, switch audio or start/end a call.

Reply starts composition; End reply sends and Cancel reply discards. Pauses never submit.
Negotiated manual composition stays until End/Cancel while its owner lease remains valid.
The legacy bounded route retains its saved idle/total limits. No command, empty content, cancellation, stale origin, listener failure or a safety
limit sends nothing. Remove only the timed control words, preserving a genuine body-leading reply.

Notification control spellings reuse the existing phrase dictionary store and global alternate-spelling
choice. Preparation freezes the exact configured forms for that attempt. The editing, built-in and
empty-list behavior is documented in [Notification replies](../README.md#notification-replies).

Native nonactivating feedback is visible throughout preparation, announcement, waiting and
composition on every display/Space. The live reply words derive from the same capture state and appear while composing. The exact original spoken text remains available beneath them; neither is added to metadata status files.
The native header can be dragged without taking keyboard focus. Each display remembers its own
position; phase/text updates preserve that placement. Short content fits its actual size; longer reply and original text scroll inside a compact panel
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

## Visual fallback response and cleanup

The original lifecycle callback schemas and notification protocol integer remain 1. New clients discover
`fallbackReady` before using this extension. Every event snapshot additionally exposes:

```json
{"opportunityKind":"visual","opportunityUptime":120.0,
 "visualDeliveredUptime":100.0,"visualDeliveredWall":1795500100.0}
```

The example numbers are synthetic. Before a window opens, kind is `none` and the three clocks are
null. Successful speech uses kind `audio`, its real exit as opportunityUptime, and null visual clocks.
Metadata contains no notification or reply body. The two-second wording in old receipts is historical;
current app-owned `limits.commandSeconds` is 5, with unchanged initial confirmation/drain and End-only
allowance. Settings and the visible prompt compose that same bound. Maximum hold is 194.6 seconds.

A visual-only session owns no audio child or media pause. Its explicit initial refusal receipt and
balanced `no-media` cleanup preserve the ordinary speech failure result; they do not fabricate spoken
success. The metadata client retains its original FIFO turn through the app decision, then acknowledges
`mediaReleased` only from actual FIFO finalization. All normal origin, instance, final native End,
expiry, real recognition-frame-loss, durable once-only claim and exact-chat delivery checks still apply.
No client may relax private status reads, replay a skipped notice, or launch a second listener.
