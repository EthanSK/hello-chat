# HelloChat engineering notes

- A moving input meter does not prove recognition. Keep recorded-fixture checks separate from physical microphone/Voice acceptance.
- Core ML cpuAndNeuralEngine allows CPU work. Compute-plan estimates do not measure real hardware utilization. Bundle pinned assets and disable model downloads while listening.
- Codex Voice must be established through exact live controls. A microphone process alone can be dictation or a residual stream; an incomplete negative accessibility scan proves nothing.
- Never cache an End control or use a start-capable toggle for cleanup. A stale toggle can reopen a call.
- Keep microphone capture input-only and pinned to the selected device; avoid changing system audio routing.
- Return promptly from AppKit termination callbacks, then clean up asynchronously; blocking the main actor can starve recognition and cleanup.
- Recognition buffers, diagnostics, and transcript contexts are bounded. Tests cannot prove indefinite leak freedom or absence of false wakes.
- Publication rename: HelloChat replaces Hey Chat. Preserve the signing identifier and process lock so privacy grants and single-instance ownership survive the rename. Migrate data without overwriting collisions. Resolve Codex by bundle identity and actual executable, not one developer's installation path.
