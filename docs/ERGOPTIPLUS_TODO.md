<!-- docs/ERGOPTIPLUS_TODO.md -->

# ErgoptiPlus continuation checklist

Updated: 2026-10-27 evening (read "Handover of 2026-10-27 evening" first). Latest stable: v1.0.7 (released 2026-10-27 from dev; previous [v1.0.6](https://github.com/adrienm7/ergopti/releases/tag/v1.0.6),
tag 950979d19c). **Next step: issue #101 follow-ups on the Mac (Backlog).** Open work only: a finished item is removed, its lessons go to
[docs/memory](memory/README.md), and the history stays in Git
(`git log -p -- docs/ERGOPTIPLUS_TODO.md`). Item numbers are stable and never reused. Open
questions are in [questions-for-maintainer.md](questions-for-maintainer.md); per-work handoff files
are in [`docs/todo-agents/`](todo-agents/).

Tags: **[CODE]** software to write or adopt; **[CI]** only a hosted or native CI run qualifies it;
**[PHYS-W]**, **[PHYS-M]**, **[PHYS-L]** needs a real Windows PC, Mac or Linux machine.

**Generic caveat, stated once.** Unless an item says otherwise, native macOS and Linux qualification
and every physical-device acceptance remain OPEN and their qualification flags stay false; portable
tests, containers and software-supplied events are never physical evidence. The maintainer has a
Windows PC (physical tests on request) and a work Mac (reproduce on CI first, then at most one short
command); there is no Linux machine.

**Rules for every agent.** dev and main stay linear (rebase or cherry-pick, never `git merge`); a
release is a push to `main` carrying a `Release-As: X.Y.Z` trailer; Codex agents push to dev, so
fetch and rebase first, and preflight on `tmp/preflight-dev` with
`gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all`; a hook failure caused by someone
else's dirty file is waited out or bypassed with a private index plus compare-and-swap `update-ref`
running the hooks, never with `--no-verify`; never weaken a test; quality over speed. Run the pinned
ruff 0.15.8 and Prettier before every commit. After touching
a sealed Windows updater source, reseal with
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`. Procedures:
[COORDINATOR-MEMORY](todo-agents/COORDINATOR-MEMORY.md).

## Handover of 2026-10-27 evening (read first)

- **Focus decided by the maintainer (27 Oct afternoon):** fix every macOS problem while their Mac is
  available. The general TODO and cross-OS parity work are paused until then (they resume afterwards).
- **State.** dev is linear and pushed; every dev push had its CI cancelled at once (a dev push builds a
  release; the maintainer allows pushing dev as long as that CI is cancelled). Latest stable: v1.0.6. A full
  CI of the head is dispatched on `tmp/preflight-dev` with `os_lanes=all`: read it first and fix its reds.
- **The maintainer's Mac field branch** is `field/mac-2026-10-27` (macOS 26.6.2, arm64, Swift Command Line
  Tools only, behind a company PAC proxy at work). It carries their logs under `docs/field-reports/` and must
  never be merged into dev: only dev is merged into it (`git merge` is fine there), then pushed. Their whole
  procedure is `git pull` then `bash tools/dev/collect-macos-field-report.sh`: it stops any running
  ErgoptiPlus and its kept-alive guardian, builds the developer app when the launcher changed
  (`tools/dev/run-macos-dev-app.sh`), runs every Debug check and the Ollama/MLX download flows through the
  field-run request (`static/ergopti_plus/macos/data/field_run.json`), collects the logs and commits and pushes
  them, also on Ctrl-C. Read the newest `docs/field-reports/mac-*` folder with
  `git show origin/field/mac-2026-10-27:<path>`.
- **Developer mode on the three OS** (run the clone's code with the installed app's features, auto-reload on a
  saved source file; inventory in `docs/design/developer-mode.md`, open checks in the item "Developer mode on
  the three OS"): macOS `bash tools/dev/run-macos-dev-app.sh` (`--open-only` without rebuilding), Linux
  `bash tools/dev/run-linux-dev.sh` (`npm run dev:linux`), Windows
  `powershell -ExecutionPolicy Bypass -File tools\dev\run-windows-dev.ps1` (`npm run dev:windows`), or a
  double-click on `static\ergopti_plus\windows\ErgoptiPlus.ahk` in the clone (the same mode, but it does not
  close a running ErgoptiPlus.exe). Each launcher passes the clone root in `ERGOPTI_DEV_SOURCE_ROOT` and the
  driver refuses a root that is not its own clone; without it, the Windows driver derives the root from its
  own folder when that folder is in a Git checkout of this repository.
- **Problem ledger of the Mac session:** see "Mac field session 2026-10-27: problem ledger" below; every
  problem of issue #104 and of the field reports is there as fixed (sha) or open with its next step.
- **Coordinator scripts** are in `tools/dev/coordinator/`: `integration-sweep.sh <out-dir>` (gen:check,
  format, every single-file node suite check in parallel with a lone re-run of each red, the Linux suite, the
  macOS suite per group), `cherry-pick-list.sh <list> [resume-sha]` and `renumber-suite-ordinals.cjs`. The
  commit hook needs Ruff 0.15.8 first on PATH (`python3 -m venv` plus `pip install ruff==0.15.8`) and Node 22.
- **Integration procedure** (each batch): list the agent branch commits whose subject is not on dev;
  cherry-pick them onto dev or a local `integ/*` branch (skip seal refresh commits; on a conflict prefer dev
  when it already fixed the same thing, otherwise merge both by hand); renumber suite ordinals on a collision;
  reseal if `test-windows-updater-original-source.cjs` fails
  (`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write`); run the integration
  sweep; push dev and cancel its push CI in the same step; dispatch `ci.yml` on `tmp/preflight-dev`.
- **Agent commits waiting for integration (paused with the parity work; integrate after the Mac
  session):** every one is on a remote backup branch; integrate by subject, they were green on their own
  base.
  - `tmp/wip-todo-af`: 8634b1ff80 (Linux acknowledges the layout scope once loaded), 358e211a10 (Windows
    number-row design answer), 3337d99bc8 (Linux number-row order onboarding), 4fcb4a979a (logger scalar),
    then `tmp/wip-todo-ag3` d5cf3ba50b (number-row strings for that work; it conflicts in the 21 locales
    unless the AF commits come first). AF also left: reconcile the Linux `keyboard_layout_scope` comments and
    the design note with the ninth batch.
  - `tmp/wip-todo-ah`: 53b1bc5375 (reset every `hs.*` cache entry between macOS test files) and five CI
    speed-ups (Ubuntu archive reuse, AHK shard split, one macOS checkout per E2E cell, Intel E2E start,
    SwiftPM cache trial); run them on `tmp/preflight-dev` before dev.
  - `tmp/wip-ci-fix`: f44fcc1e64, c9b90d11d7, ba13937b8c, 5009ad87b8 (Linux distribution-row CI fixtures):
    check each against dev first, later fixes may have replaced them.
  - `tmp/wip-fr-uncommitted` (0d7e53b28b): the uncommitted Ollama warmup-stop attempt of a stopped agent,
    saved as a commit whose tree holds only those three files; superseded by 708bc6671d, kept for reference.
  - `tmp/wip-todo-ae-par30`: 41f72525cf is an unvalidated work-in-progress snapshot of the PAR-30 Linux
    updater signature gate; redo it from the item, do not cherry-pick it as is.
- **Review the Windows antivirus surface ceilings (27 Oct).** d7d98e133b raised the exe bundle's DllImport
  ceiling in `tools/ci/windows-exe-av-surface.json` from 52 to 54 for the two staged-file custody P/Invokes of
  `vendor/ergopti_updater_download.ps1` (`CreateFileW`, `GetFileInformationByHandle`, from bdfa026d16). Check
  whether a bundled type already declaring them could be reused, then lower it back. The same build log notes
  `key_state_polling` dropped to 59: lower its script ceiling from 62 once a Windows build confirms 59.
- **Last full preflight:** run 40567247114 on d1f9682904 had 89 green and 3 red, fixed by bfd5401162 (Windows
  OS-call purity ratchet after the WPM region fix), 2956b2fc3d (macOS 26 input-source fixtures waited for the
  observed selection) and fbdf2be92d (debian:12 carries no stalonetray; the AppImage check uses trayer). The
  v1.0.7 release commit sits on top of them and a new full run qualifies it before `main`.
- **The ChatGPT fix branches** fix/linux, fix/macos and fix/windows are fully on dev. The container proxy
  refuses remote deletion, so the maintainer deletes them: `git push origin --delete fix/linux fix/macos
fix/windows`.
- **Host-only reds on the Linux container** (not bugs): JS `test-ahk-tap-follower`, `test-linux-install-sandbox`,
  `test-linux-runtime-native-registration`, `test-macos-managed-bootstrap-http`, `test-managed-ollama-protocol`,
  `test-managed-remote-retirement` (no pwsh), `test-linux-deb-package-owner` (refuses root),
  `test-drift-guard-covers-every-output` (worktrees only, node_modules symlink). Lua as root: every
  EACCES/unreadable/denied case, Linux test 102, four `test_sqlite_first_open` native cases; macOS screenshot
  EACCES, two mlx-repair unreadable neighbour, errors-log refuses denied, the eight `release-arming-physical`
  cases (refuse root). Confirm with
  `setpriv --reuid=65534 --regid=65534 --clear-groups` and set `XDG_RUNTIME_DIR`. Run the macOS suite per
  group: one process slows down progressively here.
- **Windows counterparts of the 26 October work** (add to the PC list below once the Lua side is in dev):
  - read `[logger] hotpath_slow_ms` in `hotpath_profiler.ahk`;
  - drop the dead crash kind (`error_dialog/init.ahk`, `ERROR_REPORT_KINDS`, then the shared `KINDS` and the
    `crash_multi_line_without_recent_issues` vector together);
  - read the 14-colour palette from `native_theme.toml`;
  - use `dialog.action_picker.requires_ai` for the greyed AI actions;
  - port `llm/request_plan` (debounce, batching) with its vectors, accept -1 "never", never hold explicit
    requests, read `llm.trigger.min_request_interval_ms` with a menu row, then delete
    `rate_limit_min_interval_ms` from `inference.json`;
  - `tap_hold.toml` v0→v1 migration (`_shared/tap_hold/migrations.toml`) in the loader and writer, stop
    reading and writing `explicit_delays`;
  - Quit refusals before `ExitApp` with `notify.quit_refused` (PAR-45);
  - the registry op that re-encodes a value in `config_migrate.ahk`, then delete the macOS
    `[llm.profiles] user_profiles` reader import.

## Mac field session 2026-10-27: problem ledger

Every problem seen on the maintainer's Mac on 2026-10-27 (macOS 26.6.2, arm64), from issue
[#104](https://github.com/adrienm7/ergopti/issues/104) (body; no comments), the field reports
`mac-2026-10-27_150026`, `_151611`, `_152936`, `_164726` and `new.txt` (the day's WARNING/ERROR
log) on the `field/mac-2026-10-27` branch, which never reaches dev. Builds seen: ba73f58 (15:00),
92d4615 (15:16), b014076 (15:29), 228f79f2 (16:47 developer app). The 16:28 to 16:54 boots ran
after every 14:00 to 15:38 fix below, so "not seen after 16:28" is the evidence for those fixes.
The automatic report `mac-2026-10-27_194738` (developer app from about dev 57fd72c1fb, boots
19:47:05 and 19:48:21) is "the 19:47 run" below; L40 onwards come from it. The report
`mac-2026-10-27_210657` is "the 21:06 run": its Lua and shell were current (dev 35725ebc22 era),
but the collector reused a running developer app whose launcher predates L40 and L41 (fixed by
e4ca76b1c9), so no Swift fix was active. Labels are local to this ledger. Shas on `tmp/wip-audit-field` change when rebased onto
dev.

### Fixed on dev

- **L1** Remap guardian status 'unavailable', regeneration fail-closed (new.txt 14:25:50 to
  16:06:42, 7 boots). Fixed b3893e0480, 6f667b3380 (developer-build agent fallback, after
  228f79f2). Not seen after 16:28. Mac confirms: no "guardian status 'unavailable'" at boot of the
  developer app and of the installed app. Developer app confirmed on the 19:47 run ("guardian
  healthy: true"); the installed app is still to confirm.
- **L2** menu_state.lua:531 timer held the main thread 21 to 23 s, with "Cannot read typing
  rollover facts" and "Aggregate cache recovery failed" (new.txt 14:25:49, 14:27:27, 15:26:02,
  15:28:51, 16:06:41). Fixed d854d55c79, 18d71c8580, d3cb3e6765 (sliced recovery). At 16:28 the
  recovery ran in slices ("interrupted after 267 slice(s)", expected). Residual hold: L18. Mac
  confirms: no rollover ERROR, no hold over 2 s from menu_state.lua:531. Confirmed on the 19:47
  run: no rollover ERROR, no main-thread hold warning, boot complete in 1.7 s.
- **L3** macOS disabled the keyDown, loopbackKeyUp and script-control taps, then "Typing context
  invalidated" (new.txt 14:27:29). Consequence of the 23 s hold of L2; same fix. Mac confirms:
  no tap re-enable warning. Confirmed on the 19:47 run.
- **L4** AXValueChanged watcher cleanup/setup failed, context_tracker.lua:631 (new.txt 14:26 to
  16:09, about 20 lines). Fixed 690d7877d8. Not seen after 16:28. Mac confirms: none after
  switching between apps for a few minutes. Confirmed on the 19:47 run: context_tracker logs only
  its TRACE and DONE observer lines.
- **L5** notifier.lua:79 "attempt to call a nil value (method 'release')" (new.txt 14:31:59,
  14:32:09). Fixed 75c2f02956. Not seen after; confirmed on the 19:47 run (no notifier error).
- **L6** hs.task refused to launch /usr/sbin/systemextensionsctl (new.txt 14:31:37, 15:27:18).
  Fixed f03227b916. Not seen after.
- **L7** "Boot stage 'Accessibility permission' opened while ... still open" (new.txt 14:25:26,
  15:34:07, 16:06:18). Fixed ed5a622eda (AK); verified: absent from the three boots on 228f79f2
  (16:28, 16:48, 16:54) and the 19:47 run. Mac confirms: absent after a cold start that waits for
  the permission.
- **L8** AI activation chain at 15:27:35: MLX bootstrap exit 78 "native network receiver is
  unavailable", Ollama bootstrap exit 64 "Erreur inconnue", eight MLX warmup settlement ERRORs,
  "PGID pending timeout", four HTTP 1500 ms timeouts, two download_window error states, failed
  switch_model. Fixed c0e3359a19 (receiver admitted in a developer app), 8fc33138ec (named exit
  causes), 0e9fa0c149 (MLX warmup stop), bc09e4584c (owned pinned Ollama). Mac confirms: enabling
  MLX then Ollama from the menu downloads or names a closed cause, with no settlement ERROR. The
  19:47 run named both causes and logged no settlement ERROR; the causes are new: L40 (Ollama
  exit 64 again, developer build) and L41 (MLX, native_certificate_load).
- **L9** TIS probe did not compile, "missing argument label 'name:'" (`_151611`, `_152936`
  probe_compile.txt), and a stale binary ran anyway. Fixed 678588c625, 1434adcc57.
- **L10** PAC download failure aborted downloads; issue #104 `probes.proxy_pac.state: error`.
  Fixed 8e267e23df, 7634296b28, cbaa14ad46, 7af4e65b10, d09303810d (PAC then direct). Field check
  part: L26.
- **L11** Field run step 10_ollama_model timed out while still downloading, then "answered after
  it was settled" (`_164726`, new.txt 16:53:45). Fixed 2790b3239a.
- **L12** "Field run ... was cut short by a reload" (new.txt 16:54:32). Fixed bde408f3a6.
- **L13** `_164726` holds no logs: the collector was stopped. Fixed 259244ddb1.

### Fixed on tmp/wip-audit-field (to land on dev)

- **L14** "TOML mapping file '<name>' registered ZERO mappings" on every boot (new.txt 14:27:05 to
  16:54:31, 7 boots). Cause: a pack whose only section is disabled by the user registers nothing
  on purpose. Fixed 9481ba78ac: one INFO line names the disabled section count; an empty or
  unreadable file still warns. `'<name>'` is the deliberate PrivateLabel mask
  (`_shared/lua/diagnostics/private_label.lua`), not a logging bug. Mac confirms: no ZERO warning.
  Confirmed on the 19:47 run.
- **L15** "Duplicate Ergopti Karabiner revocation completion ignored" on every reload (new.txt
  14:26:53 to 16:28:13, 6 times). Cause: both revocation halves answer synchronously, the join
  settles, and the trailing join in `M.revoke` (platform/remap/init.lua) settled again. Fixed
  9f4dea89b2. Mac confirms: no such warning after a reload. The 19:47 run has one, at 19:47:04,
  from the driver booted at 16:54 before the clone was updated; the two boots of the new code log
  none. Still to confirm after a reload of the new code.

### Fixed on tmp/wip-field-1947b (to land on dev)

- **L40** Ollama install "exit=64, the installer refused its own request" in 110 ms (19:47 run,
  09_ollama_runtime install_failed/state_failed, 19:48:49). Not the network and not the port
  11435: the driver names `ensure-ollama-native-deps.sh` in its own folder, which a developer
  build reads from the clone, and the launcher's PTY guardian admitted only the bundle payload
  folder, so it answered `RETIRED 64` before running anything. Fixed 94bfe7e2e4: the guardian
  admits the installers of the folder `LuaSourceSelection` names. Mac confirms: on a developer
  app, choosing Ollama installs Ergopti's own 0.40.4 or names a later closed cause (expect L41's
  certificate cause while L41 stands). The 21:06 run still shows exit 64 in 120 ms: expected, its
  launcher was the stale one without this fix.

### Fixed on tmp/wip-field-2106 (to land on dev)

- **L47** MLX install `bootstrap_failed`, `cause_permission` (21:06 run, 21:08:39): every package
  was downloaded and synced and "Virtualenv ready" printed, then the PTY process-group wrapper
  raised `PermissionError` from `os.killpg(pgid, 0)`. Darwin answers EPERM for a group whose
  leader is exiting but not yet reapable, and the wrapper raised as soon as `poll()` still saw the
  leader. Not the SSL_CERT_FILE drop (the downloads succeeded because of it) and not a clone file
  mode. Fixed 4058b3d471: EPERM is asked again on the next tick within a 2 s grace; a lasting
  refusal is still an error (`test-pty-process-group-escalation.cjs`, exiting-leader mode). Mac
  confirms: the MLX install ends with exit 0 after "Virtualenv ready".
- **L48** [PHYS-M] 12_mlx_model `download_launcher_failed`: "the launcher failed (code 0)" in a
  notification only, 0.7 s after the start, with no log line. The launcher script prints the
  download PID line and exits 0, so code 0 with no PID means the PID line never reached the
  stream callback; whether it arrived only in the final output, after the stream had stopped, is
  unproven. 30f49c487b now logs the exit, the PID state and whether the final output carried
  the PID line. Mac confirms: the next run with a working MLX runtime (L47) either downloads the
  model or logs that line; "sentinel in final output=yes" points at the stream stopping early.

### Open TODO

- **L46** [CODE][PHYS-M] Two-finger scrolls switched tabs through the vertical three-finger swipe
  (`swipe_3_up` tab_prev, `swipe_3_down` tab_next); the maintainer turned the option off. The
  day logs hold no live fire line (the swipe action was off and the log collapses repeats), but
  show the shape: `Finger join (fast-path): 2 → 3` immediately followed by `n 3 -> 2` (14:25:52).
  Causes in `modules/gestures/engine.lua`: a third contact joined a pair on ONE frame; a count drop
  shifted startPos but left endPos frozen, so a palm touching below the pair for a frame committed
  a vertical swipe toward it; a resting thumb moved the centroid two thirds of the scroll; a
  three-contact touch-down continued as a moving pair; a three-finger touch landing on a scroll's
  momentum. Fixed on dev (6d3aa65273), then rebalanced on `tmp/wip-three-finger-swipe2` after the
  first Mac test missed deliberate swipes: a pair that has scrolled (direction locked, travel past
  the two-finger lock `SWIPE_MIN_2`, or a macOS scroll phase) or outlived `multi_finger_landing_ms`
  (300) never promotes; before that a third finger promotes once held `pair_join_confirm_ms` (20);
  every contact must cover `Geometry.COHESION_MIN_SHARE` (0.3) of the travel since the promotion;
  a three-finger gesture that continues as a moving pair aborts; `scroll_momentum_guard_ms` (200)
  follows only a native momentum phase or a locked pair lifting. Each refusal writes one DEBUG line
  `Three-finger candidate rejected by <gate>: <measured value>` (gates: frames held, pair scroll,
  landing window, cohesion, scroll guard). Linux `mt_decoder.lua` had the same one-frame peak and
  whole-touch travel: same rules there (`finger_join_frames` 2, landing, peak-only travel, pair
  abort, scroll guard, same DEBUG lines). The cohesion share stays with the other spatial
  thresholds in `geometry.lua`: the timings registry is read through `sec` by the 22 engine test
  stubs, which have no `count`. Windows: no shared flaw, the precision touchpad driver recognises
  three-finger swipes itself and sends the configured key chords
  (`windows/modules/gestures/init.ahk`), so Ergopti counts no contacts there. Mac confirms:
  re-enable the vertical three-finger swipes, scroll with two fingers for a few minutes (with and
  without a thumb resting), no tab switch; deliberate three-finger swipes (slow, fast flick,
  staggered landing) switch tabs every time; any miss leaves a `rejected by` line naming the gate.

- **L16** [CODE][PHYS-M] Slow ingest tick, `append` phase 466 to 563 ms, peaks 1531 and 1709 ms
  (new.txt 14:25:50 to 16:53:38, 20 lines, still on 228f79f2). The 1.2 to 1.8 s ticks are the
  log_manager.lua:1722 holds. `LedgerAppend.flush` (adapters/ledger_append.lua) takes the lock,
  reads the journal, publishes it atomically, reads the tail, appends, clears the SQLite outbox
  and publishes the journal again; `prepare_append` reads the whole data.sql (68 MB) only without
  a journal, so the cost is not proven yet. Next: split the `append` trace mark into lock,
  journal publish, tail, write, clear and terminal publish, then one Mac run names the slow one.
- **L17** [CODE][PHYS-M] "Slow preferences save 1.9 to 2.1 s (prepare about 1.25 s, write about
  0.8 s; operations=293)" (new.txt 15:27:35 to 16:48:20, 6 times, also on 228f79f2). It is the
  2.06 s hold of startup_controller.lua:263 (15:28:57, 16:48:20). Next: profile `prepare` for 293
  operations and why a one-key save carries 293.
- **L18** [CODE] keystats start still holds the main thread 1.1 to 1.3 s from the deferred timer
  at menu_state.lua:531 (new.txt 16:28:06, 16:48:13, on 228f79f2). Next: move the SQLite open and
  offset replay of `kl.start` into slices like the recovery.
- **L19** Fixed 3d6479306a for the measured cause; one smaller residue stays
  open. log_manager.lua:1585 (the recovery slice timer) held the main thread 5288 ms right after
  "Typing ids restart ..." (new.txt 16:49:17 to 16:49:22). Measured on a synthetic cache built
  from schema.sql with the sqlite3 3.45 CLI and Python's sqlite3 (180,000 typing rows, 61 MB of
  typing text, 3 million n-gram rows): deleting the device's derived rows in one transaction took
  9.5 s; 500 rows per committed batch took 30 ms (synchronous=FULL), 5000 rows 225 ms. The
  replay query `ORDER BY ts, id` uses a temporary B-tree for the sort and returned its first row
  after 165 to 183 ms (9 ms with `ORDER BY id`). Fix: inside the recovery, a table holding more
  than 100 rows for the device is now deleted in committed batches of 100 with a pace point
  between batches, and the rest keeps the single transaction. Still open [CODE]: the 170 ms sort
  goes over the 8 ms budget; an index on events_typing(device_id, ts, id) added through
  schema.sql with a cache migration would remove it. Mac confirms: no hold over 1 s from
  log_manager.lua after a "Typing ids restart".
- **L20** Fixed ef3b8ddfd5. "config.toml
  cannot be read, so the virtual keyboard choice is unknown" (init.lua:2168 on 228f79f2, new.txt
  16:28:07, 16:48:12, 16:54:32, developer mode). `Preferences.current_view` now returns a closed
  reason (publication_in_flight, schema_refused, unreadable, undecodable, section_shape,
  outdated_keys, value_type, value_out_of_range, ...) and the error prints it. An absent
  config.toml was already the defaults, so the field cause is one of those reasons; the earlier
  "Config migration ... refused (newer)" (15:32:19, 15:34:29) points at schema_refused. Mac
  confirms: the next occurrence names its reason; if it is schema_refused, decide whether a
  read-only view may read a newer schema. The 19:47 run names `value_type` (19:46:39 to 19:48:23,
  both boots of the new code, every regeneration and wake refresh): one stored value has the
  wrong TOML type. The view now also returns that value's config.toml path and the error prints
  it ("value_type at <section.key>"), 52d9113b74. Mac confirms: read the key in the
  next log, then fix the stored value or the manifest type it is checked against. The 21:06 run
  names it: `value_type at hotstrings.dynamic.date`. That manifest entry is a feature row (a
  table such as `date = { enabled = true }`); a bare `date = true` or `date = false` reproduces the
  refusal here, while `Preferences.load` accepts the same file, so only the read-only view fails
  and every Karabiner regeneration and wake refresh stops on it. Writer found: the current macOS
  preferences save, whose `dynamichotstrings_date` state key mapped the boolean onto the row
  itself, so every save wrote `date = false` or `true`. Fixed in three parts: c84e0f3a95 (load
  and the view admit values through one rule; a value load leaves out as outdated is left out of
  the read-only view, never refused by a second rule), 9db1dea667 (the macOS key maps to
  `hotstrings.dynamic.date.enabled`), 54767a938d and 1b7abe4e29 (op `wrap_value` in the three
  engines, then schema v16 rewrites a bare switch of any dynamic feature row into
  `[hotstrings.dynamic.<id>] enabled = <bool>` on Windows, macOS and Linux). Mac confirms: after
  the update the boot logs the v16 migration (with its `config.pre-v<N>-*.toml` backup),
  `[hotstrings.dynamic]` holds no bare `date`, and no "config.toml cannot be read" appears on a
  Karabiner regeneration or a wake refresh.
- **L21** Fixed 708bc6671d. Ollama
  `stop_warmup() could not retire its HTTP owner: false` and settlement 'Ollama warmup stop' did
  not commit (new.txt 16:28:07, after "startup_model_download_declined"). Cause: hs.http.asyncPost
  returns no task, so a warmup POST in flight can only be revoked logically; `cancel()` reported
  that as a refusal. It now answers "pending" for that case and the stop commits, as the MLX fix
  877b922d23 does. Mac confirms: no such ERROR when the startup declines the model download.
- **L22** Fixed b5b56adbf0. A
  granite model pull showed an error at 100% that no log recorded (maintainer report during the
  field run). A non-zero pull exit only posted a notice; it now logs an ERROR with the exit code
  and the last line the pull printed (the digest or manifest refusal after 100%). A pulled model
  that does not load, and a pull task that cannot be settled, log an ERROR too. Mac confirms: the
  next failed pull has one ERROR line naming its cause.
- **L23** [CODE] "Ignored-window prewarm incomplete; tracking remains fail-closed" (new.txt
  15:28:28, 16:28:04) and 1 s holds from keymap/utils.lua:1426 and :1455 (14:26:05, 15:34:09).
  Next: log which prewarm stage was incomplete and bound the 1 s probe.
- **L24** [PHYS-M] key_event_health: key events 250 ms or more late (max 879 ms), 100 key-downs
  without key-up, 81 key-ups without key-down, 62 keys stuck over 3 s, one key stuck 518 s
  (new.txt 09:54 to 10:36, session totals); issue #104 shows 1 late key. Most late events follow
  the main-thread holds of L16 to L19. Next: after those, re-read the totals; lost key-ups without
  a hold point at the Karabiner virtual HID path (big item 2).
- **L25** Known limitation, plus one open bug. "Failed to enable 'Composer Check' —
  reason=process_failed" (new.txt 14:31:52, 16:48:44). The TIS probe (issue #104 and `_152936`)
  shows macOS 26.6.2 refuses it: register 0 and enable 0, but the source stays disabled, select
  returns -50, the HIToolbox preference route is refused too, and removed sources stay listed
  until logout. The rollback disable right after was refused "busy": `run_bounded_process`
  (modules/keymap/input_sources.lua) published the terminal before freeing the mutation slot, so
  a mutation started from that callback was refused. Fixed af5765a659. Mac confirms: after a logout, the probe's `after-logout` mode for M5b/P6.
- **L26** [CODE][PHYS-M] field run 03_field_network: fail (`_164726`); the PAC host is unknown
  off the company network (new.txt 16:48:20). Sub-steps were not captured (L13). Next: read the
  sub-steps in the next report; a PAC that cannot be fetched while direct works must not fail the
  check. The 19:47 run has them: see L41 and L42.
- **L27** [PHYS-M] field run 04_field_toolchain: fail (`_164726`), sub-step unknown; candidates
  are `timer_late_ms` (main-thread hold) and the Shortcuts or Homebrew steps. Next: read the
  sub-steps in the next report. The 19:47 run names it: `karabiner_signature` exit_1, see L43;
  every other step passed (timer late 0 ms).
- **L28** [PHYS-M] field run 06_field_composer: fail, same cause as L25. 07_key_accounting:
  needs_typing, not a failure: the maintainer types the prompted text on the next run. The 19:47
  run is the same (composer_ready fail:not_enabled; the TIS probe again shows register 0, enable
  0, select -50 and the source still disabled): known limitation, not re-fixed.
- **L29** Fixed on tmp/wip-field-run-checklist (cf852cf23d): every privacy pane URL now comes from
  macos/data/privacy_panes.json through adapters/privacy_settings.lua, which opens the
  `com.apple.settings.PrivacySecurity.extension` form from macOS 26 on. The collector's
  `privacy_pane_urls` step opens every pane in both forms and records each `open` exit code
  (System Settings is quit only if it was not running): read it in the next report; if the
  extension form fails too, trace `hs.urlevent.openURL`. The diagnostics schema `settings` URLs
  still use the legacy form. Original entry: Screen Recording settings could not be opened, openURL returned false
  (new.txt 15:31:46). adapters/screen_capture.lua uses
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, the same
  scheme as the Accessibility and Input Monitoring panes, so the URL alone does not explain it.
  Next, on the Mac: run `open "<that URL>"` in Terminal; if it fails on macOS 26, switch to the
  `com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture` form, else trace the
  `hs.urlevent.openURL` call made from the notification click.
- **L30** Fixed 0e7bff98d2. karabiner.lease "'status' called before M.init()" (new.txt
  15:32:19, right after the config migration refusal stopped that boot early). The guard at
  platform/remap/lease_controller.lua now logs its caller's traceback. The evident caller is the
  diagnostics collector (`H.collect_input`, ui/healthcheck/helpers.lua), which reads the remapping
  phase on any boot; it now reports `uninitialized` without calling status() when the controller
  was never initialized. Mac confirms: no such ERROR; if one appears, its traceback names the
  other caller.
- **L31** fixed (this commit): "Accessibility observer setup failed ... for PID 31319" was the runtime's own
  windows (31319 is `runtime_pid`). The maintainer decided their typing counts; the event tap already counts
  it, so `M.update_ax_observer` now logs that refusal at INFO and rolls the observer back, while another
  application's refusal stays a WARNING (`test_context_tracker_ax_own_process.lua`). Mac: no such WARNING
  after focusing an Ergopti menu or page.
- **L32** Partly fixed on tmp/wip-field-run-checklist (cce99afbc7): the shared schema enum lacked
  `missing`, `unavailable` and `not_used`, so the share projection turned a refused Screen Recording
  grant (and a guardian needing approval) into `unknown`. Still open: Input Monitoring has no
  non-prompting reader (IOHIDCheckAccess via a native helper), and the resident size breakdown.
  Original entry: issue #104 diagnostics: Input Monitoring, Login Items and Screen Recording read
  `unknown`; memory used 843 MB with 93 MB free. Next: read or label those permissions, and
  measure the 843 MB resident size.
- **L33** Fixed on tmp/wip-field-run-checklist (23ac97fb4a), not compiled here: the next collector
  rebuild must show none of the four warnings. Original entry: Swift warnings in the launcher build (`_164726` field*run.txt). The "always
  true" one, OwnedVirtualHIDDaemonReportMainOperation.swift:112 `returned != nil && error ==
nil`, has no behavior effect: `executeAndReturnError` returns a non-optional descriptor and
  `error == nil` alone decides, which is the intended check. Next, on a Mac with swiftc: replace it
  by `* = script.executeAndReturnError(&error)`and`scriptReturned = error == nil`, then fix
main.swift:1290 "will never be executed", OwnedSuspendedImageGuardian.swift:58-59 trailing
closures and RemapLeaseWorker.swift:1297 `var`; the Linux container has no swiftc to compile
  them.
- **L34** [CODE] HotPath over budget: preview.rebuild 5.3 to 13.3 ms, hotstring.match 6.4 ms,
  keydown 5.8 ms (new.txt 14:26 to 16:18). Low priority; profile with perf-profiling.
- **L41** Fixed bc33bfbc73 [PHYS-M]. Every native download stopped at stage
  `native_certificate_load` (19:47 run: the MLX `uv sync` staging failed 6 of 6 attempts with
  native receipt reason `certificate`, 19:48:49 to 19:51:26; 03_field_network tls and transfer `certificate`). This is
  not TLS inspection: that stage runs before any route lookup or connection, and it fails only
  when `SSL_CERT_FILE` or `SSL_CERT_DIR` is set in the environment the driver inherits
  (`ManagedCertificateAuthorities.load`; no Ergopti code sets either). The client is the signed
  native worker (`--managed-http`, used by `managed_network_check.py`, `managed_bootstrap_http.py`
  and the owned Ollama): it keeps the system and keychain trust and adds those variables'
  certificates as extra anchors, but refuses the whole request when the file or folder is not
  strictly PEM certificates (a comment or text header such as `/etc/ssl/cert.pem` carries, a
  non-certificate block, an unreadable path, an empty folder). uv, curl and Python were never
  reached. The check now reports `route_lookup skip not_reached` and `tls fail ssl_cert_env`
  for that stage (76c8e5336b) instead of "selected" and a TLS verdict. Maintainer decision: macOS
  downloads use the system and keychain trust only. bc33bfbc73: `network-retry.sh` unsets both
  names for every download child with one INFO line per name ("Inherited SSL_CERT_FILE ignored:
  downloads use the system and keychain trust."), the launcher's `--managed-http` and
  `--managed-bootstrap-download` roles unset both before reading their environment, and the Go
  `native_http` package ignores them on darwin. Linux and Windows are unchanged. The Swift part
  is not compiled on the Linux host (ManagedNetworkBootstrapTests covers it on macOS CI). Mac
  confirms: the next run logs that INFO line, the MLX install passes `uv sync`, and
  03_field_network reads `tls pass:trusted`; if TLS then fails with `certificate`, the company root
  is missing from the keychain. The 21:06 run confirms the cause: "Inherited SSL_CERT_FILE
  ignored" was logged, and the MLX staging that goes through the shell then downloaded every
  package. The network check, which starts the worker without the shell, still read
  `tls fail:ssl_cert_env` because its launcher was the stale one; it should clear after the
  rebuild.
- **L42** [CODE][PHYS-M] 03_field_network on the 19:47 run: `pac_download fail:failed` and
  `pac_script fail:invalid` because the PAC host (http, company intranet name) does not resolve
  off the company network; environmental, the fallback goes direct. Two defects behind the other
  values are fixed on tmp/wip-field-1947b: `route_plan fail:lookup_failed` lost the real stage
  because the port read the route role's stdout while its `STAGE` line is on stderr, so the PAC
  fallback could not apply (5d93e78e90); and the WARNING carried the company PAC URL (1dfaec8298).
  Mac confirms: the next run shows `route_plan info:direct_fallback:<stage>` or a named stage,
  and no URL in "PAC download failed". Next [CODE], once L41 is settled and direct `transfer`
  passes: report `pac_download`/`pac_script` as info when the fallback covers their failure, as
  L26 asks. The 21:06 run confirms the route fix
  (`route_plan info:direct_fallback:native_pac_download`) and a URL-free warning; `pac_download`/`pac_script` still fail off the company network, which is
  the open follow-up above, not a defect of the fixes.
- **L43** [PHYS-M] 04_field_toolchain `karabiner_signature fail:exit_1` (19:47 run). Not a
  wrong check: `karabiner_cask info:absent` only means Homebrew did not install it; Karabiner
  16.0.0 is installed from the pqrs package (its services run, karabiner.txt), so the app exists
  and `codesign --verify --deep --strict` refused it. Mac must run
  `codesign --verify --deep --strict --verbose=4 /Applications/Karabiner-Elements.app` and
  `spctl -a -vv` on it. Next
  [CODE]: carry codesign's first stderr cause as a closed token in the step value, so the report
  says why without a manual run. The 21:06 run is unchanged (`exit_1`); not Swift, so the rebuild
  will not clear it.
- **L44** Fixed 6593474037. Wake at 19:46:39 (driver booted 16:54): "Cannot refresh Karabiner
  lease liveness — no live generation exists" and "Wake refresh could not renew the exact
  Karabiner lease liveness", twice each, then the layout refresh retries of L20; nothing
  restarted the lease. Maintainer decision: re-acquire it. The controller now returns
  `no-live-generation` (INFO) and the wake handler hands that case to the bounded failure
  recovery, which refuses while the remap is disabled, paused or in a transition. Mac confirms:
  after a sleep that loses the lease, the log shows "Wake found no live Karabiner lease;
  re-acquiring it." and remapping works again without a reload. The 21:06 run's warnings (20:06,
  20:16, 21:06:41) all come from the driver that ran before the 21:06:55 reload, so the fix was
  not exercised yet.

### Expected, no defect

- **L45** Fixed b721c5c81f. "Global external writer 'Watcher reload' refused because terminal
  quiescence was not proved: true" and "Menu reload request was refused; the source-file burst
  remains pending for retry: false" (19:47:04): the clone update's file burst arrived while the
  controlled reload it had just started was fencing the lease; the reload went ahead (boot
  19:47:05). Both now log at INFO when the termination coordinator reports a reload or quit in
  progress; any other refusal still warns. Mac confirms: a `git pull` during a session logs no
  such WARNING. The 21:06:55 pair came from the driver that the reload was replacing, which
  predates the fix.

- **L35** "Ergopti driver not started in this Hammerspoon" (new.txt 11:19 to 11:21): the stock
  Hammerspoon.app started next to a standalone ErgoptiPlus; the guard kept it inert.
- **L36** "Config migration ... refused (newer)" (new.txt 15:32:19, 15:34:29): an older build met
  a config written by a newer schema and left it untouched. Linked to L20.
- **L37** Lease heartbeat answered after 1.06 s, under its 2.5 s deadline (new.txt 09:59:00): a
  main-thread hold, covered by L16 to L19.
- **L38** "Aggregate cache recovery interrupted after 267 slice(s)" (new.txt 16:28:13): the sliced
  recovery resumes at the next start by design.
- **L39** Ad hoc signing of the developer app loses the Accessibility and other grants on each
  build (`_164726`): known; `tools/build/create_macos_signing_identity.sh` gives a stable
  identity.

## Windows side to do on the PC (from October 25)

Work done on Linux and macOS only; the AHK side is built and run live on the Windows PC.

- [ ] **PRIVACY: private hotstring text reaches AI prompts on Windows.** [CODE] Fixed on macOS (private
      expansions now hidden from every prompt) and Linux (separate AI context). Read-only look at Windows:
      `_HSE_MirrorCanonicalEffectToLlm` (`hotstring_dispatch.ahk`) and `_HSE_MirrorLiteralEditToLlm`
      (`hotstring_send.ahk`) copy `Effect.InsertedText` into `_LLM_Bridge_Buffer` and the agent buffer, and the
      Effect objects from `HSE_ApplyExpansion` carry no private flag, so a phone/SSN/IBAN expansion can be sent
      to Ollama or a remote provider. Add `IsPrivate` to those Effects, clear both buffers on a private effect
      and keep appending later typing (as Linux); AHK test: a private expansion then a prediction request
      carries no secret. Do this first on the PC.
- [ ] **Hosted Windows unit failures.** [CODE] Run 40235626114 (e2aa642f8c) still fails `meta`,
      `config-scope-features`, `core` and `keymap-gestures` (likely the gesture greying, dbc29c5077);
      `hotstrings-shortcuts` passes since the second round of fixes. `test_hotstrings_scope.ahk:520` (expected 0.5, got 1.0) is
      unexplained: print `_HotstringsOverrides["autocorrection"].Sections[family]` after
      `HotstringsOverridesApplyBase()`.
- [ ] **AI off disarms the AI keys and the agent's manual actions.** [CODE] Done on Linux and macOS
      (bc2048765a, 6d96986979). Windows: `AiActionIsAi`/`AiActionBlocked` in `modules/gestures/config.ahk`;
      split `TapHoldTapAction` (`platform/remap/tap_hold_loader.ahk`) so a blocked AI tap returns the native
      tap, configured readers in `menu_taphold.ahk` and `tap_hold_writer.ahk` use the new
      `TapHoldConfiguredTapAction`; per-press gates in `TapKeyShouldFire`, `ScriptShortcutSlotRunsAction`,
      `KeyCombinationOwns`/`KeyCombinationFire`, `GestureDispatch`, `_MagicEditorBrokerWinner`; AI hotkeys
      through `HotkeyRegistrarSetEnabled` from `LLM_Menu_ActivateRuntime` and `_LLM_Menu_ApplyToggleCommitted`;
      `_LLM_Agent_ManualRefusal` passes `LLM_Menu_AiEnabled()`; `requires_ahk = ["ai:on"]` on the two agent
      actions with the codegen token and the picker greying; tests `test_ai_action_gate.ahk`,
      `test_llm_agent.ahk`, `test_llm_agent_requester.ahk`; reseal.
- [ ] **One app-category file on the three OS (PAR-34).** [CODE] Windows keeps `app_categories.json` in the
      metrics dir and accepts legacy flat string values the Lua codec refuses, and it preserves unknown
      members the codec drops. Align the location (decision pending), the record shape and the score range,
      and replay `_shared/tests/corpus/metrics/app_category_store_vectors.json` in AHK.
- [ ] **AI off disarms the agent's automatic mode.** [CODE] Done on Linux and macOS (e284077ba9). Windows:
      the AHK agent runner arms no typing pause and refuses a triage or request in flight while the AI is
      off, cancels the pause at the switch-off and re-arms on the next keystroke; rewrite
      `test_llm_agent_ai_off.ahk` (it feeds the agent with the AI off on purpose) to assert that.
- [ ] **Release notes in the update-check window (PAR-52).** [CODE] `windows/ui/update_check/init.ahk`:
      seed `state.notes = {body, owner, repo}` in the `available` message (from `UPDATER_LATEST_RELEASE.Body`,
      `UPDATER_GH_OWNER`, `UPDATER_GH_REPO`, as `_Updater_ReleaseNotesSeed`), serve `open_url` in the
      `available` phase through the allowlist behind `_Updater_OpenManualUrl`, add `"open_url", "available"` to
      `UC_PAGE_ACTIONS`, then drop `open_url:available` from `luaHostsOnly` in
      `tools/test/test-update-check-dialog.cjs`.

## Decisions of 2026-10-26 to implement (docs/questions-for-maintainer.md)

- [x] **Slow-segment threshold 5 ms on macOS and Linux.** [CODE] Done (`[logger] hotpath_slow_ms`); Windows reader left.
- [ ] **Versioned `tap_hold.toml` migrator.** [CODE] Linux done (`_shared/tap_hold/migrations.toml`,
      macOS has no tap_hold.toml); in progress: byte-preserving rewrite (agent AE); Windows side on the PC.
- [x] **Linux crash: notification only.** [CODE] Done; Windows dead crash kind left.
- [x] **Linux Quit refusals as macOS.** [CODE] Done (shared `quit_admission.lua`; Quit wins over a reload and waits
      for a running write, 59e20c6b0a); Windows on the PC (PAR-45).
- [x] **14 hotstring colours on the three OS.** [CODE] Done (`native_theme.toml`); Windows reader left.
- [x] **Retire `_shared/ui/metrics_apps/script.js`.** [CODE] Done; the "general" alias folding is in the live modules
      (81635a815a).
- [x] **Dedicated AI-off hint string.** [CODE] [I18N] Done (`dialog.action_picker.requires_ai`); Windows reader left.
- [ ] **Registry op that re-encodes a value.** [CODE] Windows `config_migrate.ahk` first (PC), then the Lua
      engines, then delete the macOS `[llm.profiles] user_profiles` reader import (0146a938c5).
- [x] **Prediction request floor.** [CODE] Explicit requests never wait for the floor; one global floor
      settable from the menu on the three OS; "never" debounce on the three OS; live mode instant at a word end;
      the variants of one request never wait; default 300 ms, 0 accepted; a mashed explicit shortcut supersedes
      its in-flight request. macOS and Linux: done and checked part by part (88b27a94c1 to 5c36a116cd,
      fcaec1a91c, 8fce07aa86, 928bca090e, 15ceb9e044). Windows on the PC (see the counterparts list).
- [x] **PAR-66 section readers.** [CODE] Done (4c9a672215, 0747800cfc; gates pin the shared text). Re-point the source-pin gates to the shared module, then extract
      `personal_info_editor_source` and the metrics/configuration/debug/about readers.

## Integration pass of 2026-10-24 evening: what landed and what is left

A coordinator session ran a parallel pass on the parity and performance items. Its work is now on `dev` (about 495
commits). Its CI run was cancelled, so no release was cut. The `agent/*` and `fix/*` branches on origin could not be deleted from the session (the proxy refuses branch deletion): delete them by hand, since all their commits are on `dev`.

**Landed.** 9 cloud worker branches:

- Linux CI lanes, AppImage distribution matrix, Linux perf probe.
- macOS Lua perf (TOML scan reuse, ASCII fold), macOS stubbed suite health, Windows AHK suite under Wine.
- PAR-19, PAR-22/34/40, PAR-30 (first commit), PAR-59/63/64, PAR-67, PAR-71, PAR-73/77, PAR-74/84.

14 local agent branches:

- The health fixes, the Linux perf commits (in-process `find` replacements), PAR-21 (part).
- PAR-44/45/52 (part), PAR-53..57 (part), PAR-60..62 (part), PAR-65 (part), PAR-68/72 (part).
- PAR-69 and PAR-70 (one of nine), PAR-75, PAR-81 (part), PAR-12/37/48 (part), PAR-78..80 (part), PAR-82/83/85 (part).

The three `fix/*` branches: fix/linux 36 commits, fix/macos 31 commits, fix/windows 269 of its 273 commits (the other
four were already on dev).

**Measured on this container (stubbed suites).**

- macOS: 484 failures on the previous `dev`, 68 after integration.
- Linux: 18 failures after integration (the agents reported 85 on the previous `dev`).
- `npm run test:js` loads again; the duplicate ordinals and ids were renumbered.
- `node tools/test/verify-change.cjs` is still red in this container: openbox, native Nix admission and Unicode 17 are
  missing here.
- Nothing native (AHK, Hammerspoon, a real desktop) was executed except the AHK suites under Wine.

**Integration resolutions to review.** These are conflicts between branches that each counted from a base without the
other:

- `test-linux-e2e-shards.cjs` 180 steps, and `test-ci-full-default.cjs` 185 slots: the Go route plan twin plus the
  split install steps.
- The reason ratchet ledger in `test-platform-restrictions-explained.cjs` (3): `llm.user_profiles` and
  `auto_profile_for_model` should be opened to macOS.
- The duplicate-constant-name baseline shrank by two.
- `windows/infra/input_probe.ahk`: the owner and admission rewrite from fix/windows, combined with dev's
  `WMPresentWindow` and `_IP_TargetReady`. **Not executed: run it on the PC.**
- The keystats aggregation corpus test now follows the shared walker from PAR-67.
- Duplicate fixes for the LuaJIT 60-upvalue limit of `main()` (three agents) were dropped in favour of the first one.

**Left, not committed when the agents stopped.** Their worktrees were removed; redo each item from its PAR entry:

- PAR-53..57: the instrumentation inventory, Lua driver sections and the macOS boot profiler tests.
- PAR-75: the macOS adapters migration.
- PAR-66: the menu frames, entirely.
- PAR-82/83/85: the Lua reader migrations of the UI-string gate.
- PAR-44/45/52: the release-notes and update-check pages, and the notes contract.
- PAR-65: the request plan in both prediction engines.
- PAR-68/72: the Linux and macOS readers of the shared hotstring config.
- PAR-78..80: the `[limits]` rules of the timing gate.
- PAR-12/37/48: the locale and translation-audit part.
- PAR-60..62: the sequence-corpus commit and the macOS harness edits.
- PAR-81: the computed-style comparison.
- fix/windows: the keylogger publication owner tests.
- Cloud sessions stopped mid-task:
  - PAR-73/77 (features manifest text consumers);
  - PAR-74/84 (Lua dotted-key migration);
  - macOS stubbed suite health (about 68 reds left);
  - Linux perf lab (boot-stage timings);
  - Windows AHK under Wine (triage of its reds).
- Not started: PAR-14 (Windows), PAR-43, PAR-58, PAR-76, the Windows managed Ollama route plan consumer, the PAR-71
  proxy-precedence ratchet to zero, and the Wave 2 and backlog remainders.

**How the work was split, and what to keep.**

- **Split by file ownership, not by todo item.** Each agent owned one surface (a driver area or a shared module) and
  the items that touch it, so two agents rarely edited the same file. The coordinator alone edited this todo, integrated
  and pushed. Each agent had its own branch and wrote a final report: commits, done and left per item, gates, what was
  not executed.
- **Shared registries collide.** These grow at the end in every branch: `tools/test/features/*/suite.json` (global
  ordinals and `js-NNNN` ids), `linux/tests/test_manifest.lua`, CI step and slot counts, ratchet baselines, the sealed
  updater inputs. Give each agent a reserved ordinal range up front, or integrate often. Regenerate generated files
  and reseal once after integration, never by hand.
- **Land early and often.** One branch every half hour, rebased onto `dev`, with one push and its CI cancelled, is far
  cheaper than 30 branches at the end.
- **Size the pass to the quota.** About 30 parallel agents (18 local, 12 cloud) used the whole five-hour allowance in
  about 20 minutes. Stay at 4 to 6 parallel agents. Resume a stopped agent within the hour, while its prompt cache is
  warm; after that, harvest its commits instead of reloading its context.
- **Specialised containers worth reusing.**
  - A Wine container that runs the Windows AHK suites on Linux (`tools/test/run-ahk-under-wine.sh`, UTF-8 locale):
    Windows checks no longer need the PC for everything that is not input or GUI.
  - A distribution container matrix that launches the AppImage (Ubuntu 20.04 to 26.04, Debian, Fedora, openSUSE,
    Arch, Alpine).
  - A Linux perf lab (startup module graph probe, boot-stage timings).
  - A macOS pure-Lua profiling container (stubbed Hammerspoon).
  - A Linux CI-lanes container that runs every step of the hosted Ubuntu jobs locally.
  - One review pass with three lenses (correctness, contracts, integration), each finding checked by two skeptics,
    before landing.

## Handover of 2026-10-24: where we stand and how to continue

Written at the end of a long multi-agent session. Read this first, then the item you pick.

**State of the repository.** About 140 local commits on `dev` are NOT pushed (the last push to `origin/dev` was
7099eb93ef). Pushing `dev` needs the maintainer's explicit go-ahead in the current conversation (AGENTS.md); a push
cuts a release unless the run is cancelled, so cancel the CI run of each push (`gh run cancel`). No release was cut and
`main` was not touched. Before the first push: integrate the shared JSON (see "Integration checklist"), run
`node tools/lint/lint-conventions.js`, the three AHK boot checks and the targeted gates of the items you touched.

**What was done in this session (details in `git log` and in the items).** Keystats rename (keylogger gone); issue #101
fixes (ATS key for an http PAC, direct route when the PAC lookup names no route, named lookup stages, no retry of a
refused route, lease line cap, Ollama 412 upgrade request; later: PAC-then-direct fallback on macOS, see "PAC unusable:
direct fallback"); WinHTTP transport (item 62); per-layer layout composer on the
three OS; hotstring expansion delay defined once and aligned (shared corpus `time_gate_vectors.json`, definition in
`docs/memory/text-input-and-config.md`); chaining pinned by tests (buffer continuity, `test_hotstring_chaining.ahk`);
Space tap-hold press tick; HS-274 owned Karabiner runtime (dormant, hidden `[karabiner] runtime = "owned"`); one-click
Debug field checks on all OS; evidence log API that is never collapsed (`LoggerEvidence`, `Logger.evidence`); redaction
rules and the opt-in redacted day log; AV-surface gate and the false-positive submission pack; CI tooling (rerun verdict,
Flatpak cache and retry, remap-runtime workflow, slowest-test summary); performance work (below); cross-OS parity audit
(PAR entries). Hosted validation on throwaway `tmp/ci-validate-*` branches is logged in
[ci-validation-2026-10-24.md](ci-validation-2026-10-24.md).

**Performance state per OS (measure before optimising; every driver now has permanent counters).**

- Windows: boot to ready 13.6 s to about 8.4 s, tray menu stage 2.6 s to 1.2 s, focus cache event driven. Next: remaining
  registry compares (about 28 write-admission callers), `Hook.KeyDown` attribution (sampled subscriber timings are in;
  read the next live log), `Tooltip.Build` 7.6 ms and `Present` 10.6 ms, layout registration (about 1 s of `Hotkey()`
  calls), the 2 s script parse (9.7 MB include graph, no safe lever found), typst/emoji hotstring sections (about 460 ms).
- Linux: idle loop 99.99 % of a core to 1.5 %, X11 focus without forks, TOML about 2x faster. Next: 315 eagerly loaded
  modules (about 500 ms), five `find` forks in the hotstring loader, log rotation forks in `logger_sink.lua`, validate
  idle CPU and the libxcb focus path on a real desktop.
- macOS: instrumentation only (`infra/phase_stats.lua`, menu per row, boot sub-stages, hold attribution). Next: read the
  Mac log lines listed in "Mac field test" and optimise the dominant phases (menu rebuild 113-247 ms, boot stages,
  preview 21-29 ms per key, preferences writes of 300 operations, ingest tick 1.0-1.5 s).

**Maintainer decisions taken (do not re-ask).** Hotstring chaining is buffer continuity and already works; it is pinned
by tests, never break it. Shared complex-key multiplier on all three OS (PAR-7). Layout pause/resume implemented on
Windows and Linux (PAR-19). Tap-hold and key-combination defaults identical on all OS except real role differences,
each with a stated reason (PAR-17). Linux reload through a TTL-bound pending-record protocol shared by the three OS.
Preview switches default ON everywhere, notifications aligned on macOS, WPM defaults off (coordinator choices, ask for
review). libXi dependency declined (Xi packet retired). Items 46/47/48 retired except the macOS Ollama termination debt
(120). Optional redacted day log allowed; config-directory names masked in logs. Item 131 is a read-only login-items
check, no removal. No token-reuse rearm (ADR 012). Expansion delay with end char: from the last typed letter to the
expander (`★` or the end character).

**Decisions still pending for the maintainer.** `docs/questions-for-maintainer.md` (check it for anything new). The 2026-10-24 QCM answers are implemented (October 25): PAR-6, PAR-8, PAR-15, PAR-21, PAR-24, hotstring cascading, Space tap completion, the recommended-defaults rule and AI off on Linux. Still open: the content-Gui pool of the Windows prediction tooltip, PAR-12 on the PC.

**Remaining work, in the order to take it.**

1. Integrate and push (see checklist), then run the FULL suites once on the final tree: `node tools/test/verify-change.cjs`
   (about an hour with parallel agents idle) and the full AHK suite (about 90 minutes, single threaded, nothing else
   running: `run_all.ahk` is `#SingleInstance Force`, concurrent runs silently kill each other). Fix only reds caused by
   our changes (hosts reds: Node 22.16 vs pinned 22.22.2, Unicode 16, no pwsh, no lfs, `build:linux`, Windows file staging).
   Known red to chase first: live check `reload-click-joins` ("second click not logged as joined") failed at the end of the
   session after it passed at 1254dd7bd7; the joined-click log line comes from `menu_dispatcher.ahk`; suspects: the
   driver_control pending-record work (d682fa6995) or the perf commits; run
   `node tools/maintainer/windows-live-checks.cjs --only reload-click-joins` with no other AutoHotkey process, bisect with
   `git archive` exports (no worktree).
2. Hosted CI on the final source: `gh workflow run ci.yml --ref tmp/preflight-dev -f os_lanes=all` (only after every
   piece passed alone; macOS runners are expensive). Then the CI receipts section.
3. The cross-OS parity entries `PAR-1` to `PAR-85` below: unfinished ones are those not marked done; centralisation and
   constants (PAR-65 to PAR-85) were not started: one declaration in `_shared` per constant, delay, colour, label;
   hexagonal architecture (rules and ports in `_shared`, OS code only in adapters); each with a single-source gate.
4. Performance items above, on each OS; then re-measure with the permanent counters and keep the numbers in the commits.
5. Items that need devices or the maintainer: see "Mac field test", "Windows PC field test", SignPath application,
   Microsoft/vendor submissions, tester retests, the maintainer checks sections.

**Mac field test (after a release or a local build of this tree).** Debug menu, one click each, then Copy report and
send the log lines `Field check result:`: Test Karabiner lease, Test owned Karabiner runtime (dormant check), Test
network (PAC, proxy, download), Test key accounting (30 s while typing), login items and agents, toolchain (timer,
Shortcuts, Homebrew, Karabiner signature), Test the composed layout. Also bring back after an hour of normal use:
`Phase summary [family]` (keymap, preview, menu, menu_item, toml, process, boot_sub, hotstring_load, runtime, hotpath),
`Menu tree rebuilt ... Slowest:`, `Boot stage requires:`, `Boot sub-stage:`, `Common hotstring load:`, every
`held the main thread ... Phases inside the hold:`, `Slow ingest tick`, `Slow preferences save`,
`Lease token decision=`, `written in N ms`, `Memory snapshot`. Confirm on the Mac: an http company PAC works (issue
#101), `pr` + Space style triggers, the ISO/ANSI selector (Automatic/ISO/ANSI) with a physical keyboard, the
menu-triggered redeploy.

**Windows PC field test.** Reload the driver from the working tree only when the tree parses (the three boot checks);
then run `node tools/maintainer/windows-live-checks.cjs` with NO other AutoHotkey process running (SendInput falls back
to SendEvent when another script has a keyboard hook, and the real-key checks refuse to run next to another driver);
Debug > Record keyboard hook order (expect the native owner first again after the reassertion) and Measure SendEvent vs
SendInput on a quiet machine; the manual lists in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md).

**Integration checklist (shared files other agents leave uncommitted, because the pre-commit hook rejects a partially
staged `.json`).** `static/ergopti_plus/_shared/data/locales/*.json` (21 files), `_shared/modules/menu/menu_manifest.json`
(regenerate with `npm run build:domain`; `codegen-unicode-case` fails on this host, ignore that step),
`_shared/modules/diagnostics/schema.json`, `_shared/modules/features/manifest.toml`, `_shared/ui/layout_manager/strings.json`,
`windows/tests/run_all.ahk` (includes for tests whose files already exist: capsword state, composer check, new live
tests), `package.json` (npm aliases such as `test:remap-runtime-manifest`, `test:neutral-installation`), the test suite
registries under `tools/test/features/*/suite.json` (renumber clashing ids), `docs/memory/*.md` entries listed by the
agents. After integrating: `python tools/locale/check_locales.py`, `node tools/test/test-menu-manifest.cjs`,
`test-approved-menu-labels.cjs`, `test-diagnostic-ui-integrity.cjs`, `npm run test:ci-pipeline-wiring`. Reseal the
updater original source after any change to a pinned file:
`node tools/ci/seal-windows-updater-original-source.cjs --ref <commit> --write` (only when `run_all.ahk` is clean).

**Hazards learned.** One lint violation in anyone's new file blocks every commit (the hook lints the whole repo):
run the lint after every save. A half-saved `.ahk` file breaks the maintainer's live driver (reloads come from the
working tree): edit a copy and move it in when it parses. Committing through a temporary index leaves the real index
stale: run `git status` before a plain commit and reset only your own paths. `wsl --shutdown` kills other agents' WSL
jobs and clears `/tmp`: do not run it while others work. Never type backslashes through bash heredocs or python text
mode (use the Write/Edit tools). Test the Windows pieces for real on the maintainer's PC (everything Windows can be run
here); macOS and Linux behaviour that needs hardware goes through the Debug field checks and the maintainer's logs.

## Big item 1: Windows corporate networks and trust (items 62, 132)

- [ ] **62. WinHTTP transport for the managed remote downloads.** [CODE] Done (1d15b51e66, 7c001b2456
      and the following commits): managed requests, updater artifact download and Ollama archive
      download use WinHTTP (`vendor/ergopti_winhttp_transport.ps1`, worker
      `ergopti_managed_http_worker.ps1`); `curl.exe` stays only for loopback Ollama. Proven on this PC
      against owned loopback services with real SSPI NTLM and Negotiate proxies, CONNECT, untrusted
      TLS, bounds, deadlines and PAC failover. Left: the native CA cases (a click on the Windows
      security warning or an elevated LocalMachine scope), enterprise acceptance behind a real
      proxy/PAC (Kerberos, TLS inspection, revocation) through Debug > diagnostics (`github_api`,
      `proxy_pac`), and item 36 (external trusted binding).
- [ ] **132. SignPath Foundation signing.** [CODE] Apply, integrate Windows signing, then delete
      `.github/ci/stable_windows_signing_exception.json`. Before applying, check the current
      conditions on signpath.org/foundation (open-source license, public repository, build and
      signing from CI with a maintainer approval per signing request, a published code-signing
      policy and privacy statement, a reputable project; the keystats-like metrics module and the
      hooks need a clear explanation). Decided 2026-10-22: apply now. Done: SignPath wired in
      `ci-windows.yml`, off until configured (61fb29d64d); README code signing policy and privacy
      (c6db589c76). Left (maintainer): apply, then set the variables and secrets; eligibility table,
      form answers and switch-on steps in the
      [handoff](todo-agents/signpath-foundation-application.md).
- [ ] **`ErgoptiPlus.exe` flagged by a corporate proxy (Netskope, Airbus tester).** [CODE] [PHYS-W]
      Done: no hidden PowerShell clipboard stage, own version resource, English metadata, tar.exe
      extraction, the keylogger naming gone (keystats rename; the gate forbids `keylog` in the script
      and the bundle), string-surface ceilings and a per-build record with the exe SHA-256 in CI
      (e2c9dfb79d), the submission pack
      [windows-exe-false-positive-submission-pack.md](todo-agents/windows-exe-false-positive-submission-pack.md).
      Left (maintainer): signing (132), VirusTotal lookup, Microsoft and vendor submissions, the
      tester's block page and retry (T1-T4); decide whether the `WH_KEYBOARD_LL` probe in
      `input_probe.ahk` stays in the release exe. Playbook:
      [handoff](todo-agents/windows-exe-flagged-by-proxy.md).

## Big item 2: macOS Karabiner input reliability (items 31, 117, 140)

- [ ] **117/140. Karabiner lease failures on Apple silicon.** [PHYS-M] Exit 73, PONG/READY
      timeouts since dev.155. The lease budgets are ordered so a slow CLI keeps the lease, every
      exit 73 names its cause, each deploy decision is one INFO line (recovery deploys wait for a
      typing pause; an unchanged `karabiner.json` is never republished), and the lookup that froze
      the main thread 13 s is gone (0292ec401d, e57f4cce77). Issue #100: on-time deadlines fired
      while the Ergopti menu was open, because `hs.task` streaming output is read only in the
      default run loop mode; an on-time deadline now waits for a `/bin/cat` echo before judging the
      worker (25411ee080, after v1.0.5). Reproduce on the Mac with these log lines; the only
      workaround is Configuration > Ergopti uses Karabiner > Off. Recovery deploys (28 of 33 on
      2026-10-19) cannot be reduced without fewer lease failures. Leftovers:
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Dropped letters on macOS.** [PHYS-M] Unproven. Every consumed and never delivered key is
      reported ("typed key(s) swallowed", decisions only, never the key). Mac action: Debug > Report
      a bug right when a letter disappears, then compare with lease failures or Karabiner deploys.
- [ ] **31. HS-274 exact physical key accounting with an owned Karabiner runtime.** [CODE] Work
      packages WP3-WP10 (production consumer, headless producer v2, reproducible runtime, launchd
      ownership, owned configuration, native and real-Mac acceptance, enable and retire); media keys
      without a macOS keycode; VirtualHIDDevice incompatibility blocks owned mode with an
      explanation. Plan: [ADR 011](../static/ergopti_plus/docs/adr/011-owned-karabiner-runtime.md).
      Estimate 30-40 agent-days plus hardware time. The owned runtime stays dormant at default
      startup.
      Status 2026-10-24: WP3 largely done and dormant; WP6 Lua owner (`runtime_owner.lua`,
      `runtime_vhid.lua`, read-only ports) and WP7 owned deploy done, dormant behind the hidden
      `[karabiner] runtime = "owned"`; one-click Debug field checks shipped (lease, owned runtime
      dormancy, network, 30 s key accounting). Left: WP5 artifact manifest (hosted macOS run), a
      closer for another running Karabiner, the production capture owner, the Swift lease worker's
      owned CLI path, who starts the Console (Lua or `InstalledPhysicalSourceBridge`: duplicates
      otherwise), `UninstallWorker.swift`, the karabiner_model diff 16.0.0 to 9312593e, WP8-WP10.
      Next: the maintainer sends the `Field check result:` log lines from the Mac.

## Big item 3: Windows input-hook architecture (items 49, 91, 50)

- [ ] **49. Keyboard-hook order.** [PHYS-W] [CODE] AutoHotkey removes and reinstalls its low-level
      hook around SendInput, so hook order is undefined. Record the real order before and after a
      SendInput rehook; audit terminal capture against KLE, dead-key, digit, profile, tap-hold,
      combination and script-shortcut consumers (down, repeat, up, owner change while held, pause,
      reload); finish event-specific capture and replay and modifier ownership (source pin,
      authenticated event stream, non-hook handler conversion, chained/repeat semantics). Regenerate
      the DLL and manifest only through the official MSVC generator; check the patches in
      `docs/handovers/2026-10-12-dev-consolidation/` against the tree first.
      Measured on the maintainer's PC (Debug > Record keyboard hook order, 2026-10-24): before a
      SendInput the test hook is first; after it the AutoHotkey hook is first, so SendInput does
      reinstall the AutoHotkey hook in front of any hook installed earlier. SendEvent does not
      (item 50: hotstring output already uses SendInput at level 0, so it is exposed to this rehook). Consumers that rely on their own hook staying ahead of AutoHotkey's (the
      native nav owner DLL, item 91) lose that position at the first SendInput of the other paths.
      Consumer audit:
      [windows-input-hooks-items-49-50.md](todo-agents/windows-input-hooks-items-49-50.md). Left:
      decide per remaining SendInput consumer (text sender, HSE dispatch) whether it can avoid
      SendInput or make the consumer order-independent (single-hook/RawInput source, needs an MSVC
      DLL and manifest); the terminal-capture hardware list; the `SetWindowsHookExW` string in the
      exe for antivirus (the AV-surface gate allows it).
- [ ] **91. Simultaneous and first-key hold arbitration.** [CODE] Integrate with the
      single-hook/RawInput source (needs a genuine MSVC DLL and manifest pair); [PHYS-W]
      held-alone-then-joined order, AltGr hook provenance.
- [ ] **50. SendEvent against SendInput.** [PHYS-W] `SendMode("Event")` is set, yet the hotstring
      send/dispatch, text sender and config I/O still call SendInput. Measure expansions, pastes and
      predictions (latency, lost or interleaved keys) before choosing.
      Measured on the maintainer's PC (8 repetitions per scenario, all exact, 0 lost, 0 interleaved in
      both modes): expansion median 50.6 ms (SendInput) vs 136.8 ms (SendEvent), prediction 56.1 vs
      191.0 ms, paste 3.6 vs 3.8 ms, a concurrent key during the send 201 vs 282 ms. \*\*Finding
      (2026-10-24, real engine on the maintainer's PC): hotstring expansion already used SendInput
      (`HSE_DispatchMatch`); there are no native `Hotstring()` registrations left, so a hotstring's
      output is final on every driver and does not trigger another hotstring (the comment on
      `SendMode("Event")` described the retired native engine; `SendMode` now only affects `Send`,
      `Click`, `MouseMove`). One real bug fixed (0c85debc93): the Space tap-hold completed a trigger
      from its level-2 thread, and with another AutoHotkey hook SendInput fell back to SendEvent, so
      the burst re-entered the watcher and cascaded (final text `foo qbar qzz` instead of
      `foo qzy `); all engine output now goes at level 0. Deliberate cascading is built (858c9aa, 0746b18c86):
      `hotstrings.cascade_max_arrows` counts arrows (1 = one expansion, 2 = a > b > c), default 3,
      range 1 to 10, the whole chain resolved before one send (one SendInput burst on Windows), a rule
      fires once per chain, a link fires only where typing the same text would; the typed delimiter
      lands once after the final output unless the user marked it consumed (★ ships consumed).
      Space tap completes an end-character trigger like a plain space on the three drivers (Windows
      already via `TextPressKeyFed`, Linux pinned by 504ee63, macOS emits a native space).
      `test_hotstring_output_is_final.ahk` is already in `run_all.ahk`. Left: on each OS type `fb` + Space,
      Enter and ★ with the abbreviation and brand packs, at 1, 2 and 3 arrows, consumed and not.
- [ ] **Per-layer layout composer.** [CODE] Done on the three OS (docs/layout-composer.md): shared
      model, page, 21 locales, Windows host, macOS and Linux install paths, tests, one-click Debug
      "Test the composed layout". Left: typing the composed layout on a real keyboard on each OS.

## Wave 2: mid-size work

In progress (agent), October 22:

- [ ] **Windows config policy (items 33, 42) and the TOML parse cost.** [CODE] Per sub-item in
      [config-policy-33-42.md](todo-agents/config-policy-33-42.md); 33: Windows keyboard binding
      publication from its real input owner, macOS Hotstrings category authority, Linux retired
      API-provider reader, macOS Karabiner obsolete-leaf intent, Windows retired cleanup
      projections; 42: explicit `--config FILE.toml` watcher admission, Windows full-save comment
      preservation. Parse cost: every document-mode write parses source, expected model and final
      candidate, and every start pays two builds after ready; reuse one parse per transaction
      before adding any cache. **In progress (agent).**

Not started:

- [ ] **Ollama redirect policy and Go compile (decision 5).** [CODE] [CI] Code done (cda1e10c5e): an
      unresolved download host is left to the proxy or the native worker; private, loopback,
      link-local and CGNAT addresses and names resolving to them stay refused; the build recipe
      patches upstream `ValidateRedirectTarget`. The hosted Go cell (`go vet`, `go test` through
      `build-macos-managed-ollama.py`) passed on a throwaway branch (run 40021624397, see
      [ci-validation-2026-10-24.md](ci-validation-2026-10-24.md)). Left: the same cell on the final
      source before a release.
- [x] **54/81. Last three native Windows menu rows.** Done in 02b63912f1 (local): census Windows
      0, macOS 0, Linux 0. The default-section, file and folder submenus are renderer template
      children (`MenuRenderer_TemplateChild` reserves, `MenuRenderer_FillTemplateChild` fills,
      `MenuRenderer_RepaintTemplateChild` repaints only a child the renderer still publishes); a
      kept callback after a rebuild is now refused before any write. Left: manual check 17
      (installed menus, default choice after restart); the shared-tree census is red on Linux only
      while `linux/ui/menu/rebuild_owner.lua:39` (another agent's uncommitted edit) is in flight.
- [ ] **Ergopti-started Ollama behind a PAC proxy.** [CODE] Linux done (89d22d782c, fake-lookup
      tests). macOS in code (launcher role `--managed-proxy-route`, 06addb2e3f; per-origin route
      plan 1fd254d92e and 749e00c4c8); Swift compiled and tested on the hosted macOS cell. Windows
      is covered by the WinHTTP transport (62). Left: a real-PAC pull on the maintainer's Mac (Debug >
      Test network), the Ollama blob host inventory check, a `route_plan` step in the network check.
      The daemon start now looks up every inventory origin (it read only the single-origin variable,
      so `pac_probe_client = "ollama"` never resolved at start; fixed with the fallback below).
- [ ] **PAC unusable: direct fallback (maintainer decision).** [CODE] [PHYS-M] macOS done on branch
      `tmp/wip-pac-fallback`: when the PAC or WPAD route lookup fails at a stage listed in
      `proxy_policy.json` `pac_unavailable_fallback` (PAC download, evaluation, WPAD discovery, lookup
      budget, empty route), `network-retry.sh`, the Swift spool and native worker, and the Python
      receiver go direct (no relay, loopback exclusions kept) with one WARNING naming the stage, then
      log that the direct connection worked or an error naming both causes; the Ollama pull shows
      `network.failure.pac_unreachable_direct_failed`; the Debug network check reports the lookup as
      `info direct_pac_download` (or the stage met). Decision: an explicit inherited relay
      (`HTTPS_PROXY` and the others) wins and never falls back; a relay the PAC names that then fails
      is NOT retried direct (only the PAC's own list, such as `PROXY a; DIRECT`, is followed), on
      every OS. Mac must confirm: on the company network, an Ollama pull and the MLX install log the
      WARNING with `native_pac_download` or `native_pac_evaluation`, then the direct success line (or
      the two-cause error), Debug > Test network shows the `route_lookup` info step, and the Swift
      change compiles in the macOS cell. Deferred: Linux (`managed_ollama_proxy.lua` still refuses
      with `runtime_proxy_unavailable`) and Windows (`ergopti_network_routes.ps1` still refuses with
      `pac_failed` or `wpad_failed`) must follow the same policy.
- [x] **Menu clicks during a reload.** Done (b0fb0f585b, c280aa4eaf, 8c4314524a, d8f6fbf1d2): a click
      is held during a reload and replayed with its intended state; a Reload click during a reload
      JOINS it (Linux and macOS; Windows in the standing-checks agent's work, see PAR entries); Linux
      reports a refused `load_all` truthfully; the ordered-pair test runs in 8 s.
- [ ] **AppImage self-contained.** [CODE] `.zsync` and update information are done (10c016e51f,
      6fb83014e3). Built on ubuntu:22.04 (glibc 2.35 floor, no bundled libc or loader, musl refused in words,
      tray closure kept); the build refuses a foreign loader or a staged C library (dce846a0bd). Left: hosted
      CI evidence of the Build and `install-linux` AppImage rows on the distro matrix.
- [x] **Linux `copy_selected_path` in a file manager.** Done (8edb31edba, d2a7bc9c5b, 3027faffd3: the
      AT-SPI active frame names the application under Wayland). Left: confirm the AT-SPI query on a
      real GNOME or KDE Wayland desktop. Unicode IDNs and a zoned IPv6 are searched, not opened.
- [ ] **Linux X11 window list.** [CODE] `getAll()` is covered by the Openbox receipts (962a25a973);
      confirm in the first hosted run. Flatpak: wmctrl is only a documented host program.

## Cross-OS parity, centralisation and constants (audit of 2026-10-24)

Maintainer rule: the same behaviour on Windows, macOS and Linux wherever possible, unless there is a
good reason stated in the menu reason text; everything that can be common lives in `_shared`
(hexagonal architecture: rules and ports in `_shared`, OS code only in adapters); every constant,
delay, colour and label has one declaration. Source: [audit](audits/2026-10-24-cross-os-parity.md)
(row ids `H1`, `R3`, ... refer to it); entries are `PAR-1` to `PAR-85`, stable ids. Rows tagged I in the
audit come from grep counts: confirm them before starting. Done and verified: about 35 entries (see git log); the list below is what remains. Decisions taken: PAR-7 shared multiplier, PAR-17 identical defaults with stated exceptions, PAR-19 implement on Windows and Linux.

### A. Behaviour that differs without a good reason (fix first)

- [ ] **Tests write the real user config.** [CODE] Fixed (the magic-key catalogue test, and both Lua
      runners now move a real HOME to a scratch dir, `_shared/lua/test/runner_home.lua`). The keystats
      tests own their HOME fixture (29b7c5a0fe). Left: on Lua 5.4 an `io.popen` child still sees the real
      HOME.
- [ ] **Retire the orphaned Windows gesture-notice entries.** [CODE] The gesture status submenu and notice
      are gone (dbc29c5077); the `gesture_conflict_dismissed.*` storage entries they wrote stay in user
      state. Remove them in a config migration.
- [ ] **Review the machine translations of October 25.** [I18N] New keys (gesture recommendation notes,
      cascade depth, tap-hold defaults, missing-program messages) are hand-written in French and
      machine-written in the 19 other locales.
- [ ] **PAR-6. Make the base expansion delay user-settable on all three.** [CODE] Done (a737049): the
      base is user-settable everywhere, section delays are stored as `delay_offset` or `delay_unlimited`,
      old absolute values migrate keeping the effective delay, shared vectors `base_delay_vectors.json`.
      Left: run the Windows corpus test on the PC.
- [ ] **PAR-8. Word delimiters in config leaves on Windows.** [CODE] Done: the consume choice is the
      leaf `[hotstrings.terminator_consume]` on macOS and Linux (76716e7); Windows writes built-in states
      through the live config writer and moves the old override strings at boot (2d734b6). Left: run the
      rewritten AHK tests on the PC (never executed); no menu toggle for built-in consumption on any
      driver; macOS and Linux still ignore user delimiters when deciding a repeat.
- [ ] **PAR-12. Token streaming reason.** [CODE] Done: reason text rewritten in 21 locales and the key renamed
      `token_streaming_unvalidated_on_windows`. Left [PC]: enable the row on Windows after a live Ollama check.
- [ ] **PAR-14. Check-only fallback when the GitHub API is blocked: Windows.** [CODE] Linux and shared
      pieces done (28bdd5a5d9, vectors `check_only_vectors.json` and `list_cache_vectors.json`). Windows
      needs the Atom fallback in `core.ahk` plus an AHK feed parser, then a reseal of the sealed updater
      sources (only when `run_all.ahk` has no foreign hunk).
- [ ] **PAR-15. Tap-hold thresholds.** [CODE] Done: exact per-key thresholds pinned, one one-shot timeout
      (macOS read 3000 against 2000 ms), Linux holds the key's own side. macOS reads the shared per-key
      thresholds too (8cb8f04); one fallback `default_activation_ms = 200` (macOS was 250). Left: Windows
      still holds a 0.2 literal pinned to it by a gate; check the Karabiner JSON on a Mac.
- [x] **PAR-19. Pause and resume of the layout, implement on Windows and Linux (decided).** [CODE] Done on
      the three OS (shared `pause_switch_policy.lua` and contract; Linux gsettings and `setxkbmap` adapter;
      Windows `pause_layout_switch.ahk`). Left: a live check on GNOME, X11 and Windows.

### B. Missing features on one OS

- [x] **PAR-21. Linux LLM parity batch.** [CODE] Done: per-app trigger disabling (5b66b7e761), min/max
      words rows, model delete (`http_client.delete_owned`, `model_delete.lua`), warmup (`warmup.lua`), a
      separate AI typing context with `llm.generation.reset_on_nav` (e934ae45c8, shared `context_buffer`).
      Private expansions clear that context; macOS and Windows are being checked for the same exposure. AI off
      disarms the automatic agent mode and every AI key (7735e6b, 47ca337, bc2048765a).
- [x] **PAR-22. LLM telemetry on Linux.** [CODE] Done: generation, suggested, dismissed, accepted rows in
      `events_llm`, Ollama token counts (928aeffd43), remote-provider tokens and cost through the shared
      `remote_response_classifier.lua` and `remote_usage_vectors.json`. Left: check the dashboard cost with a
      real provider.
- [ ] **PAR-30. Sign the Windows and Linux update assets.** [CODE] [CI] Done: ECDSA P-256 detached signatures
      over a record of asset name, size and SHA-256, signer and reference verifier
      (`tools/build/update-asset-signature.cjs`), Linux verifies with OpenSSL, Windows with CNG, shared
      vectors, CI signs the Windows exe and publishes the `.sig`. Linux transfer flow done (cd824ccf8e:
      `signature_gate.lua` fetches the `.sig` and verifies after adoption; no separate "warn" value, a bad
      signature is logged in words while enforcement is "off"); macOS needs nothing beyond Sparkle's EdDSA
      and the release-installer SHA-256 plus designated requirement. Left: the Windows `release_install`/`self_update` path (enforcement `"off"` until
      the maintainer provisions the key: five steps in `docs/tooling/update-signing.md`), then flip it to
      `"required"`.
- [x] **PAR-34. Mouse metrics, event families and app-category store on Linux and macOS.** [CODE] Done:
      Linux pointer counters and the window, session and system families (4947f7a445); one
      `{schema, version, apps}` category file shared by macOS and Linux through
      `_shared/lua/keystats/app_category_store.lua`, Linux importing its old SQLite rows once (94e7ed0b4a).

### C. UI-only gaps, reasons and docs

- [x] **PAR-37. Platform reasons for restrictions.** [CODE] Done: every restriction has a reason, the ratchet
      is frozen at 0; the drafted reason texts in 20 locales still want a native review.
- [x] **PAR-40. Unify user LLM profile storage.** [CODE] Done: one `llm.user_profiles` envelope on the three
      OS (a6f0fd8ad9, manifest rows d6146eb82b, 300aa8c4a6). An older macOS `[llm.profiles] user_profiles`
      array is imported on load and deleted by the next save (0146a938c5). Left: check on a real Mac that an
      old config keeps its profiles in the menu.
- [ ] **PAR-41. One shortcut data model.** [CODE] Design note written
      (`docs/design/one-shortcut-model.md`, 4ca41ed2e9): one action slot per chord with neutral role-based ids.
      Done on macOS and Linux (sixth integration batch): schema v15 `v14_to_v15` migration of the slots and
      Ctrl-letter switches, role table with per-driver families, manifest slots, both drivers adopt the role
      names, migrated-config binding proof, AHK fixtures pinned to v15, per-slot parameters carried by
      `rename_prefix`. Left: the Windows adoption, macOS `ctrl_g` to `open_url` later.
- [x] **PAR-43. Duplicated per-OS prompt strings.** [CODE] Done: `max_words`, `temperature` and the port
      dialogs (fb1aa4d934); one shared `menu.llm.server_port_label` row caption through `caption_getters`
      (`mlx_port_label` retired, `ollama_port_label` kept for AHK); `delay_prompt` and `debounce_prompt` stay two
      keys on purpose (different accepted input), reason documented (3f885f03d1).
- [x] **PAR-44. Reset error texts on macOS and Linux.** [CODE] Done: shared `config_reset_failure.lua`
      composes `dialog.reset_defaults.reason.*` for the macOS (`ui/menu/init.lua`) and Linux
      (`ui/menu/menu_builder.lua`) restore and clear rows; `reload_refused` has no entry there because they
      reload nothing.
- [ ] **PAR-45. Notifications: one behaviour for toggles and refusals.** [CODE] Done on macOS and Linux
      (shared `feature_notice.lua`, Linux quit refusal). Left: Windows `NotifyFeature(label, enabled)` around
      `NotifierSend` at the same call sites, and a Windows quit-refusal path firing `notify.quit_refused`.
- [x] **PAR-48. Review values equal to English in each locale.** [CODE] Done on `tmp/wip-todo-ag`: 95 keys
      translated in 19 locales, sticky and leftover labels, a shrink-only gate in
      `test-locale-catalogue-complete.cjs` with `tools/lint/locale-identical-to-english-allowlist.json` and
      `tools/locale/report-identical-to-english.cjs`. Left: a native review of the long `ui_typing.tooltip_*`
      texts; on the PC re-run the Windows menu caption tests (`menu.llm.backend_unknown` changed).
- [ ] **PAR-52. Release notes on macOS and Linux update windows.** [CODE] Done on macOS and Linux
      (80a5a650a6): shared `release_notes/pane.js` in the `update_check` page, repository-only links. Left:
      the Windows host (section "Windows side"), a visual check on a Mac and a Linux desktop.

### D. Instrumentation and diagnostics

- [ ] **PAR-53. Bring HotPath-style slow-segment logging to macOS and Linux.** [CODE] Done (shared
      `hotpath_segments.lua`, always-on Linux spans, one warning per segment per 10 s). Left: nesting
      attribution (Windows has it), the threshold question.
- [ ] **PAR-54. PhaseStats and child-process timing.** [CODE] Done on macOS and Linux (`process.<program>`,
      `toml.parse`, `menu.rebuild`, `boot.stage`, `boot.stage_cpu`). Windows: port `phase_stats_core.lua` with
      the same phases (`boot_profiler.ahk` already measures stages).
- [ ] **PAR-55. Crash reports: one content, one cap, one notice.** [CODE] Done on macOS and Linux (shared
      `crash_report.lua`, vectors `diagnostics/crash_report_vectors.json`, 20 newest kept). Left: Windows
      `crash_report_worker.ahk` adopting the same fields, names and cap.
- [ ] **PAR-56. Log-volume metrics on all three drivers.** [CODE] Done on macOS and Linux (per-level,
      dropped, suppressed and collapsed counts in the shared logger core, on the interval evidence record).
      Left: Windows `_LoggerEmit` counting the same seven figures in the same order.
- [ ] **PAR-57. Retention read from timings on Windows.** [CODE] `logger.ahk:112` is a literal 14. Read
      `Timings` and extend `test-logger-scalars-single-source.cjs`. Audit G5.

### E. Tests and corpora

- [ ] **PAR-58. Windows consumer for the shared Lua contracts.** [CODE] 105 contracts (about 940 cases)
      run on macOS and Linux, none on Windows. Convert the highest-value ones (`config_scope_*`,
      `toml_*`, `menu_*`) to JSON vectors and replay from one AHK consumer per family. Audit test
      item 11, section 14. Lua side done: 302 JSON vectors replayed by both drivers; the ledger
      (`tools/test/test-contract-vector-ledger.cjs`) classifies 288 Lua sites, 13 data-driven and 275 kept in
      Lua with a reason code. Left [PC]: the AHK consumers per family.
- [ ] **PAR-59. Corpus replay gaps.** [CODE] Done on macOS and Linux (file warnings, route plan, GET
      redirects, document lease; the download-document contract is Linux-only by design). Left: Windows
      consumers of `http/get_redirect_vectors.json`, `native_presentations/original_captions.json`,
      `route_plan_vectors.json`.
- [ ] **PAR-60. Hotstring `family_samples.json` plus chaining, synthetic-output and erase vectors.** [CODE]
      Done on macOS and Linux (`family_samples.json`, `sequence_vectors.json`, `cascade_vectors.json` in both
      E2E harnesses). Left: a Windows `family_samples` consumer.
- [ ] **PAR-61. Tap-versus-hold decision corpus.** [CODE] Done on macOS and Linux (`decision_vectors.json`,
      23 vectors, shared contract). Left: a Windows consumer through its tap-hold engine.
- [x] **PAR-62. Contract tests for shared modules no test requires by name.** [CODE] Done (ab086f5020):
      direct contracts for nine shared modules, each proved red by a mutation; personal_model's
      `unowned-personal-section` stays covered by the writer corpus only.
- [ ] **PAR-63. Remaining 2026-10-18 test items.** [CODE] Done on Linux and macOS (personal-info editor,
      field masking, native-only number row; model records, downloads, keystats corpus and the toggle gaps
      were already covered). Left: Windows dynamic hotstrings, Windows root runners and the
      `test-driver-tree-parity.cjs:19` exclusion.
- [ ] **PAR-64. Installed-record and layout corpora on Windows.** [CODE] Windows replays 1 of 4 files.
      Replay extensions, preservation and updates. Audit L6.

### F. Centralisation and hexagonal architecture (value order)

- [ ] **PAR-65. Extract the LLM request plan to `_shared/lua/llm/request_plan`.** [CODE] Phase 1 done on macOS
      and Linux: `debounce.lua` and `batching.lua` with request-transcript vectors (`_shared/tests/corpus/llm/`)
      replayed by both drivers (48be669def, 7442ab5edd, d18f573791; the decisions of October 26 are on
      `work/todo-af`). Left: the Windows twin replaying the vectors, then the HttpClient, TimerScheduler and
      TooltipRenderer ports, the live prompt, the token budget, the info-bar text and the agent flows. Audit R1.
- [x] **PAR-66. Move the menu frame builders to `_shared/lua/menu/frames`.** [CODE] Done on macOS and Linux:
      `magic_frame`, `parent_source` (Debug, Configuration, Metrics, About) and `personal_info_source`, with
      contracts replayed by both drivers; the source-pin gates own the shared text and pin only the driver
      ports (`tools/lib/menu-parent-source-gate.cjs`). Windows has its own AHK reader.
- [ ] **PAR-67. Shared keystats query catalogue and walker.** [CODE] Reader catalogue, shared walker and
      aggregation vectors done; `meta.rev` shared and a gate refuses SQL spelled by hand in both Lua drivers.
      In progress: write-statement catalogue with typed slots (agent). Windows: adopt it later.
- [ ] **PAR-68. Hotstring override parser into `_shared` on `toml_codec`.** [CODE] Done on macOS and Linux
      (shared `hotstrings/overrides.lua`, `override_parse_vectors.json`). macOS now reads a duplicate key or
      header as invalid TOML (was last-wins). Left: Windows `_ParseOverrides` replaying the vectors.
- [x] **PAR-69. Shared ownership protocols.** [CODE] Done: `scope_owner.lua`, `storage_owned.lua`,
      `error_dialog/core.lua`, `owned_timer_slots.lua`, each with a contract (4947f7a445).
- [x] **PAR-70. Factory per macOS/Linux infra shim.** [CODE] Done on macOS and Linux: `timings`,
      `manifest_reader`, `text_cipher`, `text_migration`, `config_backup`, `user_code` share their policy in
      `_shared/lua` with contracts replayed by both drivers. Windows keeps its own AHK implementations.
- [ ] **PAR-71. Finish the route-plan rollout and make `proxy_policy.json` the codegen source.** [CODE] Done on
      macOS and Linux (generated shell and Lua precedence, Linux lookup limits from the policy, drift guard).
      Left, Windows: generated or read AHK copy in `http_client.ahk` (reseal), the route-plan consumer
      replaying `route_plan_vectors.json`, the native lookup limits from the policy.
- [ ] **PAR-72. Shared registries and catalogues.** [CODE] Done: layout registry store, shortcuts
      catalogue, healthcheck report runner, agent learning store (daee88e48d..e105336d39); gesture
      direction and temperature were already shared with vectors. Left: the registry install/select flows and
      the healthcheck bridge stay per driver (different converters and bridges).
- [ ] **PAR-73. Collapse generated per-driver artifacts and tap-hold timeout duplicates.** [CODE] Done:
      `[hs_timeouts]`, `action_catalogue.lua`, and `features_manifest.lua` (one shared
      `_shared/lua/features/manifest_data.lua`, eae6f45708). Left: `config_template.toml` (decision pending).
- [ ] **PAR-74. Config-key and command-id constants by codegen.** [CODE] Generate constants from
      `config.schema.json` and `menu_manifest.json` for AHK, Lua and JS; lint raw literals such as
      `private_filter_enabled`. Audit R10. Lua and shared Lua done (567 sites to 0); JS and Node tools done
      (83 sites to 0, the ratchet now scans `tools/`, CommonJS `tools/lib/_generated/config_keys.cjs`). Left
      [PC]: 1243 AHK literals in the shrink-only `config-key-literal-baseline.json` (read
      `windows/_generated/config_keys.ahk`).
- [x] **PAR-75. Shared Lua helper modules and a redefinition lint.** [CODE] Done: every inline site burned
      down (baseline `{}`), basename detector added; the allowed exceptions are listed in the gate's `ALLOWED`
      list (two URL segments, the Linux worker `arg[0]` check, boot-time dirname splits).
- [ ] **PAR-76. Long refactors, plan before starting.** [CODE] Generate the AHK config-migration op table
      from `migrations.toml` (R17); extract menu row-ordering rules to data (R18); pure hotstring
      injection plan (R26); FileSystem port spec for lease/atomic write (R33); canonical `.keylayout`
      parser (R23); Windows updater `check_session`/`rate_limit` vectors (R25). Done on macOS and Linux: R18
      (`_shared/modules/menu/row_order.json`, generated `row_order_data.lua`, single-source gate), R33
      (`_shared/lua/file_system/ports.lua`, both owners checked at load), R23 (`layouts/keylayout.lua` the
      only reader, gate), R26 (`hotstring_engine/injection_plan.lua`, both engines, 18 vectors, no driver
      divergence). Left [PC]: R17, R25, and the AHK readers of R18, R23, R26 and R33.
- [x] **PAR-77. Remove platform branches from shared UI JS.** [CODE] Done: hosts pass capability flags
      and `executableSyntax`; `test-shared-ui-no-platform-branches.cjs` guards it.

### G. Constants, delays, colours, labels (value order)

- [x] **PAR-78. Timing registry liveness and duplicate-name gate.** [CODE] Done:
      `test-timings-registry-liveness.cjs`, the duplicate ratchet `test-duplicate-constant-names.cjs`, and source
      pins for copies that cannot read the registry (ed257e285a).
- [ ] **PAR-79. Replace repeated timer literals with registry keys.** [CODE] Done on Lua and JS
      (ed257e285a): registry keys for the repeated delays, the literal gate in `test-fast-timer-inventory.cjs`
      with a shrink-only `timer-literal-baseline.json`. Left: 139 AHK sites (`STALE_TEMP_MS` x5, gesture poll
      `-100` x6, safety flush `-2000` x3...), ~25 Swift `usleep`, 40 baselined Lua/JS sites.
- [ ] **PAR-80. `[limits]` section for byte caps.** [CODE] Done (7376321788): `[limits]` with the process
      output, declaration file and changelog caps, a retyping gate with a shrink-only baseline. Left: the AHK
      caps, `MAX_TEXT_BYTES` and `MAX_BODY_BYTES` (public module fields).
- [ ] **PAR-81. Theme tokens and palette codegen.** [CODE] Done: `_shared/ui/theme.css` linked by the
      shared pages; `_shared/data/native_theme.toml` generating `_shared/lua/native_theme_data.lua` for the macOS
      and Linux palettes; the dead macOS download-window page removed; hex lint with a shrink-only baseline
      (`tools/lint/hex-literal-baseline.json`, 53 files). Left: an AHK emitter replacing the typed palette in
      `hcw_helpers.ahk` (then retire `test-color-presets-parity.cjs`), and moving the baselined literals onto
      tokens with per-page pixel diffs.
- [ ] **PAR-82. Hard-coded UI string gate.** [CODE] New `tools/test/test-no-hardcoded-ui-strings.cjs`
      (TrayTip, MsgBox, alert, title literals fail unless allowlisted; reuse
      `tools/lint/audit-gui-titles.cjs`), including the Linux `install.sh` echo table. Audit K6, I9.
- [ ] **PAR-83. Identifiers and hosts in one file.** [CODE] Done for Lua (948ebef074, bb1899206e):
      `_shared/data/identifiers.json` generating `_shared/lua/identifiers.lua`, typed copies held to a
      shrink-only baseline. Left: an AHK emitter and the AHK, Swift, shell, Python and JS-page copies.
- [x] **PAR-84. Closed enums for reasons, phases and log tags.** [CODE] Done: `vocabulary.json`, the scan,
      the census and the gate in `test-logger-scalars-single-source.cjs` with a shrink-only free-form baseline.
- [x] **PAR-85. Tooltip dequeue and ring constants.** [CODE] Done: dequeue timings single-sourced in
      `tooltip/constants.toml [timing]` (`test-tooltip-timing-single-source.cjs`); the 64/32 rings are
      unrelated (keystroke ring, phase attribution ring).

## Backlog (one line each)

Added October 22 (from the agents' reports; details in their commits):

- [ ] **macOS swallowed-keys check on v1.0.6.** [PHYS-M] The fixes (03a2c2fa4b, d026f3e024,
      a414e83fb7, 19fa9fa872, 89cbcae90b, 9b500a9e8c, c21e920d7e, bb6fcc2cc2) shipped in v1.0.6;
      they need a Mac day of typing with the `key_event_health` counters; handoff in
      [issue99-karabiner-input.md](todo-agents/issue99-karabiner-input.md).
- [ ] **Keystats rename leftovers.** [CODE] The rename is done (180a53e4de, 1 283 files, 579 paths). Left:
      the comment in `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` (a compiled
      script: recompile on a Mac); declare each persisted name once and make tests read it instead
      of pinning spellings, so the next rename is cheap.
- [ ] **Issue #101: Mac follow-ups.** [PHYS-M] Fixed, to confirm on the Mac with the next release:
      ATS key so the URLSession can fetch an `http://` company PAC (c0c29cd8ab); direct route when the
      PAC lookup names no route (719c7fcd76); no retry of a refused route (ace928dc1c); the lookup now
      names its failing step (363a63f79d: `native_proxy_budget`, `native_pac_download`, ...); lease
      line cap judged per line (5deb892d58); Ollama 412 upgrade request shown (08aaeaf3c2);
      diagnostics PAC probe on the three OS (f798aae1f9); one-click Debug checks (lease, owned
      runtime, network, 30 s key accounting). Left: (1) read the Mac's next log lines `Slow ingest
tick`, `Slow preferences save` and `Field check result:` to name the dominant main-thread
      phase before slicing it; (2) an explicit proxy override field; (3) local server probes (oMLX,
      Jan) all answer "Network request failed"; (4) `keymap/utils.lua` ignored-window TTL probe
      (1 s): bound it only after measuring the AX call time (secure-field cache); (5) rebuild the
      inverse oracle of `macos_native_http_receiving_facts_test` (red since 719c7fcd76), compile the
      Swift on macOS CI, add Go table cases for the new stages; (6) the network check's digest step
      is skipped (HEAD only); (7) PAC fetch/evaluation failures now fall back to a direct connection on
      macOS (item "PAC unusable: direct fallback"): confirm on the Mac.
- [ ] **macOS input follow-ups (swallowed keys).** [CODE] Done: late keys pass through (ed2d9fe65c),
      AXValue read once per burst (34765cde7c), no error window for a lease failure that recovered
      within 60 s (fcf4af85dc), `key_*` counters in the diagnostics (6f2daed2e5). Lease token reuse
      was analysed and refused (ADR 012): a reused token could never reach READY because the
      revocation tombstone is monotone; reuse needs a native acknowledged rearm, decided NOT to
      build for now. The next Mac log carries `Lease token decision=` and `written in N ms`: if the
      write is short, keep it; if long, shrink the 743 KB file instead.
- [ ] **Linux correction parity remainders.** [CODE] Done (06bbbe5985): Backspace pops the word, erased
      n-grams get `e`, synthetic output chains. Erased and synthetic vectors in the shared corpus, replayed on
      macOS and Linux (ee2eab6b1e, `keystats/correction_erased_vectors.json`). Left [PC]: the AHK replayer
      (`KLW_WalkTypingEntry`); Windows word separators are wider than Linux's three.
- [ ] **Developer mode on the three OS (maintainer decision, 27 October).** [CODE] [PHYS-M] [PHYS-W] Each app
      runs the clone with the built app's helpers, config and AI runtimes, reloads a saved source file, and
      starts with one command; the updater, uninstall and remote layout catalogue stay off in a source run.
      Inventory per feature: `docs/design/developer-mode.md`. Commands: macOS `bash tools/dev/run-macos-dev-app.sh`
      (done: guardian 6f667b3380, network receiver c0e3359a19); Linux `bash tools/dev/run-linux-dev.sh` (done in
      branch `tmp/wip-devmode3`: Reload relays the runner, a saved driver or `_shared/lua` `.lua` restarts the
      daemon, the native archive backend is built into the clone); Windows `tools\dev\run-windows-dev.ps1`,
      run with `powershell -ExecutionPolicy Bypass -File` (same branch: `infra/dev_source.ahk` reloads on a saved
      `.ahk`, the run reads `%APPDATA%\Ergopti\paths.toml` like the exe). Left: (1) [PHYS-W] on the PC with the exe installed and
      running, run the command from a PowerShell in the clone: the exe closes by itself (taskkill without /F; if it
      stays, the script names it and stops), the tray icon appears, Debug logs say "Developer source mode; the driver
      runs from <clone>\static\ergopti_plus\windows (clone root from the developer variable)" and "Developer source
      watcher started"; the config is the
      exe's (same hotstrings, same `paths.toml` choice, no onboarding); save any driver `.ahk` with a harmless
      comment change: within about 2 s the driver reloads once and keeps a Pause; the tray's Reload still works;
      AI menus (Ollama), the metrics window (WebView2, sqlite3.dll) and Alt+Tab navigation (ergopti_nav_owner.dll)
      work; Start at login in this mode registers the interpreter and the clone's script, and that login start
      derives the root, so it is a developer run too (wanted, maintainer decision of 27 October): confirm it. (2) [PHYS-W] check that
      `npm run dev:windows` works from Git Bash and from cmd (it calls Windows PowerShell 5.1). (2b) [PHYS-W]
      double-click works: quit the exe from its tray, double-click `static\ergopti_plus\windows\ErgoptiPlus.ahk`
      in Explorer: the same Debug lines appear, the "Developer source mode" one ending "(clone root from the
      script location)",
      a saved `.ahk` reloads, About shows the updater off and Uninstall greyed; then start the exe and
      double-click again while it runs: the source run yields after about 3 s (no second tray icon, a
      "Another instance owns the single-owner mutex" WARNING in `bootstrap.log`) and the exe keeps running. (3) [PHYS-M] the Mac lines of the hardware session cover the macOS
      mode. (4) Linux, on a real desktop with the package installed: the unit is stopped, the tray appears, a
      saved `.lua` restarts the daemon (`Debounced source reload firing` then a new boot), the tray's Reload
      restarts it, and a second `run-linux-dev.sh` while one runs reports "already running". (5) [CODE] decide
      whether the layout catalogue should fetch the remote registry in a developer run (today all three read the
      clone's registry, by design of `local_source`). (6) [CODE] `bin/ergopti-hotstrings` run from a clone still
      prefers `/usr/lib/ergopti` when a package is installed; fix or retire that branch.
- [ ] **Owned, pinned third-party runtimes on the three OS (maintainer decision, 27 October).** [CODE] Ergopti
      installs and runs its own pinned Ollama, MLX environment, Karabiner runtime and any other third-party
      runtime, whether or not the user has one, and never uses, stops or modifies the user's copy. Ollama:
      always the managed daemon on its own port and models directory (agent AK, macOS first, then Linux and
      Windows). MLX: already Ergopti's own environment; keep it so. Karabiner on macOS: this activates item 31
      (owned Karabiner runtime, ADR 011, dormant today behind `[karabiner] runtime = "owned"`); plan it as the
      default. Rule from the maintainer: with tap-hold on, quit the user's Karabiner and run ours; with
      tap-hold off and theirs present, never activate ours (this rewords ADR 011 decision 3). WebView2 stays
      the system copy, with a version check and a clear refusal. Linux and Windows: inventory every external tool the drivers call (ydotool, xdotool, wmctrl,
      curl, Python, PowerShell modules, WebView2) and decide per tool whether Ergopti ships its own.
- [ ] **Ergopti's own Ollama on Windows and Linux too (maintainer requirement, 27 October).** [CODE] Same rule
      as macOS on every OS: Ergopti always installs and runs its own pinned Ollama, whether or not the system
      has one, and never selects, reuses, stops or modifies the user's Ollama. macOS is done (bc09e4584c:
      `ollama_binary.resolve()` returns only the owned runtime, pinned 0.40.4 from `managed_ollama_runtime.json`;
      the shared key `llm_ollama_owned_port` = 11435 in `defaults.json`, read through `ollama_endpoint`; a saved
      11434 override is refused and the old `llm.ollama_port` is migrated once and logged). Left: Linux
      (`managed_ollama_proxy.lua`, the Ollama resolver and the endpoint still on `llm_ollama_port` 11434) and
      Windows (it already has an owner for its own Ollama taking a models directory and port; check its
      installer and every caller against the rule), both moved to `llm_ollama_owned_port`, the user's daemon
      on 11434 left untouched, with regression tests that an installed system Ollama is never resolved or
      started. [PHYS-W] [PHYS-L] confirm with a system Ollama running on 11434: Ergopti's listens on 11435.
- [ ] **Ctrl+Caps Lock slot on macOS.** [PHYS-M] The `secondary_capslock` slot binds through its own native
      entry again (ea02cf7000: the generic registrar refuses Caps Lock and the whole shortcut start rolled
      back). The registrar tests say macOS never fires a Caps Lock hotkey: check on a real Mac that Ctrl+Caps
      Lock toggles Caps Lock; if not, report it and drop the slot's recommendation on macOS with a reason.
- [ ] **Layout emulation on macOS and Linux through one generated `.keylayout`, live (maintainer request, 27
      October).** [CODE] Decided by the maintainer: no pre-generated variants. The user picks a layout
      (Ergopti, Bépo, ...), the menu options (number row in direct access or symbols, row switches) and later
      per-key edits in a page; that produces one custom `.keylayout`, the single source the three OS already
      share: Windows emulates it (AHK reads a `.keylayout`), macOS installs it as the input source, Linux
      converts it to XKB (`_shared/lua/layouts/xkb_converter.lua`). The per-layer layout composer
      (docs/layout-composer.md) already compiles a composition into `composed.keylayout` and installs it on
      the three OS; build on it, do not add a second format. Left: (1) the menu options (Ergopti or Bépo base,
      `layout.direct_access_digits`, `layout.number_row_reorder_edges`, the row switches) feed the compiled
      `.keylayout` on macOS and Linux instead of narrowing a Windows-only emulation, with Ctrl/Cmd maps, dead
      keys and symbols from the layout; (2) a live replace with no logout: macOS caches a rewritten
      `.keylayout` until the input source is toggled or the user logs in, so write each build under a new
      versioned id, register it (`TISRegisterInputSource`), select it, then disable and remove the previous one
      (verify on the maintainer's Mac); Linux replaces the XKB files and reloads with `setxkbmap` on X11 and the
      desktop input-source setting on GNOME and KDE Wayland, with an honest reason where a compositor cannot;
      (3) the scope participant acknowledges only after the new layout is selected. Design note
      `docs/design/layout-option-emulation.md` first (agent AF), then slices.
- [ ] **Windows updater -File workers: real update check.** [PHYS] Install a build with 5d6beccf83
      by hand, then update from it to the next release: the exe is replaced and restarts, the
      three scripts are in `%LOCALAPPDATA%\Ergopti\vendor\`, the PowerShell command line shows
      `-File ...ergopti_updater_staging.ps1` and no `-EncodedCommand`.
- [ ] **Config policy remainders (33, 42).** [CODE] Done: macOS category authority (80c18d9cc2),
      explicit `--config` watcher topology (3dd420292d), `api_entries` retired rows (c03762d27b),
      parse cost (e525cd6615). Left: the physical keyboard slot parameters
      (`keyboard__win_SC03A__x`), the Windows `api_entries.json` per-row warning, the bare-root and
      unknown-`[[x]]` cleanup offers, a reseal of the updater original source after e525cd6615
      once `run_all.ahk` is clean, and the Linux reload as a daemon restart (the control protocol
      needs a pending record that can name an unknowable successor pid; recommended: a TTL-bound
      pending record completed by the successor).
- [ ] **Linux CI installs packages inside short test steps.** [CI] 18 steps moved and skipped when the
      suite is deferred (c52cb916a7, 285d3363a1). Left: `Qualify three actual XI2 property cookies`
      and `The whole daemon, live` (their text is pinned), the 35-minute and 18-minute steps, the
      other jobs, and hosted validation.
- [ ] **macOS "Quit did not end both processes within 10 s".** [CI] Cause found: the Quit AppleEvent
      timed out while the launcher log had been silent since startup (run 39850037912); the gate now
      names the surviving process and keeps the failing attempt's evidence for 7 days
      (b2b5bb149b, bf05488dfb). Read `launch-gate-failed-*` if it recurs.
- [ ] **History hygiene of October 22.** Commits with another agent's message, already on dev:
      c6db589c76 (macOS cipher argv fix under a README subject), 90da28c725 (config snapshot test
      under a CI subject), 18ca214ead (also deletes ten handoff files), 6d9c659 ("applied for now"
      instead of "apply now"). Keep, or rewrite dev once with a lease: maintainer's call.
- [ ] **Signing and antivirus: maintainer actions.** Apply to SignPath at signpath.org/apply (the
      HubSpot form does not load in an automated browser; answers in
      [signpath-foundation-application.md](todo-agents/signpath-foundation-application.md)), submit
      the Defender false positive, and ask the tester for the exact block page.

- [ ] **36. Windows updater production coupling.** [CODE] The "original23" collector stays inactive
      (`docs/handovers/2026-10-12-group6-ci/INACTIVE-ORIGINAL23-SOURCE.md`) until enrolled.
- [ ] **62 (macOS and Linux).** [CODE] Packaged paths resolve every request and redirect natively;
      the environment fallback now resolves each origin of the client inventory and refuses two
      different relays (1fd254d92e, 749e00c4c8). Left: confirm the Ollama blob host on the Mac,
      the Go twin `_shared/go/route_plan` in a CI cell, a Linux wrapper test.
- [ ] **CI duration** ([target](memory/workflow-and-verification.md)). Flatpak runtime cache and a
      bounded retry are in (07a601c97e plus the retry commit); confirm on a hosted run (target under
      5 min). Windows Integration still adds 4-5 min on the critical path; the macOS lane (about 58
      min) must stay within the five-runner budget.
- [ ] **CI structure.** [CODE] Slowest-test summary and `tools/ci/run-timing.cjs` shipped
      (e1aa4a5f48, cab1170446). Left: a per-step elapsed summary inside the CI run itself.
- [ ] **Test parity across the drivers.** [CODE] Done: Windows CapsWord behaviour tests, dynamic
      hotstrings, macOS audit-named tests renamed, neutral-installation gate. Left: Windows replay of
      the shared HTTP-redirect, timer-ceiling and key-chord corpora (needs a decision to build those
      policies on Windows), conversion of Windows source assertions to behaviour (audit item 14).
- [ ] **5.** [CODE] Linux layout and number-row scope participants composed with the real runtime
      producers; Linux/macOS numeric-owned Script aliases need an explicit snapshot contract.
- [ ] **116. Guided third-party validation report.** [PHYS-M] macOS `field_check_toolchain` landed
      (timer, Shortcuts, Homebrew, Karabiner signature); needs a run on a real Mac. Package
      provenance beyond the signature check is open.
- [ ] **139. Personal identities in logs.** [CODE] Done: email, URL-credential, foreign-profile
      rules (5ef12e8a2a) and config-directory name masking (20e845692b); opt-in redacted day log
      attachment (1c6f891ed3, item 138). Left: emitter-side pack labels (the TomlLoader SUCCESS line
      prints the pack label; check the macOS and Linux loaders), write-time masking in the three
      loggers, historical logs on disk stay unmasked (the collector masks at export), GitHub field
      editability after a form reload needs a real draft.
- [ ] **142 gaps.** [CODE] Windows: a Reload click during a pending reload now follows the join rule
      (standing-checks agent); no hash-check requirement identified for the Windows client. Linux:
      the reload is in process; see "Config policy remainders" for the protocol decision.
- [ ] **13/35.** [CODE] Enrol the complete guardian acceptance collector in main CI.
- [ ] **93. Linux ordered pairs.** [CODE] XI2 property cookies proven on Xvfb in WSL; the saved Xi
      packet is retired (libXi as a package dependency declined by the maintainer). Physical input
      and the XKB/XI2 server-state join need a real kernel and desktop.
- [ ] **97/98.** [CODE] Native physical-position capture and all-owner collision admission; Linux
      identity needs the MediaStore device contract. The star setting migration is dropped (no
      users, no legacy migration).
- [ ] **106.** [PHYS-M] Genuine Apple Shortcuts invocation with bounded cancellation; only the
      refusal-in-time probe exists (in 116).
- [ ] **107.** [CODE] macOS forced output, Linux input+XI2+writer join.
- [ ] **108.** [CODE] Item 97's collision/source/modifier/output joins.
- [ ] **109. Branded debug GUI.** Blocked: AHK 2.0.26 has no supported invisible
      Variables/KeyHistory snapshot.
- [ ] **120 (formerly 46/47/48).** [CODE] Broad Ollama process termination on macOS stays debt (the
      other clauses of 46/47/48 were stale or by design; their context was lost and the maintainer
      retired them).
- [ ] **L115.** [CODE] Provider error envelope guard: not reproducible under WSL LuaJIT (6 of 6
      runs pass); leave it or close it.
- Optional, not planned: XKB angle-name gaps and raw-input grammar (L118-L120); concurrent JSON
  backup replacement (L52, L60); ALSA fallback (L63); multi-group XKB recovery (L100); a real
  `Comments` exe field through a version `.res` resource.

## Maintainer checks

Record the commit, OS build, scale, layout and emulation state; report pass, fail or not executed
per line. Use a disposable profile (`paths.toml` pointing at a scratch folder) for anything that
writes configuration. Reload the driver from the working tree for dev-only fixes.

### Mac hardware session (prepared 27 October, run from a branch of dev)

Clone only the current dev state and branch from it:
`git clone --depth 1 --branch dev --single-branch --filter=blob:none https://github.com/adrienm7/ergopti.git`,
then `git switch -c field/mac-2026-10-27` (if the clone is cut off: `git config --global http.version HTTP/1.1`).
Run the developer app: quit the installed ErgoptiPlus, back up `~/.config/hammerspoon` (the v15 migration
rewrites `config.toml`; keep a copy of the old one for section 3), remove an old `~/.hammerspoon/init.lua`
bootstrap if one exists, then `bash tools/dev/run-macos-dev-app.sh` (Command Line Tools are enough: it builds a
native single-architecture app whose Lua runs from the clone, then opens it; `--open-only` reopens without a
rebuild). Saving a `.lua` file reloads the driver; the menu Reload row reloads on demand. Rebuild only after a
Swift, native helper or LuaSocket change; each ad hoc rebuild asks again for Accessibility and Input
Monitoring. `~/Library/Logs/ergopti_plus/launcher.log` must say "developer source mode". Sparkle is off in
this mode, so the update lines of section 5 need a release build. Before starting, write down the commit (`git rev-parse
--short HEAD`), macOS version and build, chip (Apple silicon or Intel), keyboard (ISO or ANSI, built-in or
external), input source, Karabiner version and whether Ollama.app or oMLX is installed. Report each line as
pass, fail or not run.

**Give me the logs.** At the end of the session (and right after any failure) use Debug > Report a bug, or copy
`~/Library/Logs/ergopti_plus/ErgoptiPlus_<date>.log`, `ErgoptiPlus_errors_<date>.log` and
`ErgoptiPlus_llm.log` into `docs/field-reports/mac-2026-10-27/` on your branch and push it (the logger already
masks secrets, the home folder, e-mails and personal names; check nothing private is left). Set Debug > Log
level > DEBUG first for the whole session. I read: `Boot complete in`, `Boot CPU`, `Boot stage`, `Slow <segment>:
X ms own, Y ms total, parent ...` (HotPath, PAR-53), the periodic PhaseStats and log-volume summaries
(PAR-54, PAR-56), `Field check result:`, `typed key(s) swallowed`, `key_event_health`, lease lines (`exit 73`,
PONG/READY), `Lease-bound input startup failed`, `Layout poll detected change`, every ERROR and WARN.

#### 1. Start-up time and idle cost

- [ ] Cold start: quit Ergopti, wait 10 s, start it; note the `Boot complete in … ms` and `Boot CPU` lines.
      Repeat three times, then once right after a macOS login. Report the three numbers and the slowest
      `Boot stage` lines.
- [ ] Reload: Hammerspoon > Reload config three times; same lines. A menu click during the reload is held
      and replayed; a second Reload click joins the first one (no double reload).
- [ ] Idle: 10 minutes without typing, then Activity Monitor CPU and memory of Hammerspoon; the PhaseStats
      summary in the log should show no recurring work above a few ms per minute.
- [ ] Quit during a busy moment (typing, then Quit within a second): the app ends both processes within
      10 s (CI item "Quit did not end both processes within 10 s"); Quit wins over a reload in progress.

#### 2. Typing in real conditions (one working day if possible)

- [ ] Type normally for at least an hour in Safari, TextEdit, Terminal, VS Code and one Electron app (Slack
      or Discord). Note any dropped, doubled or reordered letter with the time; right after one, use Debug >
      Report a bug. I compare with `typed key(s) swallowed`, `key_event_health` and the lease lines
      (items "Dropped letters on macOS", "macOS swallowed-keys check on v1.0.6", 117/140).
- [ ] Hot path: after that hour, the HotPath lines name each slow segment with its own time and its parent;
      send them, they decide what to optimise next (Issue #101 point 1: `Slow ingest tick`,
      `Slow preferences save`).
- [ ] Hotstrings: expansions, chained expansions, the magic key on ISO and ANSI, Backspace right after an
      expansion (undo), hotstrings in a password field (none must fire, private text never logged), an
      ignored app. The injection order is new code (PAR-76 R26): any wrong erase count or replayed
      terminator (Return, Tab, a letter) is a fail.
- [ ] Tap-hold: each tap-hold key alone, fast rolls (`one-shot`), holding with another key; the Karabiner JSON
      thresholds equal the shared per-key thresholds (PAR-15: compare `~/.config/karabiner/karabiner.json`
      with the menu values).
- [ ] Ctrl+Caps Lock toggles Caps Lock (new `secondary_capslock` slot binding, ea02cf7000; the tests say
      macOS may never fire a Caps Lock hotkey: report exactly what happens).
- [ ] Right Option + Return, Delete, Backspace and Escape run their script actions; Backspace word start in
      Terminal (`ab`, three Backspaces), TextEdit Option+Backspace and Safari Cmd+L.
- [ ] CapsWord: the pointer cancels it (item 44).

#### 3. Configuration migration and menus

- [ ] Schema v15 (PAR-41): with a copy of an old `config.toml` that has keyboard shortcut slots with
      parameters (for example a shortcut that opens a URL or types text), start the new build: every slot
      keeps its action and its parameter under its role-named id.
- [ ] Old `[llm.profiles] user_profiles`: a config that has them still shows the profiles in the AI menu
      (PAR-40), and the next save writes the new `llm.user_profiles` only.
- [ ] Clear and Restore per category and global, then restart: unknown keys kept, personal hotstrings kept
      by Restore, exact backups; recommended-settings restore asks no confirmation where it should not.
- [ ] Shortcuts group restore and clear; tap delay row opens the dialog and « Use global delay (…) » is
      right below it; tap and hold pickers (steps in
      [macos-tap-hold-action-picker.md](todo-agents/macos-tap-hold-action-picker.md)).
- [ ] Menu row order looks as before in every submenu (orders now come from one data file, PAR-76 R18).
- [ ] « Retirer les anciennes règles » on an upgrade (item 43); Login Items show one Ergopti (item 24,
      Debug > Show what starts Ergopti at login).

#### 4. AI predictions

- [ ] With a real local model (Ollama.app, then oMLX if installed): predictions appear; the request floor
      (default 300 ms, settable in the AI menu, 0 accepted) spaces automatic requests; an explicit
      shortcut is never held; asking for several variants sends them without delay; mashing the shortcut
      replaces the request in flight; the debounce "never" setting works; live mode answers at once at a
      word end.
- [ ] AI off disarms the AI keys, the agent's manual actions and the automatic mode; greyed actions show
      the dedicated "requires AI" hint.
- [ ] Agent: manual action refused with the right notice when paused, AI off or agent mode off; automatic
      triage skipped while typing a hotstring preview (new shared decisions, PAR-65).
- [ ] Tooltip typography and placement near screen edges, on two displays (item 111).
- [ ] Issue #100: with Ollama.app and a PAC proxy, enabling the AI downloads the model; with the Ergopti
      menu held open, no lease timeout.
- [ ] Issue #99: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG line `Local server 'omlx'
probe answered ...`, else `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models`);
      `Ollama bootstrap failed (exit=137)` with an external Ollama; declining the download opens no error
      window ([issue99-ai-startup-updater.md](todo-agents/issue99-ai-startup-updater.md)).

#### 5. Network, updates and field checks

- [ ] Debug > Test network (PAC, proxy, download), on the office network if possible and at home: send the
      `Field check result:` lines; the new route-plan step shows which route each Ollama origin takes; an
      `http://` company PAC is fetched (Issue #101).
- [ ] Debug > Test Karabiner lease, Test key accounting (30 s, type during it), Test third-party tools
      (Shortcuts, Homebrew, timer; item 116), Test owned Karabiner runtime (must stay dormant).
- [ ] Update check window: release notes pane readable in light and dark, links open the repository
      (PAR-52); a Sparkle update from the previous release installs and relaunches; Homebrew live upgrade.
- [ ] MLX download behind a proxy (119/130/136); code 74.

#### 6. Windows and pages (visual)

- [ ] Open every page once in light and dark mode: metrics (apps and typing), changelog, release notes,
      model browser, hotstring editor, layout manager, onboarding wizard, download window. Colours now
      come from the theme (PAR-81, proven identical in Chromium): report anything that looks different in
      the real WebView.
- [ ] Onboarding wizard (item 7): fresh folder, existing folder, moved folder, Cancel, Finish then
      restart.
- [ ] App Cloner: clone an app, cancel the folder picker (system « Annuler » label is expected now), and
      clone into a full or read-only folder: an error dialog must appear, never an endless progress bar
      (4550befb08).
- [ ] Trackpad gestures (item 126); Diagnostics window focus (item 122); shared export (item 123).

#### 7. Edge cases

- [ ] `pipefail` and `printf %b` under the system bash 3.2 (automated: collector step `system_bash`), the native HTTPS downgrade refusal,
      `hs.fs.attributes` on a FIFO, the read-only dashboard with a hot journal.
- [ ] Recompile `macos/apps/Encryptor.app/Contents/Resources/Scripts/main.scpt` from its source in Script
      Editor so its comment follows the keystats rename, and commit it.

### After v1.0.5 (actions)

- [ ] Post `/retest` on AppImage/appimage.github.io#10422 from **PowerShell** (Git Bash rewrites
      it): `gh pr comment 10422 -R AppImage/appimage.github.io --body '/retest'`; read the bot's
      screenshot (status window and tray menu, 98d41e630b) and warnings.
- [ ] Airbus tester (Netskope): retry the `ErgoptiPlus.exe` download and report T1-T4
      ([matrix](todo-agents/windows-exe-flagged-by-proxy.md)).
- [ ] Give the v1.0.5 SHA-256 to VirusTotal; submit it to Microsoft Defender as a false positive if
      flagged.
- [ ] Number-row testers (October 13 and Discord): retest with their exact setup (native layout,
      emulation and row switches, CapsLock, outputs in the three modes); fix only a confirmed
      discrepancy. Key-combination testers (October 15): confirm c89d74eb, else ask for
      `[KeyCombinations] Pair`, `AHK drop detected` and `Menu command refused` lines.
      Priority-100 tester: confirm uppercase output (cf29c35e5f).

### Windows PC

Fixes of October 22 (dev, after v1.0.5):

- [ ] **Win+S open target** (ec1c4105d9): automated checks cover the target resolution; by hand only
      what leaves the driver: a browser, the mail client, Regedit with its prompt, Settings, a web
      search (steps in [windows-maintainer-checks.md](tooling/windows-maintainer-checks.md)).
- [ ] **Backspace word start**: the engine-buffer cases are automated; by hand only Windows Terminal
      with Claude Code, Notepad Ctrl+Backspace, the browser Ctrl+L, and AltGr+Backspace on an
      AZERTY-style AltGr and a Kana layout.
- [ ] **Tap-hold and key-combination pickers**: automated except the native pair popup itself.
- [ ] **Versions tabs**: automated except the Retry button.

Standing checks:

1. **Seven-page wizard** (item 7): fresh, existing and moved folder; every page, Cancel, Finish then
   restart, rerun; No against recommended choices; WebView rendering and persistence; the layout
   step's controls never reload the UI.
2. **Clear and Restore** (item 5): per category and global, then restart; unknown and outdated keys
   preserved; personal hotstrings unchanged by Restore; exact backups; an external write refused.
3. **Number row and key combinations**: on AZERTY, US QWERTY and Ergopti, each ordering and
   edge-key choice, each row emulation switch, an inert choice ticked, greyed and suffixed « — non
   appliqué », the ² key; a pair assignment saved and reloaded.
4. **Installed build**: install, start, Diagnostics cold and reopened (UIA/render probes, cold
   WebView), Quit during a keystats flush, File/Exit and Windows shutdown with exit code 0;
   uninstall greyed on a source run. Item 101: capture the watcher/debt state if `watchers=0`
   recurs.
5. **Item 51 matrix**: arrows and both Shift+Tab over a multi-slot prediction move the marker once
   and wrap (also after reload, with `nav_modifiers = ctrl`, with a tap-hold Tab); footer "⇧G + Tab
   ou ↑/←"; bubbles and delayed expansions with emulation off and on; no "eeee"; one clipboard-log
   row per Ctrl+V; AltGr+Entrée/Suppr/Retour arrière/Échap script actions; AI menu; « Revenir à
   cette version » keeps a backup.
6. **Items 19, 49, 50**: tooltips near screen edges on Windows 10 and 11 at several DPI scales; hook
   order around a SendInput rehook; the send-mode measurement.
7. **Hotstrings** (items 34, 37, 102, 104, 105, 129): follow
   [GROUP2-WINDOWS-TODO](handovers/2026-10-04-parallel-containers/GROUP2-WINDOWS-TODO.md); with no
   Ergopti layout installed the shipped pack, suffix rules and magic-key repeat appear once;
   `update` never proposes `date`.
8. **Layout switching** (item 38): AZERTY with emulation to native Ergopti and back keeps AltGr
   usable without a reload, also on an AZERTY-style AltGr (LCtrl+RAlt) and a Kana layout.
9. **Touchpad registry** (item 13): values restored after OFF and removal; kept after a refusal.
10. **Managed network** (item 62): the twelve steps of the
    [Group 6 Windows handover](handovers/2026-10-04-group6-windows/README.md) behind a company
    proxy.
11. **CapsWord auto-off**: delays, the eight default delimiters, each pointer kind, the LAlt then
    CapsLock trigger.
12. **AI off (#97)**: no local server sweep, no AI hotkeys, a refused AI hotkey leaves the driver
    running. Item 143: time the AI toggle behind an unfinished startup (3.05 s on the smoke).
13. **Prediction chord (item 112)**: in Notepad each slot's modifier+digit inserts that prediction
    and its correction form; the shortcut column is right-aligned and muted.
14. **Item 114**: observe the resident process during a prediction-key (1-5) or AltGr+Enter stall
    and collect the Notepad stale-admission diagnostics before changing anything.
15. **Items 30, 46-48, 54/81, 63, 73, 88, 96-98, 107, 108, 125, 138**: physical magic key under
    emulation; a real local model (chat, download, consent, pause/resume/shutdown, HTTPS behind the
    system proxy); installed menus (captions, unavailable reasons, state after restart);
    brightness up/down and refusal without a backlight; physical-key labels after a locale change;
    prediction tooltip typography; emulation picker precedence and dead-state output; chosen
    physical positions and arbitrary outputs including dead keys; number-row and magic-key
    shortcut delivery; free-text translation dialog; diagnostic export copy, write, reveal and
    browser.

### Mac

- [ ] **L46 three-finger swipe vs scroll** (`tmp/wip-three-finger-swipe2`): re-enable
      `swipe_3_up`/`swipe_3_down`, scroll with two fingers for a few minutes, no tab switch; a
      deliberate three-finger swipe (slow, flick, staggered) switches tabs every time, and a miss
      leaves a DEBUG `Three-finger candidate rejected by <gate>` line in the day log.
- [ ] **Issue #100 retest** (after v1.0.5: 2353a72eed, 25411ee080, e57f4cce77): with Ollama.app and
      a PAC proxy, enabling the AI downloads the model; with the Ergopti menu held open, no lease
      timeout.
- [ ] **Issue #99**: `memory_pressure | tail -1` during lease errors; oMLX listed (DEBUG
      line `Local server 'omlx' probe answered ...`, else
      `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/v1/models` and
      `lsof -nP -iTCP -sTCP:LISTEN | grep -i omlx`); `Ollama bootstrap failed (exit=137)` with an
      external Ollama; which login item starts the second Hammerspoon; declining the download
      opens no error window. Details:
      [issue99-ai-startup-updater.md](todo-agents/issue99-ai-startup-updater.md).
- [ ] **Fixes of October 21-22**: tap and hold pickers (steps in
      [macos-tap-hold-action-picker.md](todo-agents/macos-tap-hold-action-picker.md)); tap delay
      row opens the AppleScript dialog, « Use global delay (…) » right below; Shortcuts group
      restore/clear; Ctrl+S open target (as on Windows, registry keys answer « Windows only »);
      Backspace word start (Terminal Return, `ab`, three Backspaces, `c★`; TextEdit
      Option+Backspace; Safari Cmd+L).
- [ ] **Item 38**: no "Lease-bound input startup failed" or spurious "Layout poll detected change";
      Right Option + Return/Delete/Backspace/Escape run script actions; no Python or Rosetta notice;
      MLX behind a proxy; Versions rollback.
- [ ] **Installed app**: 7 (Cocoa Finish, folder disagreement, native restart), 116 page, 120
      provider menu, 122 Diagnostics focus, 123 shared export, 127 VS Code bridge retirement, 13/35
      guardian registration and retirement on both architectures, 24 Login Items, 43 « Retirer les
      anciennes règles » on an upgrade, 44 CapsWord pointer cancellation, 126 trackpad gestures,
      111 two displays, 30 magic key on ISO and ANSI, 46-48 and 88 a real local model and the
      tooltip typography, issue 94 (tap-hold menu refusal, symbol-wrap clipboard, ISO/ANSI captured
      once), 119/130/136 MLX PAC download, code 74, Homebrew live upgrade.
- [ ] **Shell and file edge cases**: `pipefail` and `printf %b` under bash 3.2 (automated: collector step
      `system_bash`), the native HTTPS
      downgrade refusal, `hs.fs.attributes` on a FIFO, the read-only dashboard with a hot journal.

### Linux (no machine available)

Wizard (7) on Wayland, physical input, installed-daemon restart; real kernel capture (93); magic
key grab, injection and hotplug (30); tap delay row (zenity/kdialog), group restore/clear, open
target, Backspace word start (GNOME Terminal Enter, `ab`, three Backspaces, `c★`; gedit
Ctrl+Backspace; Firefox Ctrl+L). L46: a two-finger scroll with a thumb resting reports two
fingers, a brisk three-finger tap still reports `tap_3` (the peak must hold two frames).

## CI final acceptance receipts

Qualification-only items: each closes on a named green hosted or native run, recorded here. They are
not open software work.

- [ ] **16/38.** One complete non-release three-OS checkpoint on the final source (units, E2E,
      packaging, installation, launch) with exact receipts.
- [ ] **36.** macOS Package job: Sparkle install/refusal/retry/relaunch, both Brew positives,
      full-policy denial, Brew archive scenarios (the deny-removal AppleEvent positive needs a Mac);
      Linux Flatpak/AppImage installation and PAC/session/TLS delivery.
- [ ] **40.** Signed native execution of the eight Karabiner default/recommended/switch variants.
- [ ] **63, 71.** Brightness joined source; retired Metrics-window shortcuts across a three-OS full
      save and installed upgrade.
- [ ] **104, 105.** Common autocorrection sections (native Windows/macOS, per-section E2E, package;
      the 140-rule corpus is never regenerated from production); dynamic hotstrings on macOS.
- [ ] **34, 37, 102, 129.** Native Linux/macOS delimiter transactions; macOS packaging with both
      extension TOML files; Windows native cases and Fedora/Alpine ShellRunner fixtures; Linux E2E.
- [ ] **121, 123, 137.** AI Agent submenu composed-menu qualification; native Linux export
      write/close refusal; provider published before model loading (macOS).
- [ ] **30.** Linux tests of the physical magic-key notice (407db5fd50).
- [ ] **Carbon and daemon-report Swift.** Carbon fixture compilation and both-architecture
      receipts; daemon-report Swift allocation failures on Intel and Apple silicon.
- [ ] **CodeQL Go.** After the `native_http` Go module is published, re-enable Go and check a fresh
      non-empty analysis.
- [ ] **Native Windows TLS fixture.** Seven `native_tls` cases fail since Git 2.56 moved the SDK to
      ucrt64; the trust install stays at `before_add`. Cause not proved.
- [ ] **Full Windows AHK suite.** Never completed green locally (about 90 min single-threaded);
      shard it, never raise `_SUITE_MAX_TIMEOUT_MS`.
- [ ] **Intermittent fixtures.** Close each after it stays green, root-cause a relapse from the
      logged attempt: Linux window switch, cffi-lua clone, desktop-webview AI focus, Windows
      `config` group (managed-network budget, artifact curl relay), macOS Go
      `TestIdleDeadlinePhysicallyRetiresPeer`, macOS Swift
      `testBridgeHardDeathLeavesNoReceiptAndGuardianClosesOriginalScope` (failed once on macOS 26).

## Decided, do not re-raise

- **Delta updates (item 22)**: withdrawn by the maintainer; full signed downloads stay below 20 MB.
  Reconsider only if release size or measured repeated-download cost grows
  ([rationale](handovers/2026-10-04-parallel-containers/PARALLEL-WORK.md#delta-updates-decision)).
- **Report a bug has no review screen**: the report is reviewable on GitHub (October 21).
- **Not defects after native review**: L48, L83 and the release-notes CR handling on Windows; L30,
  L85, L88 and L18 on macOS.
- **Configuration file style (October 20)**: `config.toml` keeps the 5/3 blank-line style everywhere
  (templates and the Windows writer); `windows/_generated/config_template.toml` changes only
  through `npm run build:manifest`; the release list and its ETag persist across restarts.
- **Credentialed redirects** are not followed, by design (L42).
- **Unsigned stable Windows releases** are authorised until SignPath signing is integrated (item
  132).
- **The AHK suite watchdog** is not raised to make a run finish; shard the suite instead.
- **Obsolete configuration scalars** are preserved until explicit cleanup; ordinary saves refuse a
  colliding subtree (ADR-009).
- **Unicode general categories and graphemes** are out of scope for the metrics character classes
  (L137); there is no Lua 5.4 AT-SPI backend, the FFI needs LuaJIT (L67).
- **A stored layout or number-row choice is never rewritten** by a layout change: where it cannot
  apply it stays ticked, greyed and suffixed « — non appliqué », and applies again by itself.
- **Moving the Karabiner lease token out of the rule text** is impossible: Karabiner compares
  variables only to fixed values. Fewer recovery deploys need fewer lease failures first.
- **Do not deduplicate the macOS Swift launcher XCTest classes between E2E and Build.** The managed
  native E2E cells run the SDK, logger and daily-log cohorts on macOS 15 (Apple silicon and Intel);
  Build's full Swift run repeats them on macOS 26 (`macos-latest`). Skipping them in Build saves
  about 42 s of 364 s of test time (measured 2026-10-20, run 39388400901) and nothing on the
  critical path, and drops their only macOS 26 coverage. Job, lot and step names state each cell's
  macOS version, read from `HOSTS` in `tools/ci/macos-stage-roles.cjs`.
- **Windows unit shards are grouped by test category, not by duration.** A new test file with no
  category fails a gate; a minute more of wall time buys a CI whose red job says what broke.
- **Maintainer workflow**: partial work is delivered into dev after the feasible container or CI
  work, with native or device gaps documented here rather than holding a branch.
