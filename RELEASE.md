# Releasing HelloChat

Every push to `main` starts the Release workflow on a dedicated Apple Silicon signing runner. The job tests, builds, verifies the Developer ID signature and microphone entitlement, notarises and staples the app, signs the final ZIP for Sparkle, and publishes a new immutable release. No signing private key is exported to GitHub.

## One-time signing runner setup

Use the GitHub repository’s Actions → Runners setup for an official macOS ARM64 runner. Add the `hello-chat-release` label and run it in the signing user’s logged-in macOS session. Keep its work/temp directories on suitable scratch storage. This workflow runs only for trusted main pushes and manual dispatches, never pull requests from forks.

Keep the runner's work-folder path free of spaces; a space-free symlink to scratch storage also works. The runner can otherwise split its generated shell-script path before the script runs. Verify the resolved storage destination before a release.

For a LaunchAgent signing runner, set `SessionCreate` to `false` so it shares the logged-in user's security session, then reload only that idle runner. If `notarytool history` succeeds interactively but reports `keychainLocked` in the job, check this session setting before asking for another unlock. Do not copy signing credentials or store the login password in a workflow to work around that difference. Require the workflow's signing-access check to pass.

The signing user must have:

- Developer ID Application identity from team `T34G959ZG8`, accessible to `codesign`.
- An existing working `notarytool` profile. Set repository variable `HELLOCHAT_NOTARY_PROFILE` to its name; the default is `HelloChatRelease`.
- A Sparkle signing key in Keychain account `com.ethansk.HelloChat`.
- The existing EthanSK GitHub CLI login in Keychain, with `repo` and `workflow` scopes. Only publication removes the job-token overrides and verifies this account; it never prints or exports the credential. This preserves the exact verified source if workflow files on main change during the build.

The signing host also needs the shared Sparkle 2.10.1 tools at `~/.local/share/sparkle-tools/2.10.1/bin`. During host setup, copy `bin` from the checksum-verified archive pinned in `.github/workflows/release.yml` to that location, preserving its executable permissions and signatures. Every release still verifies a fresh archive and compares all tool bytes before using this persistent copy. Apps keep separate Keychain accounts and public-key checks; this reuses a tool location, not private keys or permissions. Provision a new version separately when upgrading Sparkle; changed tool identities may require fresh macOS consent.

Use the verified Sparkle distribution’s `generate_keys --account com.ethansk.HelloChat` once. It saves the private key in Keychain and prints the public key. Add only that public value as `SUPublicEDKey` in `Info.plist`. Never use its private-key export option. The workflow checks that the stored key matches the app before building.

An offline runner, locked keychain, missing public key or rejected notarisation blocks publication. A configured workflow alone is not an operational release pipeline. The signing Mac must remain awake and connected while a release runs; locking the screen and putting the Mac to sleep are different states.

## Version ownership

`Info.plist` owns the requested major/minor version baseline. The serialized release job selects the next public patch above existing releases, starting with `1.0.0`. It assigns a build above both the workflow counter offset and the last published build. The generated `release-manifest.json` records the source commit, version and build; it is an immutable receipt, not another editable configuration file.

Do not bump a second version file or commit generated release metadata back to main. Do not replace published tags/assets. A retry or later push must still produce a build newer than the one offered to installed clients.

## Verify a public release

1. Require a successful Release workflow and an online runner with the required label.
2. Download the exact release’s ZIP, appcast and checksums. Run `shasum -a 256 -c SHA256SUMS`.
3. Extract and verify `codesign --verify --deep --strict HelloChat.app`, `xcrun stapler validate HelloChat.app`, and `spctl --assess --type execute --verbose=2 HelloChat.app`.
4. From an older installed build, check that Sparkle finds the newer version, downloads it, validates its signature and relaunches into that exact build. Verify preferences, startup configuration, microphone permission and Accessibility permission remain intact.
5. Keep real microphone/Voice acceptance separate from fixture and transport tests. Never automate live Codex calls to test a release.

For a change to Voice behavior, check both the ChatGPT and Codex presentations of the same desktop app. First use fixtures for the affected Start, existing-call, End, cancellation, and unavailable-Voice cases. Then obtain user-operated live acceptance in each supported presentation, without ending an existing call to make room for a test. Preserve custom bindings, keyboard layout, the complete modifier combination, and the chosen presentation. Record a native availability or registration blocker explicitly; a passing fixture or a working call in one presentation does not establish the other.

The public download is `https://github.com/EthanSK/hello-chat/releases/latest`. Sparkle reads the latest release’s `appcast.xml` asset. That feed points to the exact immutable version ZIP and contains its Ed25519 signature and length.

## Package on the signing Mac

```sh
zsh scripts/test.sh
zsh scripts/build.sh
HELLOCHAT_NOTARY_PROFILE=your-existing-profile \
HELLOCHAT_SPARKLE_TOOLS=/path/to/verified/Sparkle/bin \
zsh scripts/package-release.sh
```

Both scripts use `HELLOCHAT_BUILD_DIR` when set. Packaging accepts only the original bundle identity, expected team, arm64 executable, hardened runtime and microphone entitlement. The archive is recreated after stapling and only those final bytes are signed for Sparkle. The app’s updater postpones its relaunch only during its own in-flight actions or speech checks. External Codex Voice calls and Agent Flow recordings do not block it; detach and file flushing preserve those sessions. Pending-only rechecks resume installation without requiring app focus. An abort after preparation restores local listening according to current saved settings. A matching installed startup job retains ownership after the update.
