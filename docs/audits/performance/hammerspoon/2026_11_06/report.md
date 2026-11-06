# Hammerspoon performance pass: macOS field report 2026-11-06

Baseline source: `origin/dev` at `0fc9e0be23`. Field evidence: branch
`field/mac-2026-11-05-dev`, folder `docs/field-reports/mac-2026-11-06_100244`
(`analysis.md`, `ErgoptiPlus_2026-11-06.log`, `field_run/26_diagnostics.json`).
The field build was `19c96ca86` (dev channel 0.0.0-dev.166) on macOS 26.6.2,
arm64, with the log window 2026-11-06 00:11:43 to 10:12:40.

No Mac was available for this pass. Every "before" figure below is the field
measurement; every "after" figure is either an operation count measured under
Lua 5.4 through the driver's own test doubles, or a structural proof that the
work left the measured path. No native latency is claimed for an "after"; the
next field run is the measurement that confirms or refutes each change.

## Budget verdicts and outcomes

| Field measure                    | Budget | Field (before)                               | Root cause                                                                                                                              | Outcome                                                                                                                                                                           |
| -------------------------------- | ------ | -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| diagnostics phase A              | 5 ms   | 10.2 ms; `permissions` = 9.2 ms              | `hs.accessibilityState` and `screenRecordingState` are TCC queries answered by another process, run inside phase A                      | Fixed on dev by the integrated parity fix: phase A reads the last known Accessibility and Screen Recording answers, never a TCC query. Expected phase A about 1.0 ms (10.2 - 9.2) |
| healthcheck.sync                 | 5 ms   | 10.2 ms (one occurrence)                     | Same log line as phase A                                                                                                                | Fixed with phase A                                                                                                                                                                |
| hotpath:preview.rebuild          | 5 ms   | 7 over, max 9.29 ms, parent keydown          | First preview of a category per session read that category's TOML metadata on the keystroke (snapshot stat, loadfile, full source read) | Fixed for 4 of 7: the boot prewarms every enabled TOML group's metadata on run-loop turns; the preview then performs no file read (counted). 3 of 7 have no attributed cause      |
| hotpath:tooltip.show_predictions | 5 ms   | 12.02 and 10.99 ms, first frame of a request | The width was found by assembling the whole styled block once per reserved slot, then once more to render                               | Fixed: one sizing pass. Native text layouts per show 11 to 7 for 3 slots, 15 to 7 for 5 (counted through the renderer double)                                                     |
| main_thread.hold (menu.rebuild)  | 250 ms | 537 ms; menu.rebuild 495, Shortcuts 341.9 ms | Not attributed: the Shortcuts submenu took 30 to 47 ms in every other rebuild; nothing inside it was instrumented                       | Not fixed. Each Shortcuts stage now records a `menu_shortcuts.<stage>` phase so the next hold report names the stage                                                              |

## Evidence

### Diagnostics phase A (items 1 and 4)

`26_diagnostics.json` carries the codes `phase_a_ms_10`, `phase_a_permissions_9.2`,
`phase_a_issues_0.7` and `fail_phase_a_budget`. The other two phase A runs of
the same log (09:44:29, 10:09:06) took 2.9 and 4.2 ms: the TCC answer time
varies, which is why it does not belong on a path with a 5 ms budget.

At integration, dev already carried a fix for the same cost from the parity
campaign: phase A reads the answers of the boot's and the latest capture's live
reads (`accessibility_permission.last_known`, `screen_capture.last_known_permission`),
unknown before one. This pass's alternative (live reads moved into the
`local_state` probe) was therefore not integrated.

### Preview rebuild (item 2)

Slow lines and the TOML snapshot hits next to them:

| Slow preview.rebuild | ms   | Metadata read in the same keystroke                      |
| -------------------- | ---- | -------------------------------------------------------- |
| 09:44:22:562         | 9.02 | `french/magickey.toml` (first star preview)              |
| 09:48:32:952         | 5.70 | `personal_hotstrings.toml` (first personal preview)      |
| 09:49:29:915         | 5.93 | none logged                                              |
| 09:51:29:215         | 9.29 | none logged; an LLM request started 167 ms earlier       |
| 09:52:17:668         | 5.35 | none logged                                              |
| 09:52:36:396         | 5.82 | `french/autocorrection.toml` (first autocorrect preview) |
| 10:05:48:492         | 7.75 | `french/magickey.toml` (first star preview after reload) |

The phase summary at 09:47:32 puts `preview.providers` at 0.93 ms and
`preview.resolve` at 0.69 ms maximum while `preview.total` reached 9.02 ms, so
the time was in the row construction, which is where `hotstrings_config.resolve`
runs per candidate. Regression: `test_hotstrings_config_meta_prewarm.lua`
counts the category TOML reads of a preview after the prewarm (0) and checks
that the boot asks for the prewarm after the groups are registered.

### Prediction tooltip (item 2)

Both slow lines are the first frame of a request ("1 active, 3 reserved").
`assemble_blocks` already measures the widest line over both renderings of
every row, and the footer never reads the highlighted index, so the width is
index-invariant and one sizing pass gives the same width. Regression:
`test_tooltip_llm_sizing_once.lua` counts `minimumTextSize` calls for 1 and 5
reserved slots and requires them equal.

### Menu rebuild hold (item 3)

The 537 ms hold at 10:12:36:167 followed a layout notification
`Ergopti_v2_2_2_plus -> French` at 10:12:35:597. Its phases: menu.rebuild
495.2, menu_item.shortcuts 341.9, menu_item.keyboard_layout 116.1
(rows 58.3, sources 57.1). The Lua heap fell 52 to 40 MB inside the hold, so a
collection cycle ran in it. The rebuild back to Ergopti two seconds later was
under budget. Reading the stages of the submenu (keyboard slots, tap keys, key
combinations with their fingerprinted picker cache, wrap symbols, extension
menus, script control, CapsWord) found no work that depends on the input source
at a cost the code shows, so no change is proposed without a measurement.
Regression: `test_menu_shortcuts_stage_phases.lua` requires one phase per stage,
including a stage that raises.

## Rejected or deferred

- Raising any budget: rejected by the task; none was changed.
- Caching the permission states: rejected; a cached grant can be stale after a
  user revokes it in System Settings, and the probe already keeps phase A free.
- The other main-thread holds over 250 ms (501 ms ignored-window probe at
  09:43:25, 469 ms in `platform/remap/init.lua` at 09:43:25, 376/328/324 ms
  prewarm rebuilds with `shell.find` 29 to 44 ms) are outside this pass.

## Unmeasured paths

Native latency after each change; the three preview.rebuild lines without a
metadata read; the content of the 341.9 ms Shortcuts stage.

## Gates

Run in a Linux root container (Lua 5.4.6, Node 22.23.4), so the host differs
from the CI runners and `verify-change`/`test:js` refuse to start; the
selected gates were run directly and compared with `origin/dev`.

- macOS Lua suite: `origin/dev` 27885 passed, 291 failed; this branch 27892
  passed, 291 failed. The failing case names are identical (root-container
  history); the 7 new cases pass.
- macOS e2e: 139/183 on both, the same 44 failures.
- Strict convention lint: OK. Prettier on the changed files: OK.
- JS checks reading the changed shared files (healthcheck model, timing
  registry liveness, logger vocabulary, tooltip and timing single sources):
  no new finding; the remaining reds reproduce on `origin/dev`.
- Linux managed HTTP native: refused at its native prerequisites in this
  container, not run.
