# HelloChat

Native macOS wake-phrase helper for Codex Voice. Previously Hey Chat; replaced the unrelated HeyBoy project, whose history remains under archive/heyboy-before-hellochat.

- Read LEARNINGS.md before fragile changes. Keep public docs free of personal logs, device IDs, credentials, and local task paths.
- Build with zsh scripts/build.sh; run zsh scripts/test.sh. Use HELLOCHAT_BUILD_DIR for task-owned .noindex scratch.
- Recognition and model assets are local. Never silently add network transcription, voice identification, or background microphone behavior.
- Preserve the original com.ethansk.HeyChat signing identity and legacy instance lock for existing users. AppPaths owns data-folder migration.
- Never automate real Codex Voice calls in tests. Inspect current call and recording state before authorized installation or restart.
- docs/ is the public static site; keep installation and privacy claims aligned with actual artifacts.
