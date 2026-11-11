# Linux performance pass: daemon session measurements 2026-11-11

Baseline: `origin/dev` at `adfc5569` (the branch's start), measured from an
untouched worktree. After: branch `claude/ergopti-todo-linux-perf`. Both with the
same command, three runs each, on the same cloud container (no other workload
during a run):

```sh
unshare --mount --propagation private python3 tools/bench/linux-session-bench.py \
    --runs 7 --keys 200 --hotstrings 30 --tap-holds 30 --tray-rounds 5 --json out.json
```

The bench runs the real daemon, unchanged, over the container kernel model
(`tests/hardware/virtual_kernel_preload.c`) in an X11 session (Xvfb, openbox, the
accessibility bus, a focused GTK field from `atspi_fixture_app.py`) with a
StatusNotifier host walking the tray's dbusmenu as a panel does. Every figure is
taken outside the daemon at the boundary a user feels: a key frame written to
the model keyboard to the matching frame on the daemon's virtual keyboard, a
dbusmenu call to its reply, a spawn to the `Daemon ready` line. Each cell is the
median over the three runs of that run's median (or p95, or max). The host is a
shared cloud VM: Xvfb answers faster than a desktop's compositor, so absolute
values are lower bounds; the ratios are the result.

## Results

| Path                                      | Before: median / p95 / max | After: median / p95 / max | Change                         |
| ----------------------------------------- | -------------------------- | ------------------------- | ------------------------------ |
| Startup, spawn to `Daemon ready`          | 564 / 684 / 684 ms         | 498 / 710 / 710 ms        | -12 % median                   |
| Boot clock total (in-daemon)              | 363 / 507 / 507 ms         | 309 / 530 / 530 ms        | -15 % median                   |
| Boot CPU                                  | 216 / 229 / 229 ms         | 190 / 239 / 239 ms        | -12 % median                   |
| Layout resolves before ready, per boot    | 2                          | 1                         | -1 (X11)                       |
| First key after boot, press to output     | 3.73 / 5.32 / 5.32 ms      | 3.22 / 3.28 / 3.28 ms     | -14 % (3 boots, weak evidence) |
| Shutdown, SIGTERM to exit                 | 114 / 115 / 115 ms         | 114 / 114 / 114 ms        | unchanged                      |
| Key press to output                       | 1.68 / 3.02 / 11.4 ms      | 1.69 / 2.93 / 14.0 ms     | unchanged (bench floor)        |
| Tap-hold release to tap                   | 0.39 / 0.79 / 1.10 ms      | 0.40 / 1.03 / 1.10 ms     | unchanged                      |
| Hotstring `xz`: last key to first row     | 1.71 / 3.02 / 7.05 ms      | 1.77 / 3.07 / 8.22 ms     | unchanged                      |
| Hotstring `xz` → `MATCH`: to last row     | 45.2 / 51.2 / 55.0 ms      | 34.4 / 40.4 / 45.6 ms     | -24 % (20 ms of it is a pause) |
| Typing per replacement character          | 2.0 ms (sample rows)       | 0.65 / 1.05 / 1.11 ms     | -68 %                          |
| Tray root, first open                     | 18.2 ms                    | 3.0 ms                    | -84 %                          |
| Tray root, re-open                        | 17.2 / 18.4 / 18.4 ms      | 3.8 / 4.1 / 4.1 ms        | -78 %                          |
| Tray, every submenu's first open (sum 12) | 307 ms                     | 115 ms                    | -63 %                          |
| Tray submenu re-open (each)               | 25 to 29 ms                | 2.1 to 5.8 ms             | -80 to -92 %                   |

Boot stages (median ms), before → after: config 35 → 36, keystats 62 → 63,
services 52 → 57, input hooks 15 → 12. New stages, unattributed before:
`load` (process start to the boot clock) 190, `callbacks` 127, `watchers` 15
(63 in the first instrumented run, before the second layout resolve was skipped).

Per-submenu first open → re-open after: Tap-Holds 14.5 → 5.2, Raccourcis
13.2 → 4.2, Gestes 20.5 → 5.8, Disposition clavier 11.6 → 4.8, Hotstrings
11.1 → 4.4, Métriques 9.5 → 3.8, Intelligence Artificielle 8.1 → 3.4,
Applications 2.3 → 2.1. The remaining first-open cost is GTK row creation
(`tray.fill`: mean 5.5 ms, max 16 ms for 57 rows).

## Root causes and changes

1. **Tray requests waited out the idle wait.** The daemon's idle tick sleeps in
   `poll(2)` on the evdev descriptors for up to 8 ms; GTK, and with it the
   tray's D-Bus service, was pumped only between waits. Every dbusmenu call
   therefore waited up to 8 ms, whatever its size: a submenu open (Event,
   AboutToShow, GetLayout) cost 26 ms for 2 rows as for 57. The wait now also
   polls the GLib main context's descriptors (`appindicator.wait_companion`:
   acquire, prepare, query, poll, check, release; dispatch stays in the next
   tick's pump). GLib's own timeout is not adopted, so an always-ready source
   cannot spin the loop.
2. **Every injected press downloaded the keymap.** The per-press layout proof
   (`injector` admission → `xkb_capture.inverse_current` →
   `xkb_source_probe.read`) fetched and serialized the whole server keymap
   (48 KB, 0.6 ms on idle Xvfb) on each press. The read now reuses the text it
   last downloaded while no XkbNewKeyboardNotify or XkbMapNotify was drained
   on the connection; the synchronizing drains before and after still refuse a
   read that raced a change. Probe read cost: 0.83 → 0.16 ms
   (`tests/hardware/run_xkb_source_read_cost.lua`, which also proves a
   `setxkbmap` invalidates the reused text).
3. **The layout was resolved twice per boot.** The pre-grab resolve repeated
   the first one (an `xkbcomp` fork and a keymap parse, about 55 ms). It is
   now skipped when the published layout is bound to the X11 desktop source
   and still proven current; Wayland and `--keymap` resolve twice as before.
4. **The first key paid for a lazy load.** The shortcut assignments (a config
   read and a TOML decode, 8 ms) loaded inside the first key's dispatch; they
   load on the loop's first idle tick after `Daemon ready` (once per process
   either way).

## Instrumentation added

- Millisecond log timestamps (`infra/logger_sink.timestamp_provider`): Linux
  wrote `:000` on every line. The calendar face is cached per second, so a
  line costs 98 ns against 830 ns for the old default.
- Boot: the process age at `BootProfiler.begin` as `load=` in the summary,
  and the `callbacks` and `watchers` stages that left about 240 ms
  unattributed.
- `[Span]` TRACE/DONE pairs at DEBUG through `PerfCounters.trace/done` for
  `tray.fill` (per branch, by position, never by label), `layout.switch`,
  `config.reload` and `hotstring.expand` (event count only); macOS writes the
  same tag and name for `hotstring.expand` (`HotPath.trace/done`). At INFO a
  pair costs what `clock/span` cost (about 0.2 µs), measured.
- `input.latency`: a key's kernel stamp to its forwarded write
  (`PerfCounters.record_age`, 86 ns per press).
- The last counter interval at exit (`flush_now` had no caller, so a session
  shorter than a minute never reported its counters).

## Regression gates

- `tests/hardware/run_perf_budget_container.py` (joins
  `run_container_proofs.sh`, the CI container lane): the source read budget,
  then the bench with `--budgets` (spawn to ready under `[budgets]
boot_total_ms`, key and tap-hold under `[logger] hotpath_slow_ms`, typing
  per character under 1.5 ms, tray re-opens under 12 ms, one layout resolve
  per boot). On the baseline tree it fails four budgets (2 resolves, 1.97 ms
  per character, 26.7 ms submenu re-open, 17.1 ms root re-open); on the
  branch all hold.
- Unit: `test_perf_spans.lua`, the wait-companion cases of
  `test_evdev_reader_wait_any.lua` (one through a real FIFO), the segment
  inventory contract extended to `done()` and `record_age()` emissions.

## Not changed, with evidence

- **Compile before the boot clock**: about 440 modules, 6.5 MB of Lua; 126 of
  about 180 ms is LuaJIT compiling source, 8 ms as bytecode. Needs the
  maintainer's decision on a precompiled package (memory:
  `project-linux-startup-cost-is-compilation`).
- **Keystats stage**: 60 ms (200 ms on a first boot) waiting on the sqlite3
  child, 6 ms of CPU.
- **The first layout resolve** forks `xkbcomp` (about 30 ms) although the X11
  probe can serialize the same keymap in 0.6 ms; switching needs a proof that
  `infra/xkb_keymap` parses libxkbcommon's serialization.
- **The 20 ms pause** between an expansion's erase and its text is
  deliberate (slow applications) and blocks the loop.
- **Shutdown** (114 ms) and the key, tap-hold and first-row paths were
  already at the bench's floor (FIFO, Python reader thread).
