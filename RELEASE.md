# Releasing Hello Chat

Ethan’s authorized local updates follow the local-first rule in `.agents/skills/hello-chat/SKILL.md`. Review, build and install a viable locally signed batch promptly; full tests, public notarisation and publication below follow afterward unless a demonstrated local platform requirement prevents it. Preserve the signing identity, permissions, updater trust and safe detach/flush behavior. User-corrected — 2026-11-14.

Runtime changes pushed to `main` start the Release workflow on a GitHub-hosted Apple Silicon runner. Website/reference-only changes to the explicitly excluded paths do not ship an unchanged app; Pages still publishes the website. A manual dispatch remains available. Bundled resources, scripts, tests and workflow changes still trigger a release. The job tests, builds, verifies the Developer ID signature and microphone entitlement, notarises and staples the app, and signs the final ZIP for Sparkle. GitHub Actions transfers that package as an artifact, then a GitHub-hosted runner publishes the immutable release and verifies its downloadable bytes. The artifact contains only the signed public package and its release metadata. Signing private keys are provisioned separately as encrypted Actions secrets and never included in that artifact.

## Hosted signing setup

The Release workflow uses a disposable GitHub-hosted Apple Silicon Mac. It builds and tests the selected source, imports signing material into a temporary Keychain, requests Apple notarization, and publishes through the job's scoped GitHub token.

Provision these repository Actions secrets before enabling the hosted workflow:

- APPLE_CERTIFICATE_P12_BASE64 — the encoded Developer ID Application certificate with its matching private key.
- APPLE_CERTIFICATE_PASSWORD — the password protecting that exported identity.
- APPLE_ID and APPLE_TEAM_ID — the Apple account and signing team.
- APPLE_APP_SPECIFIC_PASSWORD — the labelled app-specific credential for notarization.
- SPARKLE_ED25519_PRIVATE_KEY — the existing update-signing private key matching SUPublicEDKey in Info.plist.

An Apple app-specific password authorizes notarization; the Developer ID identity signs the executable. Both are required. The workflow preserves the existing Sparkle trust identity, uses checksum-verified tools from its own temporary directory, and removes its signing material even after failure. The GitHub-hosted Mac is discarded at job completion.

A missing secret blocks the release. A successful setup step alone does not qualify the release: require successful tests, signing, notarization, publication and download verification. Recovery downloads an already-uploaded signed-release artifact from the selected run. Older packages retained only on a personal Mac are not available to hosted recovery.

[GitHub signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) describes the temporary Keychain pattern. Keep credentials out of source, logs and artifacts.

## Version ownership

`Info.plist` owns the source version and build floor. Every local signed release through `zsh scripts/build.sh` automatically advances the patch version and build above both that floor and the installed H Chat bundle. A successful signed build updates only those two source fields; a failed build leaves the source floor unchanged. No manual version flag or second version file is needed. Ordinary `swift build` compilation does not allocate a release. User-requested — 2026-11-24.

The serialized public Release job uses the same allocator, selecting the next public patch above existing releases or the newer source baseline. It assigns a build above the source floor, workflow counter offset and last published build. Its prepared tag bypasses local allocation, so CI does not increment twice. Generated `local-release-manifest.json` and public `release-manifest.json` record their source commit, version and build; these are immutable receipts, not editable configuration files.

Do not bump a second version file or commit generated release metadata back to main. Do not replace published tags/assets. A retry or later push must still produce a build newer than the one offered to installed clients.

## Verify a public release

1. Require a successful Release workflow, including its signing, notarization, publication and download-verification steps on GitHub-hosted runners.
2. Download the exact release’s ZIP, appcast and checksums. Run `shasum -a 256 -c SHA256SUMS`.
3. Extract and verify `codesign --verify --deep --strict HelloChat.app`, `xcrun stapler validate HelloChat.app`, and `spctl --assess --type execute --verbose=2 HelloChat.app`.
4. From an older installed build, check that Sparkle finds the newer version, downloads it, validates its signature and relaunches into that exact build. Verify preferences, startup configuration, microphone permission and Accessibility permission remain intact.
5. Keep real microphone/Voice acceptance separate from fixture and transport tests. Never automate live Codex calls to test a release.

For a change to Voice behavior, check both the ChatGPT and Codex presentations of the same desktop app. First use fixtures for the affected Start, existing-call, End, cancellation, and unavailable-Voice cases. Then obtain user-operated live acceptance in each supported presentation, without ending an existing call to make room for a test. Preserve custom bindings, keyboard layout, the complete modifier combination, and the chosen presentation. Record a native availability or registration blocker explicitly; a passing fixture or a working call in one presentation does not establish the other.

The public download is `https://github.com/EthanSK/hello-chat/releases/latest`. Sparkle reads the latest release’s `appcast.xml` asset. That feed points to the exact immutable version ZIP and contains its Ed25519 signature and length.

## Recover an interrupted upload

When publication is interrupted after the signed-release artifact has uploaded, dispatch the Release workflow from `main` with `recover_run_id=<failed-run-id>` before its three-day artifact retention expires. Recovery downloads that run's original ZIP, `SHA256SUMS`, `appcast.xml` and `release-manifest.json` from GitHub, checks the original run and source, rechecks the package and resumes the matching draft. It accepts only workflow and release-guide edits since the original build. A run that never uploaded its artifact cannot be recovered this way and needs a new normal release. No package is recovered from a personal Mac.

## Manual packaging

These commands are available for explicitly requested local packaging. Automated public releases use the hosted workflow above.

```sh
zsh scripts/test.sh
zsh scripts/build.sh
HELLOCHAT_NOTARY_PROFILE=your-existing-profile \
HELLOCHAT_SPARKLE_TOOLS=/path/to/verified/Sparkle/bin \
zsh scripts/package-release.sh
```

Both scripts use `HELLOCHAT_BUILD_DIR` when set. Packaging accepts only the original bundle identity, expected team, arm64 executable, hardened runtime and microphone entitlement. The archive is recreated after stapling and only those final bytes are signed for Sparkle. The app’s updater postpones its relaunch only during its own in-flight actions or speech checks. External Codex Voice calls and Agent Flow recordings do not block it; detach and file flushing preserve those sessions. Pending-only rechecks resume installation without requiring app focus. An abort after preparation restores local listening according to current saved settings. A matching installed startup job retains ownership after the update.
