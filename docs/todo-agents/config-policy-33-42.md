<!-- docs/todo-agents/config-policy-33-42.md -->

# Handoff: TODO items 33 and 42 (config-menus)

State on 2026-10-21. All commits are local on dev and have not been pushed.
Windows checks ran natively with AutoHotkey 2.0.26. The macOS and Linux Lua
checks ran on Lua 5.4 on Windows, with the luv.hrtime shim and no native
filesystem staging.

## 33. Config policy for files other than config.toml

### Windows keyboard binding publication from its real input owner

- **Reproduced:** yes. The loader and the cleanup judged keyboard slots by a
  lowercase four-group grammar, while the input owner bound any slot whose
  prefix resolved. As a result:
  - `ctrl_f1` and `CTRL_K` became live hotkeys, and `win_SC0FF` threw at boot.
  - A live `win_SC03A` slot was offered for deletion.
  - `keyboard__*` parameters were never judged.
- **Commit:** ef238c2758. It adds `KeyboardSlotDeclaration` and
  `KeyboardSlotIsCatalogued`, and `KeyboardSlotCatalogueIds` publishes the
  domain to the shared keyboard identity rule. The test slug is
  `(keyboard-slot-publication)`, and it was red on HEAD.
- **Remaining:**
  - A parameter of a physical slot (`keyboard__win_SC03A__x`) still fails the
    lowercase grammar of `TomlConfigActionParameterIsOwned`, so the cleanup
    offers it.
  - The 600 expanded chord ids (`ctrl_alt_k`, ...) are actions, not slots. No
    picker group offers them, so they stay outside the slot domain.
  - The updater source seal pins `config_io.ahk`. Reseal from ef238c2758 with
    `node tools/ci/seal-windows-updater-original-source.cjs --ref ef238c2758 --write`.

### macOS Hotstrings category/section/order authority

- **Not implemented.** Confirmed by reading only. macOS checks the type of
  `hotstrings.groups`, `hotstrings.modules` and `hotstrings.order_overrides`
  entries, never the name, so an entry for a removed category is marked read
  and never offered. That is the safe "no catalogue" policy, not data loss.
- **Next steps:**
  - Publish a catalogue from `modules/keymap/registry_index.lua` once a
    complete load has finished.
  - Judge only bundled ids. Leave `ext:*`, `personal-file:*` and dynamic ids
    unjudged.
  - Consume it in `infra/preferences.lua` (`boolean_choice`,
    `partition_section_choices`, `section_order_fits`), using the same pattern
    as `delay_fits`.
  - Mirror Linux `choice_is_retired` and `sections_are_the_builds`, ideally
    through a new shared `_shared/lua` owner.
- **Unconfirmed risk:** a save with an empty hotstring inventory may emit a
  whole-table `hotstrings.groups = {}` row (`sparse_updates`). A fixture with
  write stubs should test that first.

### Linux retired API-provider reader (with ai)

- **Not a defect any more.** 49ec6ee20c fixed it on 2026-10-05, and the TODO
  line is stale.
- `test_api_entries_retired_provider.lua` read cases pass here. Its write cases
  need native `luv.fs_open`, which the shim lacks.
- **Parity gap (open):** Windows `_LLM_Menu_ParseAndValidateApiEntries`
  rejects the whole `api_entries.json` when one entry names an unknown
  provider. That contradicts the rule that an outdated entry is warned and the
  rest of the file kept. Fix it per row.

### macOS Karabiner obsolete-leaf intent

- **Reproduced:** yes. Every menu setter of an obsolete leaf was refused
  forever, and an explicit default timing was a silent no-op.
- **Commit:** 54a537b724. `save_user_config` now takes a validated leaf intent,
  and each setter names its own leaf. The test slug is `(remap-leaf-intent)`.
- **Remaining:** native macOS qualification, meaning real
  `write_if_unchanged` staging.

### Windows retired dotted/inline/table-array cleanup projections

- **Reproduced:** yes.
  - Root dotted and inline unknown leaves, and inline feature children, were
    never offered.
  - A section-relative dotted leaf was offered under a literal name, and its
    deletion reported "removed" without changing the file.
- **Commit:** 300790cb37. The cleanup now classifies the loader's semantic
  rows, and a row with no source value is "changed". The test slug is
  `(config-unused-keys-semantic-shapes)`.
- **Remaining:**
  - Bare root keys (`foo = 1` at the root) are warned by boot but not offered,
    because the removal cannot address section "".
  - Unknown `[[x]]` table-array generations are only counted by boot ("skipped
    sections"), so they are not offered either.

## 42. config.toml batch writer follow-ups

### Ancestor admission and external symlink-target replacement (`--config FILE.toml`)

- **Not reproducible here.** The 16 explicit-file watcher tests skip without
  native luv, and the host can create no symlinks.
- **Code reading** (`linux/infra/file_watchers.lua`) shows four gaps:
  - A parent or ancestor renamed away is never seen on the inotify backend
    (the anchor filter at :576 drops IN_MOVE_SELF).
  - The polling backend ignores dev/ino.
  - A symlinked `--config` is refused with luaposix present (lstat), with no
    log.
  - A file absent at start is never retried.
- **Needs** a Linux host or CI: add the T1-T7 cases (proposal in this
  session's report) to `test_file_watchers_single_selected_toml.lua`.

### Windows full-save comment preservation and table-array boundaries (native qualification)

- **Qualified natively:** 315 of 315 cases pass. They cover the full-save,
  snapshot, TOML writer and table-array cohorts, including
  `full-snapshot-obsolete-parent` (comments, foreign `[[...]]` generations,
  scalar and array namespaces) and `test_toml_table_array_writer`.
- **Gap:** no case has a table array under a namespace the full save writes
  (for example `[[layout."x"]]` after `[layout]`).
