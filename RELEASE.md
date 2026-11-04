# Releasing HelloChat

The release workflow builds an Apple Silicon app, runs the tests, verifies its Developer ID signature and microphone entitlement, notarises it with Apple, staples the ticket, and publishes a ZIP with SHA-256 checksums. It runs when a `vX.Y.Z` tag is pushed. Ordinary source pushes do not publish a release. The manual action retries an existing version tag.

## One-time signing setup

The repository currently has no release signing secrets. A maintainer must configure these Actions secrets before the first release:

- `APPLE_CERTIFICATE_P12_BASE64`: the base64-encoded Developer ID Application signing identity, including its private key.
- `APPLE_CERTIFICATE_PASSWORD`: the password protecting that archive.
- `APPLE_ID`: the Apple developer account used for notarisation.
- `APPLE_APP_SPECIFIC_PASSWORD`: its app-specific password.

Use the existing **Developer ID Application** identity from team `T34G959ZG8`. Never commit credentials or signing archives. Setting up the pipeline does not export any local private key; a maintainer must separately authorise and provision signing credentials. Imported credentials live only in the job's temporary keychain and are removed at the end.

## Publish a version

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Info.plist`.
2. Commit and push the reviewed change, then create a matching version tag, such as `v0.10.1`, and push that tag.
3. Wait for the Release action to pass. A missing secret, version mismatch, test failure, incorrect signature, or rejected notarisation stops publication.
4. Download `HelloChat-macOS-arm64.zip` and `SHA256SUMS` from that exact release. Run `shasum -a 256 -c SHA256SUMS` in the download directory. Extract the ZIP and verify `codesign --verify --deep --strict HelloChat.app`, `xcrun stapler validate HelloChat.app`, and `spctl --assess --type execute --verbose=2 HelloChat.app`.
5. Quit the old app when no Voice call or recording is active. Move the old bundle aside before copying the new app to Applications: copying over a bundle can leave old resources behind. Keep existing preferences and startup settings.
6. Open the downloaded app. Allow Microphone and Accessibility when macOS asks, then check local listening with the intended microphone. A signed archive and passing unit tests do not prove physical microphone acceptance or Codex Voice operation.

The download page is https://github.com/EthanSK/hello-chat/releases/latest after the first successful release. There is no in-app automatic updater; this workflow automates publishing only.

## Release from the signing Mac

The same packaging checks can run locally without exporting a signing key:

```sh
zsh scripts/test.sh
zsh scripts/build.sh
HELLOCHAT_NOTARY_PROFILE=your-existing-profile zsh scripts/package-release.sh
```

The profile must already be configured in `notarytool`. Both scripts use `HELLOCHAT_BUILD_DIR` when set. The package script accepts only the original bundle identity, the expected team, an arm64 executable, hardened runtime and the microphone entitlement. It recreates the ZIP after stapling so the downloaded app carries its Apple ticket.
