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

- **Done on 2026-10-23** (80c18d9cc2). macOS checked the type of
  `hotstrings.groups`, `hotstrings.modules` and `hotstrings.order_overrides`
  entries, never the name. Boot now publishes a catalogue once every bundled
  hotstring source loaded (`infra/hotstring_choice_catalogue.lua`, called from
  `init.lua`), and `infra/preferences.lua` reports a choice for a category or
  section the build no longer ships, so the cleanup offers it.
- The rule is shared with Linux (`_shared/lua/hotstrings/choice_catalogue.lua`,
  contract `hotstring_choice_catalogue_contract.lua`); Linux
  `choice_is_retired` delegates to it.
- Personal files, `ext:` packs and the dynamic group are never judged. The
  first `Preferences.load` runs before the sources load, so it judges types
  only; the cleanup scan, three seconds after boot, judges names.
- The suspected whole-table `hotstrings.groups = {}` row on an empty inventory
  was already prevented by `reset_keeping_outdated`; a test now pins it.
- **Open:** native macOS qualification of the boot publication.

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

### Explicit `--config FILE.toml` watcher admission

- **Done on 2026-10-23** (3dd420292d), verified under WSL Debian, which ships
  `luv` for LuaJIT (the 16 explicit-file cases and the new ones run there as
  root, so the EACCES case is still skipped).
- Fixed in `linux/infra/file_watchers.lua`:
  - a parent renamed away is reported under the parent's own name and was
    dropped by the anchor filter;
  - an ancestor replaced, a symlink retargeted from another directory, or (mtime
    polling) another file with the same timestamp raised no event: the selected
    path is now resolved again every second and rebound on a changed device and
    inode;
  - a file absent at start is waited for; a symlink is followed to its target;
    an unusable path is refused in the log; refusals repeat at debug level only.
- Cases: `(linux-watch-selected-topology)` in
  `test_file_watchers_single_selected_toml.lua`.
- **Open:** a real luaposix build was not available, so the production
  `posix.stat` flavour of the symlink case is covered through the luv path only.

### Windows full-save comment preservation and table-array boundaries (native qualification)

- **Qualified natively:** 315 of 315 cases pass. They cover the full-save,
  snapshot, TOML writer and table-array cohorts, including
  `full-snapshot-obsolete-parent` (comments, foreign `[[...]]` generations,
  scalar and array namespaces) and `test_toml_table_array_writer`.
- **Closed:** `(full-snapshot-layout-table-array)` in
  `test_config_snapshot_obsolete_parent.ahk` already pins a foreign
  `[[layout."future.rows"]]` generation inside the `[layout]` namespace the full
  save writes; it passes natively, so no writer defect exists.
