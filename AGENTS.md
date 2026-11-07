# BetterDock

Native macOS Dock replacement. Apple’s Dock continues running behind it.

## Build and verify

For Bilal’s workspace, native compilation and signing run on the Mac mini:

- `Tests/run-mini.sh` — source sync, cached native build, regression checks, and native integration checks in a temporary GUI LaunchAgent.
- `BETTERDOCK_BUILD_HOST=mini ./install.sh --dist` — build and sign a standalone development app on the Mini without installing it.
- `BETTERDOCK_BUILD_HOST=mini ./install.sh` — build on the Mini, then update this Mac’s developer installation.

Never fall back to a native build on Bilal’s laptop without approval for that run. Mini caches, builds and TMPDIR use `/Volumes/DevVault/Dev/`. Only the small executable, bundle and fixtures stage under `/tmp` for GUI jobs because this Mini’s launchd privacy restrictions prevent removable-volume access. GUI job staging is deleted on completion.

## Boundaries

- `ConfigStore.swift` owns schema validation, atomic saves, recovery, profile folder copies and content migration. Do not bypass it for dock.json writes.
- `DockModel.swift` owns tile identity and layout. Unavailable apps and unresolved folders remain in persisted layouts.
- `DockViews.swift` contains presentation; `main.swift` contains app lifecycle and action coordination.
- `Controls.swift` owns settings, menu-bar recovery access and keyboard navigation.
- `AppleDock.restoreBackup` must preserve the original backup on failure. Never change Apple’s Dock preferences in a test.
- Preview bundles use `BDPreview=true` and an isolated `BDConfigDir`; preview mode disables Apple Dock/login mutations and permission prompts.
- Compile `Tests/NativeTests.swift` only with `-D BETTERDOCK_TESTS`. Native method-level integration checks do not replace a real GUI walkthrough.

## Delivery

Inspect actual settings, keyboard navigation, folder open/search/reorder, overflow and a working/empty/error state before installing. Preserve the existing config and original Apple Dock backup. Native CI is opt-in on a self-hosted `betterdock-mini` runner; do not claim it is configured unless verified.
