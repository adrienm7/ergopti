# Parity pause item: resume notes (worker H)

State on 2026-11-14 at 15:08 Paris, for whoever continues « Parity audit
pause and resumption » in [TODO.md](../../TODO.md). The rule is EDD-1 (decided
by the maintainer on 2026-11-12): a pause stops typing, not configuration.
Configuration rows run while paused and apply on resume; typing stays inert.

## Landed on `dev`

- 59c36cc7 (CI run 43574300302): the third and fourth pause passes. See the
  [pause report](../audits/platform-parity/2026-11-12-pause/report.md).

## On branch `claude/ergopti-todo-parity`, not landed

Head 6cd285e7, proof run 43603030354 (dispatched 2026-11-14 about 14:50 Paris).

- `fix(llm): let the AI switch turn the AI off while paused`: Windows,
  macOS and Linux. Turning the AI on still waits for resume (it starts model
  warmups and may offer an install); decided by the agent on 2026-11-14,
  accepted by the coordinator.
- `fix(llm): choose, create, clone, edit and delete AI profiles while
paused`: all three OS. The macOS profile shortcut waits for resume (it binds
  a hotkey) through the new `llm_custom_profile_shortcut_ready` key in
  `_shared/menu/data/menu.toml`.
- `docs(hotstrings): record the maintainer's confirmation of the paused
programmable source load`: option (a), confirmed on 2026-11-14.
- Two test commits that follow the Linux profile rows.

Landing is on hold: the coordinator asked for no `dev` push until the
structure migration (S03–S12) lands. Then rebase onto the moved paths, run the
gates, read every red job of the proof run test by test against the baseline,
push, update the « Resume here » state line and message the coordinator.

Open on that run: the Windows ui test `test_native_dialog_titles.ahk:40` failed
once on run 43595483595 (a private AutoHotkey child that did not finish within
15 s) and passes on dev run 43597043448. If it fails again on 43603030354, it
must be root-caused before landing.

## Still open in the pause item

Order asked by the coordinator on 2026-11-14 at 19:06 Paris: (1) the AI model
and API rows on the three OS, (2) the macOS slot and legacy shortcut rows,
replayed on resume, (3) the macOS magic key capture, (4) the audit that every
typing feature stays inert while paused. One CI run per block.

Done for (1) on the branch, not landed: dfb5df1a « warm a model chosen while
paused on resume on macOS ». `modules/llm/init.lua` already skipped a warmup
while paused but never replayed it; `ui/menu/menu_llm/warmup_controller.lua`
now hands it to `modules.llm.warmup_controller.defer_to_resume`, which
`resume_warmup` runs. Linux reschedules its warmup on resume
(`warmup_target` is nil while paused); Windows defers the bridge start
(`bootstrap_pending`, `LLM_Menu_OnResume`).

Left for (1), with the gates found so far:

- macOS: `ui/menu/menu_llm/model_selector_page.lua` (`ctx.is_paused()` at the
  page build, install state, selection and the bridge entry points, about six
  sites), `ui/menu/menu_llm/api_panel.lua` (`paused` and `native_unpaused`,
  about twelve sites) and the `llm_model` row in `ui/menu/menu_llm/init.lua`
  (`MenuLayout.row_disabled("llm_model", is_disabled, paused)`).
- Linux: `ui/menu/llm_backend_rows.lua` (two sites) and `delete_model` in
  `ui/menu/menu_llm.lua`.
- Windows: `ui/menu/menu_llm/menu_models.ahk` and `menu_api_entries.ahk` (ten
  `A_IsSuspended` sites); the tray still greys the whole AI submenu while
  paused (`TrayMenu_ApplyPauseGreying`, the EDD-1 on AHK item).
- Downloads and deletions are installs: EDD-1 keeps them available while
  paused, but each must not start a runtime (warmup, server) until resume.

Then (2), (3) and (4) as listed above.

## Traps met

- Structural JS proofs pin exact source text:
  `tools/lib/menu-native-llm-parent-binding.cjs` (the Linux `toggle_ready`
  body), `tools/test/test-menu-parity.cjs` (its seams),
  `tools/test/fixtures/personal-section-owner-counterexamples.cjs` (a hash of
  `macos/ui/menu/menu_hotstrings_custom.lua`, recomputed on every rebase that
  touches the file).
- `tools/test/test-shared-literal-inventory.cjs` is a ratchet: a removed
  duplicate needs `--update-baseline` in the same change.
- `_shared/settings/data/features/behaviors.json` pins owner hashes; after a
  change to an owner file, re-pin and run
  `node tools/codegen/codegen-feature-inventory.cjs`.
- Run the whole Linux suite, not only the ui, modules and infra groups: the
  hotstring terminator tests live in another group.
- Use `--module menu_llm` for the macOS AI tests; `--only` with a module name
  can miss stubs.
