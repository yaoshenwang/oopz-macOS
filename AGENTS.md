# Contributor and automation rules

This is the standalone macOS client. Product source lives here; raw research and personal operations data do not.

- This repository is the sole location for future macOS product development, testing and builds. The earlier research checkout is archival; do not synchronize entire source trees, embedded authentication material or build/signing scripts from it. Audio isolation and controls were ported here for 0.4.0; maintain the implementation here from now on.
- Screen-share audio uses a Direct custom track with microphone publishing and local playback disabled. Keep voice and shared-media volumes separate; subscribe only to the selected sharing UID. Never make window sharing silently capture full-desktop audio. True microphone/Direct coexistence and echo listening checks remain manual; see docs/AUDIO.md.

- Read README.md, CONTRIBUTING.md and docs/TESTING.md before changing behavior.
- Use short branches, normally `codex/<change>`. Keep one product source tree.
- Run tools/check_fast.sh while editing. Freeze source before the final build.
- Version comes only from Info.plist. Bump for a release, not every PR. Preserve previous build/<version> directories.
- PR CI builds without a signing identity or account. Tagged releases use separate build, signing/notarization and publication jobs. Maintainer verification uses explicit Developer ID PEM signing. Never silently fall back from requested Developer ID signing.
- Build, signing and test code must never query or read system Keychains, invoke `security`, or export signing keys. Do not run public PR code on a maintainer machine automatically. The maintainer has separately authorized using the existing local GitHub CLI login for repository operations.
- Signing keys, protocol authentication material and sessions stay outside this repository and all public artifacts. The maintainer explicitly permits publishing their Developer ID certificate identity. Private keys and API credentials must remain secret. Release environment secrets are authorized for tag-triggered signing/notarization only.
- All automated integration runs are headless, single-instance, and confined to the current account's OWN EMPTY voice channel (`owner == uid`). Missing prerequisites fail. Never select by a person's or area's name.
- Stop existing native instances before integration tests. Run the executable directly, never `open`, computer-use, real screen capture, or real microphone capture.
- Headless audio stays disabled. Synthetic audio must never reach a playback or SDK publishing path. Publisher checks use synthetic video only.
- Official Web picture/audio checks are manual and remain separate from local PASS. Never fabricate acceptance.
- Keep SDK callbacks on the main actor and replay saved volumes after each join path.
- Preserve `gracefulCleanup` followed by `_exit(0)` and bounded leave cleanup. Do not restore SDK destroy/NSApp.terminate to voice-active shutdown.
- UI stays dark; use Theme text colors. Real layout and listening checks belong to the user.
- Diagnostics accept DiagnosticMessage literals; interpolated values are private by default. Never log raw responses, messages, headers, URLs or session contents.
- Run tools/audit_public.py before commits and public uploads. Scan Git history and final artifacts as well as files. Never print a matched secret.
- All binary resources must have documented provenance. Update THIRD_PARTY_NOTICES.md when dependencies or assets change.
- Source commits use the project's non-personal attribution locally. Do not import author metadata or Git history from research archives.
- No public push, release or external messages until the exact payload has passed the relevant checks and the requested destination/disclosure choices are resolved.
