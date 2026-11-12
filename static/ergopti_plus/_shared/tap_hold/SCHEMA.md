<!-- _shared/tap_hold/SCHEMA.md -->

# The shared tap_hold.toml

Every driver keeps its tap-hold settings in one file, `tap_hold.toml`, with one
layout (maintainer decision of 2026-11-10, `docs/memory/maintainer-decisions.md`).
A file copied from one OS to another works as it did, Cmd versus Ctrl aside.
`config.toml` keeps the `[[features.*]]` rows of the manifest; the tap-hold
keys, delays and key combinations live here.

| Driver  | File                                 | Reader and writer                                                                                                 |
| ------- | ------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| Linux   | `<config>/tap_hold.toml`             | `platform/remap/tap_hold_loader.lua`, `tap_hold_writer.lua`, `infra/tap_hold_scope.lua`                           |
| macOS   | `<config>/hammerspoon/tap_hold.toml` | `platform/remap/config.lua` through `platform/remap/tap_hold_file.lua` and `_shared/lua/tap_hold/shared_file.lua` |
| Windows | `<config>/tap_hold.toml`             | `platform/remap/tap_hold_loader.ahk`, `tap_hold_writer.ahk`, `tap_hold_migration.ahk`                             |

`tap_hold.schema.json` (in `_shared/core/config_schema/`) is the JSON Schema of
the file; `shared_file.toml` beside this page is the part of this
specification a reader needs as data.

## Version

`[_meta] schema_version` is the version of the file, migrated by the ordered
steps of `migrations.toml` (current version 1). A file without the stamp is
version 0. A driver that writes the file writes the stamp; a driver never
writes a file stamped newer than it knows, or one whose stamp is not a
non-negative integer, and reads such a file as it is.

## Ids

- A key is named by its catalogue id, `[tap_hold.catalog]` `id` in
  `defaults.toml`: `caps_lock`, `left_ctrl`, `left_option`, `space`, `enter`,
  `backspace`. Never by a driver's own spelling (`left_control`, `spacebar`,
  `return_or_enter`).
- A key combination is `<first>_then_<second>` over the same ids, the first key
  pressed first: `escape_then_tab`.
- A driver that has no such key or combination leaves the entry untouched.

## Sections

### `[tap_hold]` (every driver)

| Field                      | Type    | Meaning                                                                                           |
| -------------------------- | ------- | ------------------------------------------------------------------------------------------------- |
| `enabled`                  | boolean | The Tap-Holds switch. Absent: the manifest default.                                               |
| `inherit_defaults`         | boolean | Windows and Linux: lay the file over the shipped keys. macOS writes every key it binds.           |
| `time_activation_seconds`  | number  | The global delay, in seconds, in `0 < x <= 10`. Absent: `tap_hold.default_activation_ms`.         |
| `sticky_timeout_ms`        | integer | How long a one-shot Shift waits for its key, in ms. Absent: `tap_hold.one_shot_shift_timeout_ms`. |
| `lone_modifier_tap_max_ms` | integer | How long a modifier key pressed alone still taps, in ms; `0` is the strict tap-hold.              |

### `[tap_hold.keys.<key id>]` (every driver)

| Field                     | Type    | Meaning                                                                                                                     |
| ------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------- |
| `tap_action`              | string  | The action of a tap. `""` or absent: the key itself. `"none"` on Windows and Linux: nothing.                                |
| `hold_modifier`           | string  | The modifiers a hold holds, `+`-joined in the order of `shared_file.toml` `[modifiers] order`: `ctrl+shift`. `""`: no hold. |
| `hold_layer`              | string  | The layer a hold enters, one of `[tap_hold.hold_picker] layers`: `nav`.                                                     |
| `hold_action`             | string  | macOS only: a hold that is neither a modifier nor a layer, a macOS action id.                                               |
| `time_activation_seconds` | number  | The key's own delay, in seconds. Absent: the global delay.                                                                  |
| `enabled`                 | boolean | `false` switches the key off on every driver; a driver that rebinds the key removes it.                                     |

A hold is one of `hold_modifier`, `hold_layer`, `hold_action`; writing one
removes the other two. `cmd` and `fn` are macOS modifiers: Windows and Linux
warn once and hold nothing on a key that holds them, and keep its tap.
`alt_gr` is written for the macOS AltGr hold (`altgr`).

### `[mod_combos]` and `[mod_combos.config.<pair id>]` (every driver)

| Field                        | Type    | Meaning                                                       |
| ---------------------------- | ------- | ------------------------------------------------------------- |
| `enabled`                    | boolean | The key combinations switch. Absent: on.                      |
| `simultaneous_threshold_ms`  | integer | The longest gap between the two keys of a combination, in ms. |
| `symmetric`                  | boolean | `A then B` also fires `B then A`'s combination.               |
| `config.<pair>.combo`        | string  | The action of the combination. Absent or `"none"`: none.      |
| `config.<pair>.tap`, `.hold` | string  | macOS only: the action of the pair's tap and hold slots.      |

macOS and Linux read and write this section here. On Linux,
`modules/shortcuts/key_combinations.lua` reads it, and the Shortcuts and key
combinations scopes publish it through the tap-hold writer
(`prepare_combo_rows`) as the second backed-up file of their transaction;
`config.toml` keeps the pair taps and holds and the
`[category_enabled] key_combinations` switch. A `[mod_combos]` left in
`config.toml` is never read.

### `[karabiner]` (macOS only)

`integration_enabled`, `runtime`, `close_other_instances`: « Ergopti uses
Karabiner » and the runtime choice (ADR 011). Windows and Linux never read or
write it.

## Writing

A driver writes only the leaves it owns and changed, and keeps every other
section, key, field and spelling: a file carried between machines keeps the
settings of every driver. Two writes replace the whole file: the macOS
« Restore » that clobbers an unparseable file (`save_user_config` with
`overwrite_corrupt`) and the first save over no file at all.

## Old files

Each driver carries its old files over once, as `migrations.toml`
`[legacy_imports]` declares:

- macOS `hammerspoon/config_karabiner.toml`: translated by
  `shared_file.from_karabiner`, published as `tap_hold.toml`, then renamed
  `config_karabiner.toml.migrated`. Only while `tap_hold.toml` does not exist.
- Linux `config.toml` `[mod_combos]`: moved as it is into `tap_hold.toml` at
  boot (`tap_hold_writer.import_config_combos`, translation `config_section`),
  then deleted from `config.toml` line by line. Both files are backed up first
  and `tap_hold.toml` is published first; when it already holds a different
  `[mod_combos]`, it wins and `config.toml` is left as it is.
- Windows `config.toml` tap-hold keys: the Windows driver's own migration.

## Cross-driver corpus

`_shared/tests/corpus/tap_hold_shared_file/` holds a file written by each Lua
driver's writer and what each driver must read from it. Each driver suite
replays its own writer against its file byte for byte and reads both files
through its own reader (`_shared/lua/test/tap_hold_shared_file_contract.lua`).
The Windows suite reads the same files.
