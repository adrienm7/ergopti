# Small native units

Audited source: `6d92a18c8c` (`dev`). Date: November 21, 2026. Eighth campaign
in the order of the [2026-11-19 census](../2026-11-19-census/report.md), after
the [metrics views](../2026-11-21-metrics-views/report.md). The units are
small and mostly OS-specific, so each was read against its reason text and,
where one exists, the feature its counterparts carry under another name.

## Scope

The seven units the census names, with the counterparts they answer to:

- `linux/modules/keep_awake.lua` (the logind idle inhibitor), against Windows
  `modules/shortcuts/win.ahk` (the activity simulation) and macOS
  `modules/shortcuts/actions/system.lua` (the jitter and F18 heartbeat), with
  the shared `[keep_awake]` timings and the `awake_ms` producers of the three
  keystats;
- `linux/modules/take_note.lua`, against Windows `modules/take_note.ahk` and
  the `shortcuts.take_note` settings of the features manifest (macOS has no
  take-note action: Quick Note);
- `windows/native/ergopti_lua_export.c` and its host
  `windows/ui/layout_manager/editor_window.ahk`, against the macOS and Linux
  `source_export_step` (`_shared/layouts/engine/composer/export_step.lua`,
  `manager_bridge.lua`);
- `macos/ui/virtual_hid_update.lua` and `macos/ui/legacy_rules_cleanup.lua`
  (macOS only: `platform_reason.remap_engine_is_per_driver`), with the remap
  bridge reasons they report;
- `macos/native/SystemSwitcherState.swift` with
  `adapters/system_switcher_runtime.lua`, and
  `linux/native/archive_output/archive_publication.c` (no feature row: native
  ports with no counterpart).

Read for each: the behaviour, the error handling (fail fast, localized user
messages), the logging pairs, the timings against the shared registry, the
privacy and the teardown. Source reading, the AutoHotkey suites, the macOS
and Linux suites under WSL from `git archive` copies; nothing ran on a
desktop.

Checked and kept:

- **Linux keep-awake.** An inhibitor, not a simulation, by its reason: it
  reports active only once `systemd-inhibit` printed its ready line, fails
  closed with `notify.keep_awake_failed` when the command is missing, the
  process settles or the ready line misses the startup bound, and its stdin
  pipe dies with the daemon. Acquired and released are logged; a finished
  session is credited to `awake_ms` (KMD-3); the pause stops it and the resume
  gives it back, as on Windows and macOS.
- **Keep-awake cancellation.** Windows and macOS stop on a key, a click or a
  move beyond the jitter, both ignore modified keys and their own heartbeat;
  the tick bounds and the return delay are equal (SNU-01 aside).
- **Daily note.** Linux keeps an existing note's bytes (an empty append),
  refuses a symlink, opens the registered text/plain editor by its desktop id
  and never names the private path in a user message. Windows defaults to an
  undated `Notes.txt` (SNU-10).
- **Export host.** The C host opens only the base, string, table, math and
  utf8 libraries, admits only dotted lower-case module names inside the shared
  folder, bounds every file at 4 MB and the step's input at the defaults'
  `max_export_step_bytes`, and prints its identity for the digest check; the
  AutoHotkey host runs it with the defaults' `export_step_timeout_ms`, removes
  the staged input on every end and logs started then ended, refused or
  stopped. Only the refusal code differed (SNU-07).
- **Karabiner dialogs.** Nothing runs before the click, a cancelled
  administrator prompt shows nothing, a success reloads after its report, the
  cleanup makes a backup first and logs start then success or error. Only the
  texts carried raw reasons (SNU-05, SNU-06).
- **System switcher helper.** Read-only: it reads the held modifier and Tab
  states, the event-tap and Accessibility grants, and prints at most 512 bytes
  of JSON; no key content, no child, no input. The runtime admits it by the
  signed bundle's digest file and inode, never from `PATH`.
- **Archive publication port.** Paths are opened component by component with
  `O_NOFOLLOW`, the transfer folder is a random 0700 child checked by inode,
  the archive is an `O_TMPFILE` linked only after its hash, every step is
  bounded by the caller's monotonic deadline, and a refused close or link is
  kept as debt instead of retried. No user message, no log: the Lua owner
  (`infra/archive_output.lua`) reports.

## Fixed

| Id     | OS      | Sequence                                                                        | Reference                                                                                    | Before                                                                                                                                                    | Regression                                                                                                                |
| ------ | ------- | ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| SNU-01 | Windows | Tune `[keep_awake] tick_min_ms`, `tick_max_ms` or `return_delay_ms`             | macOS reads the three from the registry                                                      | `win.ahk` kept its own `AWAKE_TICK_MIN_MS`, `AWAKE_TICK_MAX_MS` and `AWAKE_RETURN_MS`, which the registry named as consumers: a tuning changed macOS only | `keep-awake: the jitter tick and cursor return read the shared registry (snu-01)` (`test_keepawake_session_parity.ahk`)   |
| SNU-02 | Windows | Run keep-awake, stop it, open the typing dashboard                              | macOS and Linux credit every finished session to `awake_ms` (KMD-3)                          | No Windows producer wrote a `passive_period` of kind `awake`: the rebuild summed it, but the day's keep-awake time was always 0                           | `… a finished session is credited to awake_ms (snu-02)`, `… stopped by a pause …` and `… idle keep-awake credits nothing` |
| SNU-03 | Windows | Run keep-awake, stop it, read the log                                           | macOS logs enabled and disabled, Linux acquired and released                                 | Neither the start nor the stop was logged                                                                                                                 | `keep-awake: the session's start and stop are logged (snu-03)`                                                            |
| SNU-04 | macOS   | Run keep-awake, pause the driver (or quit), open the typing dashboard           | Windows (SNU-02) and Linux credit a session the pause or the shutdown ends                   | `stop_awake` retired the session without crediting `awake_ms` or logging: only the user's toggle and the activity auto-off credited it                    | `keep-awake credits a session the driver stops (snu-04)` (`test_keep_awake_monotonic_grace.lua`)                          |
| SNU-05 | macOS   | Accept the Karabiner driver update with the network down or a refused signature | Windows and Linux dialogs say the cause in the user's language and keep the code for the log | « The driver could not be updated (vhid_update_digest_mismatch). »: a code in no language, with nothing to do                                             | `names each refusal's cause in the user's language, never its code (snu-05)` (`test_virtual_hid_update.lua`)              |
| SNU-06 | macOS   | The old ErgoptiPlus rules cleanup fails, or its regeneration does               | As SNU-05                                                                                    | The bridge's reason (« script-paused », a publication detail, « removal-raised ») sat inside the localized sentence                                       | `reports the precise failure of each stage` (`test_legacy_rules_cleanup.lua`)                                             |
| SNU-07 | Windows | Download the XKB or KLC files while the export host cannot read a shared module | macOS and Linux answer the defaults' export code (`target_export_refused`) for every refusal | The host's own `lua_export_host` reached the page, which no locale names: « error.generic » with the raw code                                             | `… runs lua_export, bounded (lua-export-run)` (`test_keystats_reader_ngram_sources.ahk`)                                  |
| SNU-08 | Linux   | Read the parity table or the menu reason of `shortcuts.take_note.*`             | A reason text says what that OS does instead                                                 | The folder and dated settings Linux ignores carried the shortcut chords' reason, which says nothing of the Linux note                                     | `the Windows-only note settings say where the Linux note goes (snu-08)` (`test_take_note.lua`)                            |
| SNU-09 | Linux   | Take a note with a read-only notes folder, or a text editor that fails to start | Windows logs every refused note (`TakeNote` ReportError)                                     | The user was told; the log had no line                                                                                                                    | `every refused note is logged (snu-09)` (`test_take_note.lua`)                                                            |

Notes:

- **SNU-01.** `AwakeNextTickMs` and `SimulateActivity` read `TimingsGet`;
  the registry's comments name them. The shared literal inventory fell by
  three Windows durations, and its baseline was lowered.
- **SNU-02.** `KLSystemEventOwner.RecordCompleted` enqueues a completed
  measurement no physical edge reports, through the same append, privacy and
  retry path as lock and sleep; `KL_RecordAwakeSession` credits nothing when
  the metrics are off, and a session a pause stops stays pending for the idle
  tick's drain after the resume instead of logging a delivery failure. A
  session still running when Windows exits is not credited (SNU-11).
- **SNU-04.** One `credit_awake_session` serves the toggle, the auto-off and
  `stop_awake`; a refused credit is logged instead of swallowed.
- **SNU-05.** Four keys replace `karabiner.vhid_update.failed` in the 21
  locales: `failed_download` (download, size, digest and store),
  `failed_signature`, `failed_install` (install, activation) and
  `failed_unavailable` (unpinned, not offered). The module refuses to load
  when a reason of `runtime_vhid_update.REASON` has no message.
- **SNU-06.** `removal_failed` and `apply_failed` lose their `{1}` in the 21
  locales and say the log has the details; the reason stays in the error line.
- **SNU-08.** `platform_reason.take_note_settings_are_windows`, in the 21
  locales, is a `not_yet` reason: a folder and a dated choice are possible on
  Linux but not delivered.

## Open

- **SNU-10 (medium, Windows, decision):** the shipped default note folder is
  `D:\Bureau` (`[[features.shortcuts.take_note]] destination_folder`, the
  config template and the example), a path that exists on one machine. The
  code's own fallback is `A_Desktop`, used only when the value is empty, so a
  fresh install on another PC writes into a missing folder. Follow-up: default
  to an empty folder that means the desktop, or to the desktop itself, after
  the maintainer confirms.
- **SNU-11 (low, Windows):** a keep-awake session still running at exit is not
  credited: only the pause calls `StopActivitySimulation`, and the exit path is
  refusal-capable, so stopping keep-awake there would leave it off after a
  refused exit. macOS (`stop_awake` at teardown) and Linux credit it.
  Follow-up: credit from the keystats' terminal drain without stopping the
  session.
- **SNU-12 (low, all, decision):** the end of a session is told differently.
  Windows shows « stopped » when the user's activity cancels it and at a
  pause; macOS stays silent on both (« the user is clearly back ») and shows
  « off » only for the toggle; Linux has no activity cancel (an inhibitor) and
  says « off » at a pause.
- **SNU-13 (low, Windows and macOS):** the jitter radius, 80 px, is typed in
  `win.ahk` (`AWAKE_JITTER_PX`) and `system.lua` (`AWAKE_JITTER_X`, `_Y`) with
  no gate between them; the timing registry holds only durations. Follow-up: a
  shared keep-awake geometry entry, or a single-source test.
- **SNU-14 (low, Linux):** the inhibitor's poll (1 s) and ready bound (5 s) are
  driver literals in `keep_awake.lua`, not registry timings.
- **SNU-15 (low, macOS):** `legacy_rules_cleanup.lua` shows its deferred report
  without a protected call, where `virtual_hid_update.lua` logs a dialog that
  raises; a failing alert there leaves no line.

Native receiving, in `TODO-tests-windows.md`, `TODO-tests-macos.md` and
`TODO-tests-linux.md` (field point `small_native_units` on macOS and Linux):
the Windows keep-awake log lines, cursor timings and dashboard minutes across a
stop and a pause, and the export host's refusal text (SNU-01 to SNU-03,
SNU-07); the macOS minute credited across a pause and the two Karabiner
failure texts (SNU-04 to SNU-06); the Linux refused-note log lines and the
note settings' reason (SNU-08, SNU-09).

## Proof

Commits `0453ee295c` (SNU-01 to SNU-03), `511c2eaf9a` (SNU-04), `450dd536fc`
(SNU-07), `3521d582f5` (SNU-05, SNU-06), `cb1fbe565c` (SNU-08, SNU-09),
`dc2fa1ce33` (field points).

- **Red on the old code.** Each regression was run against the owner it pins
  restored from `6d92a18c8c`, or the old expression inside the new seam:
  - SNU-01: with `-200` for the return delay, « the cursor returns after the
    shared [keep_awake] delay » fails.
  - SNU-02: without the credit call, the three cases fail « expected: 1,
    actual: 0 » rows; without the paused branch, « a session held for the
    resume is not a delivery failure » fails « expected: 0, actual: 1 ».
  - SNU-03: without the stop line, « the stop is logged once » fails.
  - SNU-04: with the old `system.lua`, « a pause credits … » and « a shutdown
    credits … » fail.
  - SNU-05, SNU-06: with the old `virtual_hid_update.lua`, two cases fail
    (« vhid_update_store_failed »); with the old `legacy_rules_cleanup.lua`,
    « reports the precise failure of each stage » fails.
  - SNU-07: with the old `editor_window.ahk`, « the page receives the shared
    export code » fails on `"code":"lua_export_host"`.
  - SNU-08: with the old `manifest_data.lua`, the reason case fails on
    `shortcuts.take_note.dated_notes`; SNU-09: with the old `take_note.lua`,
    « each refused note leaves its log line » fails.
- **Green on the new code.** AHK through `ahk-parallel --fresh`: `snu-` 5 of
  5, `keep-awake` 24 of 24, `system` 26 of 26, `neutral slots` 13 of 13,
  `lua-export` 2 of 2; `test-ahk-encoding.cjs`. macOS under WSL (`lua5.4`) from
  `git archive` copies: `test_keep_awake_monotonic_grace` 11 of 11,
  `test_keep_awake` 10, `test_rebind_preserves_keep_awake` 10,
  `test_fixture_scope` 9, `test_shortcut_delivery` 12,
  `test_virtual_hid_update` 5, `test_legacy_rules_cleanup` 6,
  `test_owned_runtime` 8, `test_field_todo_coverage` 4. Linux under WSL
  (`luajit`, `unset DISPLAY WAYLAND_DISPLAY`): `linux-take-note` 6 of 6 and the
  coverage case « tags every open line … »; the other failures it printed were
  the copy's missing `layouts/` and `macos/` trees.
- **Gates.** The locale gates (`test-locale-catalogue-complete.cjs` with 5,430
  keys, `test-locale-hints-quote-live-labels.cjs`,
  `test-action-labels-have-locale-keys.cjs`,
  `test-i18n-referenced-keys-resolve.cjs`),
  `test-error-messages-say-how-to-recover.cjs`,
  `test-no-hardcoded-ui-strings.cjs`, `test-shared-literal-inventory.cjs`
  (baseline lowered by three), `test-linux-feature-parity.cjs`, the platform
  parity table and the feature inventory regenerated,
  `test-timings-registry-liveness.cjs`,
  `test-keystats-timings-single-source.cjs`, the three
  `test-no-pinned-source-reads*.cjs`, `test-config-key-literals.cjs`,
  `test-logger-lifecycle-pairing.cjs`, `test-logger-scalars-single-source.cjs`,
  `field-todo-summary.py --check-doc` for macOS and Linux, the formatter and
  `lint-conventions.js --fail-on-violations`.
- **Not run here.** `test-features-manifest-no-drift.cjs` (it needs
  `makensis` for an unrelated generator); the full macOS and Linux suites; the
  Swift and C units (unchanged); a desktop; `npm run test:js` and
  `verify-change` (they refuse this checkout's Node pin).
