# Observed Apple notarization response

`info-observed.json` was captured from `xcrun notarytool info --output-format json` on 4 November 2026 while investigating the first HelloChat production release (GitHub Actions run 41927957422). Tool version: 1.1.4 (43).

This is an observed response, not a synthetic example. Only the submission ID was replaced with a valid placeholder UUID. Archive name, status, date, fields, types and message were preserved. The command used an existing Keychain profile; no credentials are present here.

This fixture describes the diagnostic `info` operation. It does not prove an accepted submission or publication, and it is not the output contract for `submit --wait` used by packaging.
