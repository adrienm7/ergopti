<!-- docs/todo-agents/issue99-karabiner-input.md -->

# Issue #99: Karabiner lease, swallowed keys, ISO key (macOS)

## Done (local dev, not pushed by this agent)

- `0292ec401d` fix(macos): resolve running applications without scanning every window. Root cause of
  the 13.4 s main-thread freeze at 09:40:11 that disabled the taps and fenced the lease (exit 73,
  inner silence 17.5 s): `hs.application.get` falls back to `hs.window.allWindows()`.
- `a593ac4db0` fix(macos): log an application that does not answer Accessibility at INFO.
- `a4fa6a2a13` fix(macos): name the timer callback that held the main thread (WARNING past 1 s).
- `68d474f968` fix(macos): let the lease READY deadline cover the worker's launches (7.5 s to
  11.5 s).
- `a0a2e0c85b` fix(macos): report the evidence behind every Karabiner lease timeout (wait and timer
  lateness, worker exit after a driver-side failure, slow READY, keys typed across a fence or a
  keyDown tap outage).
- `9566919c78` fix(launcher): say what the lease worker was doing when its input closed (Swift; its
  XCTests run only on macOS CI).
- `cfac383d36` docs(memory): the `hs.application.get` window scan.
- `356d14a3f3` fix(macos): deploy the ANSI virtual keyboard so the ISO pair passes through.
  Confirmed on the maintainer's Mac on 2026-10-22: the key left of "1" is the right one.

## Remaining, with next steps

Done since: the AI prompts use `RunningApplication.current()` and `DIRECT_LOOKUP_BASELINE` is
empty (e57f4cce77); the healthcheck `config` nil call was fixed by `c25c0d65c4`; on-time PONG/READY
deadlines with the menu open are read through an echo probe (25411ee080, issue #100).

2. Startup lane (decision 10, Hammerspoon coexistence, in the checklist's Wave 2): at 09:40:03 a second, standalone Hammerspoon instance started with the launcher
   one. It used `~/.config/ergopti_plus`, emitted the `karabiner_kc.log` warnings, aborted at
   `native_logger_environment` behind a blocking fatal dialog, and its KC poll timer kept writing to
   the shared daily log for at least 17 s. Find who launched it at the 1.0.4 install/relaunch, and
   stop the aborted instance's timers before its dialog.
3. PONG timeouts that fired on time with no worker diagnostic (09:49 to 09:53) are not explained by
   the log; the next report will carry the new evidence lines ("waited … late", "Hammerspoon closed
   its input without STOP; last private command …", "activation preparation took …").
4. Recovery churn: every fresh lease generation redeploys the 743 KB karabiner.json (token-scoped
   variable names change every rule), five times "during input after the 5.0 s typing deferral
   bound" in five minutes. Consider waiting for a typing pause while the rules are fenced anyway.

## Only the Mac can confirm

- Starvation hypothesis for the silent PONG/READY timeouts: run `memory_pressure | tail -1` while
  lease errors occur.

## Open risks

- `356d14a3f3` always deploys ANSI: a non-Apple external ISO keyboard (standard 0x35/0x64 usages)
  may now come out swapped, and it still overrides the user's virtual keyboard type. Leaving the
  user's `keyboard_type_v2` untouched may be the better design.
- The longer READY deadline delays recovery by up to 4 s when a worker truly hangs (rules stay
  fenced meanwhile).
- The Swift changes were not compiled here; they rely on macOS CI.
