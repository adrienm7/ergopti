# AutoHotkey audit scope

Audit `static/ergopti_plus/windows/`. Read `ahk-driver`, `windows-toolchain`,
`false-green-tests`, and only the Windows plus workflow topics routed by
`docs/memory/README.md`.

## Dedicated sweeps

- Missing `Map.Has`/`.Get` guards, unsafe coercion, unset variables, invalid
  property/array access, and OS calls whose exceptions can escape a hook,
  `InputHook`, `OnMessage`, or timer callback.
- Load-order and parse coverage. AHK v2 accepts several names as variables until
  runtime. Every `.ahk` remains UTF-8 BOM plus LF. Never use `/validate`; compile
  with Ahk2Exe or use the repository parse harness.
- Suspend/pause completeness. `Suspend()` covers hotkeys, not every InputHook,
  timer, message handler, watcher, or synthetic-input route. Check both teardown
  and restoration.
- Menu dispatch, generation fences, lifecycle START/SUCCESS pairing, timer
  ownership, asynchronous WinHTTP, and reload during active dispatch.
- `Critical` spans around I/O, COM, rebuilding, and calls whose caller can
  silently re-expand a supposedly narrowed span.
- Preview/engine parity across trigger precedence, word boundaries, groups,
  disabled features, dynamic entries, delay selection, and stale async output.
- Recent fixes and every sibling construction/caller/teardown they should have
  covered. A guard scoped to one function is suspect when the invariant is
  tree-wide.

For G4 evidence, use `perf-profiling`'s AHK reference. Resolve
`%APPDATA%\Ergopti\paths.toml` before inspecting
`<ConfigDir>/autohotkey/logs/`; never infer an event date from the process-start
date in the filename or count the errors-only mirror twice.

Search existing tests before reporting: a test can refute the hypothesis, and a
source-scanning test can also be vacuous. A confirmed finding names the exact
reproduction, current root cause, silence mechanism, and a regression test that
could fail for the whole class.
