<!-- docs/todo-agents/windows-updater-freeze-menu-census.md -->

# Windows updater release-list freeze and the last native menu rows

Owner: the Windows agent of 2026-10-21 (win3). Local commits only: nothing here is pushed.

## 1. Release-list freeze: software done, seal pending

Commits on local dev:

- `8a43bd805c` perf(windows): decode only the release list members the updater reads. The JSON
  owner validates the whole list but builds only the named members (`JsonArrayObjectMembers`,
  `JsonObjectMembers`, decode tally `JsonDecodeTally`); unread values go through a validating skip
  with an anchored PCRE fast path (no astral code point unless a strict `WideCharToMultiByte` pass
  proved the text has no lone surrogate; exact walk on anything else or on the PCRE match limit).
  The updater decodes the list once per response, keeps the index on the conditional-GET entry (a
  304 decodes nothing), reads the selected release one member at a time, and the Versions window
  decodes a release's notes only when shown. Request, 100-release window and ETag cache unchanged.
  Regression test `tests/unit/modules/updater/test_updater_release_list_budget.ahk`
  (`--only "release-list-budget"`): 40 containers instead of 6 560 with the old core.
- `1b7e8a95f0` perf(updater): the shared Lua twin indexes the list from one decode
  (`release_parser.index_releases`, used by `check_result.classify`), with contract cases.

Measured on the real list (5.96 MB, fetched 2026-10-21), inside the AHK suite on the loaded laptop:

| Path                 | Before          | After          |
| -------------------- | --------------- | -------------- |
| 200, background      | 6.1 to 7.6 s    | 0.36 to 0.48 s |
| 200, manual          | 12 to 14 s      | 0.37 to 0.42 s |
| 304                  | 6 to 13.6 s     | 0.04 to 0.11 s |
| Versions window list | 6.2 to 7.3 s    | 0.23 to 0.41 s |
| Containers built     | 3 008 (x2 man.) | 100            |
| Decoded code units   | 5 034 639       | 5 917          |

Next step (blocking the seal check): `static/ergopti_plus/windows/infra/config_io.ahk` is dirty
from another agent, and the sealer refuses while a sealed file differs from the ref. Once it is
committed, run `node tools/ci/seal-windows-updater-original-source.cjs --ref <full SHA of HEAD>
--write` and commit `tools/ci/windows-updater-original-diagnostic-cohort-inputs.json` alone
(core.ahk and run_all.ahk changed).

Gates run: conventions lint, AHK encoding, module matrix, v2 antipatterns, parse coverage,
runners-invoked, pinned reads, full startup smoke, update-channel and update-check JS contracts,
AHK `--only` groups updat/json/changelog/corpus/release (reds proved pre-existing against the
HEAD json.ahk and core.ahk: LLM live mode, number-row native fixture, managed-network fixture
budget). Lua contract cases pass under Lua 5.4 here; that run's other reds are environment.

Physical check: open "Check for updates" and the Versions fallback window on the real machine and
type during the check; no stall should be felt.

## 2. Last three native menu rows: not started

Census still `windows 3/3` (`menu_hotstrings.ahk` sites at the `MenuRenderer_AppendTemplate`
calls of the default-section submenu, the file submenu and the folder submenu). Design:

1. Give the renderer a template-child row: `MenuRenderer_TemplateChildRow(ManifestKey, ...)`
   creates the child `Menu()`, draws the template into it, and returns the parent row with the
   child plus a repaint handle (the child and the template inputs) that only the renderer can
   redraw (`MenuRenderer_RepaintTemplateChild(Handle, ...)`).
2. `MenuRenderer_PersonalFileParentRow` / `MenuRenderer_PersonalFolderParentRow` take that handle
   instead of a native menu; the default-section caption uses `MenuRenderer_GroupRow` with the
   handle's child.
3. `_MakeSetDefaultSectionFn` and the file/folder repaint commands keep the handle, so a repaint
   acts only on a child the renderer still publishes.
4. Update the word-for-word pins in `tools/test/menu-hotstring-language-binding.cjs` (and its
   source tests) to the new calls, then `node tools/test/test-native-menu-rows.cjs
--update-baseline` to reach 0 and `npm run test:native-menu-rows`.

Risks: the pinned source tests are literal and numerous; captions, order, unavailable reasons and
child commands must stay identical. Physical check needed on the real tray menus afterwards
(captions, greyed reasons, default-section checkmark repaint, state after restart).
