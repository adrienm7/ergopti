# macOS launcher: single instance, quit and relaunch against Windows and Linux

Audited source: `befa82a1` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The census's next area after the adapters: `macos/launcher/` (24 of its 102
pinned files changed, one new production file,
`OwnedRuntimeServiceRepairEntry.swift`), with the Lua side of the lifecycle
(`init.lua`, `infra/instance_admission.lua`, `infra/launcher_guard.lua`,
`platform/remap/lease_helper.lua`, `ui/menu/start_at_login.lua`). Windows
(`ErgoptiPlus.ahk`, `infra/lifecycle.ahk`) and Linux (`install/launch.sh`)
are the references. The 2026-11-04 lifecycle findings (MC-001, MC-002) are not
repeated. This session has no Swift toolchain: every candidate is a source
reading, none was built or run, and none is fixed here. Each needs a Mac to
fix and qualify.

## Findings (not fixed: the launcher builds only on macOS)

- **MLC-001, MJConfigFile seeded before the single-launcher lock.** The
  top-level code writes `MJConfigFile` to the embedded runtime's preference
  domain and flushes it before `app.run()` (`main.swift`, « Write
  MJConfigFile via CFPreferences before NSApplication.run() »). A second
  launcher (`open -n`, a developer app, an old copy in Downloads) therefore
  points the running copy's runtime at its own bundle, then finds the lock
  held and exits. The live launcher's bootstrap retry
  (`handleEmbeddedHammerspoonExit` → `launchHammerspoon`) does not seed
  again, and neither does a runtime macOS reopens by itself, so either boots
  the other copy's Lua. Windows takes its mutex first
  (`ErgoptiPlus.ahk:127-183`). `tools/test/test-launcher-single-instance.cjs`
  states the invariant but checks only the delegate's seed, so it passes.
  Direction: seed again before every runtime launch, and seed the early
  value only once the lock is the launcher's (or drop the early write if the
  delegate path covers the Gatekeeper case); then extend the `.cjs` guard to
  every `kHammerspoonConfigKey` write and add a
  `LauncherInstanceOwnershipTests.swift` case (lock held: the preference is
  unchanged).
- **MLC-002, a quit from outside skips the controlled exit.** Sparkle's
  « Install and restart », a logout or `osascript quit` reach
  `applicationWillTerminate`, which terminates the child and stops the
  loopback logger the child logs through at once. The child runs only
  `hs.shutdownCallback` (deliberately inert apart from the lease), so the
  LLM helper and orphan MLX server sweep, the keystats shutdown and the
  watchers never run, a detached `mlx_lm.server` survives, and the child's
  shutdown lines are lost. When the launcher-termination watcher wins the
  race, `launcher_guard` reports `launcher_terminated` as a runtime failure
  (exit 70). Windows routes every exit, logoff included, through
  `OnExit(Ergopti_OnShutdown)`. Direction: a controlled-quit handshake with
  the child before the logger stops; a launcher-initiated quit not reported
  as a failure (`LauncherEnvironmentTests.swift`, `tests/meta/shutdown/`).
- **MLC-003, a second launch after boot does nothing visible.** The second
  launcher activates the first and exits; the activation listener exists
  only during the Accessibility wait (`init.lua`), so nothing appears.
  Windows' `#SingleInstance Force` restarts the driver; Linux prints
  `launch.already_running`. A product decision: feedback (the menu or a
  notice), a reload, or a recorded difference.
- **MLC-004, a hard-coded leftover-runtime grace.**
  `kStaleRuntimeTerminateGraceSeconds = 3.0` and its 0.1 s poll
  (`LauncherInstanceOwnership.swift`) are literals, though the `[launcher]`
  timings registry claims every launcher wait; 3 s is below the Lua
  `user_quit_deadline_ms` (12 s), so a child still in its quit fence is
  killed. Windows never kills the old instance. Direction: both values in
  the registry, a single-source test tying the grace to the quit deadline.
- **MLC-005 (hypothesis), the exact-path launcher check under App
  Translocation or a symlinked app folder** (`lease_helper.lua` compares
  `ERGOPTI_LAUNCHER_EXECUTABLE` and its real path with the bundle path);
  `macos_launch_gate.py` has no translocated, symlinked or space and accent
  scenario. To probe on a Mac.

## Also noted

`start_at_login.lua` shows the generic « could not change automatic startup »
dialog while System Settings opens for an `approval` answer, and logs nothing
for a failed status read. `docs/memory/macos-hammerspoon.md` says ordinary
Hammerspoon on a checkout is supported, where `instance_admission` admits
only the developer app (the note looks stale).

## Refuted

The lock (flock, close-on-exec, no-follow, released by the kernel on a
crash); the leftover-runtime scan touching only the embedded bundle id; a
stray reopened runtime exiting quietly while a stock Hammerspoon is never
exited; the child's explicit environment; exit 0 after readiness read as a
quit only without a fatal report; the bootstrap retry's generation fence;
headless worker roles before NSApplication and Sparkle; the login item
following the bundle (`SMAppService.mainApp`); no Sparkle on a developer
build; a missing `init.lua`, runtime or instance lock failing loudly; the
launcher guard pinning the exact process.
