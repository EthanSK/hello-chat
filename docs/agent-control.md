# Agent control

A paired Agent Bridge client can discover and operate H Chat on the destination Mac. The signed H Chat process runs native actions in its own desktop session and applies changes to the settings its windows already use. Codex chat management has its own Agent Bridge adapter and works independently of H Chat.

## Discovery

Read the installed bundle's integer `HChatAgentControlProtocol` before invoking its executable. Version 1 accepts the single flag `--agent-control-v1` and reads one UTF-8 JSON object from standard input. The caller supplies a UUID, a Unix expiry time within the next 120 seconds, an operation name, and an arguments object.

For example, this local command asks the running desktop for its current catalogue.

```sh
python3 -c 'import json,time,uuid; print(json.dumps(dict(version=1,id=str(uuid.uuid4()),expiresAt=time.time()+10,operation="capabilities",arguments={})))' |
  /Applications/HelloChat.app/Contents/MacOS/HelloChat --agent-control-v1
```

The result contains the installed app version and the argument schema, kind and current availability for every registered operation. Conditional operations include a reason and check native state again when they run. Operation names, fields, enums and ranges come from that destination. The executable returns one JSON receipt with the same request ID. The request limit is 64 KiB and the receipt limit is 512 KiB.

## Actions and settings

- `voice.identity` returns an exact call token when the active native call can be identified. The audio, End and current-call Ultrafast operations require that token. Explicit microphone and speaker actions send the configured shortcut once. Their receipts report submission, with audio state unverified.
- A client can withdraw its pending `shortcut.start` with `voice.cancelStart`. Give the cancellation its own request UUID and supply the original Start UUID in `arguments.startRequestId`. H Chat confirms withdrawal only while that opening is still preparing. Once native shortcut dispatch begins or H Chat finds an existing call, cancellation is unavailable. After Start finishes, read `voice.identity` to select a specific call for an explicit End.
- `settings.read` returns current settings and a revision. Include that revision with each settings edit. If the desktop or another client edits the settings first, read the new snapshot before making a new request.
- Phrase rows use `main`, `new`, or a row UUID returned by the snapshot. A spelling import takes the text of the list. The receiving Mac validates the entries through the same code as the app's editor. The catalogue's restore operations reinstate the stock main phrase, built-in app and phrase spellings, speaker prefixes, and each prefix's built-in spellings.
- `listening.set` changes local recognition. Turning it off preserves an existing Voice call. `music.toggle` sends the same play/pause media key for either spoken music direction. Use `devices` and `desktop.apps` to choose known inputs, outputs, displays or app bundle IDs.
- Transcript contents require an explicit read. Use `archive.days` with an empty initial `before` cursor, select a day with `archive.list` using an empty initial `after` cursor, then supply the day and document UUID to `archive.read`. Offsets and limits are byte counts. Decode the returned base64 chunks before interpreting the assembled UTF-8 JSON document. A current document can change as recognition proceeds.
- Updater actions go through Sparkle. A restart request applies to an update that is already waiting to install. Normal Quit uses H Chat's usual call-preserving shutdown.
- The `paired.*` operations retain the separate paired Voice protocol and its existing arbitration checks. An explicit manual End uses the specific session selected by the caller.

## Receipts

| State | Meaning |
| --- | --- |
| `confirmed` | H Chat read an authoritative value or the underlying handler confirmed the requested effect. |
| `sent` | The native action was submitted. |
| `accepted` | The receiver claimed a longer operation, or the native owner accepted asynchronous work. The receipt message or corresponding status operation identifies how to check progress. |
| `conflict` | The request ID, settings revision or call identity conflicts with the current state. |
| `invalid` | The request failed schema or time validation. |
| `unavailable` | The receiver or requested capability is unavailable on that Mac. |
| `unknown` | The final effect could not be established. |

Keep the original request, including its expiry, when checking a timeout or a claimed operation. An exact replay can recover the final receipt. Reusing its UUID with different arguments is a conflict. The receiver records its claim before performing an action. After a crash, an unresolved claim stays unknown. An automatic retry with a fresh ID could toggle an already-changed control a second time.

Requests and receipts use a private per-user mailbox separate from paired Voice. Mailbox cleanup removes records older than five minutes on subsequent mailbox activity. Local macOS permissions and the receiver's interactive desktop still govern native actions.

## Offline verification

Run `scripts/test.sh` for injected action, mailbox and archive tests. Run `scripts/test-control-integration.sh` to build and exercise the real operation catalogue and settings code in a disposable preferences home. Set `HELLOCHAT_BUILD_DIR` to a task-owned build directory for either script.
