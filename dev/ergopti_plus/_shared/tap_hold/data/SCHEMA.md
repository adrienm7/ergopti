<!-- _shared/tap_hold/data/SCHEMA.md -->

# The shared tap_hold.toml

Every driver keeps its tap-hold keys in one file, `tap_hold.toml`, with one
layout, and the manifest's rows in `config.toml` (maintainer decision of
2026-11-11, `docs/memory/maintainer-decisions.md`). A pair of files copied from
one OS to another works as it did, Cmd versus Ctrl aside.

| Home            | What it holds                                                                                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tap_hold.toml` | `[_meta]`, `[tap_hold]` `inherit_defaults` and the global delay, `[tap_hold.keys.<key id>]`, macOS `[karabiner]`                                                                      |
| `config.toml`   | every `[[features.*]]` row: `[tap_holds]` `enabled`, `lone_modifier_tap_max_ms`, `sticky_timeout_ms`; the whole `[mod_combos]`; `[category_enabled]`; `[shortcuts.key_combination_*]` |

| Driver  | File                                 | Reader and writer                                                                                                    |
| ------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Linux   | `<config>/tap_hold.toml`             | `platform/remap/tap_hold_loader.lua`, `tap_hold_writer.lua`, `infra/tap_hold_scope.lua`                              |
| macOS   | `<config>/hammerspoon/tap_hold.toml` | `platform/remap/config.lua` through `platform/remap/tap_hold_file.lua` and `_shared/tap_hold/engine/shared_file.lua` |
| Windows | `<config>/tap_hold.toml`             | `platform/remap/tap_hold_loader.ahk`, `tap_hold_writer.ahk`, `tap_hold_migration.ahk`                                |

`tap_hold.schema.json` (in `_shared/settings/data/config_schema/`) is the JSON Schema of
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
- A Mac thumb key is written under the PC key at its place (maintainer
  decision TCL-004, « follow the position », `shared_file.toml`
  `[thumb_positions]`): `left_command` is `left_alt`, `right_command` is
  `alt_gr`, `right_option` is `right_ctrl`. Every driver reads an entry still
  under a Mac thumb id as that key, unless the file names the key too.
- An action is named by the id Windows and Linux bind (`enter`,
  `one_shot_shift`, `caps_word`). macOS translates its own spelling (`return`,
  `sticky_shift`, `capsword`) on read and write through the generated action
  catalogue's `tap_hold_spellings`, built from the one-to-one equivalents and
  `[karabiner_aliases]` of `_shared/shortcuts/data/actions/actions.toml`.

## Sections

### `[tap_hold]` (every driver)

| Field                     | Type    | Meaning                                                                                   |
| ------------------------- | ------- | ----------------------------------------------------------------------------------------- |
| `inherit_defaults`        | boolean | Windows and Linux: lay the file over the shipped keys. macOS writes every key it binds.   |
| `time_activation_seconds` | number  | The global delay, in seconds, in `0 < x <= 10`. Absent: `tap_hold.default_activation_ms`. |

`enabled`, `sticky_timeout_ms` and `lone_modifier_tap_max_ms` are `config.toml`
`[tap_holds]` rows (below). A copy left here by a build before config.toml
schema v22 is warned once as outdated and never read.

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

## The config.toml rows

### `[tap_holds]` (config.toml)

| Field                      | Type    | Meaning                                                                                                                            |
| -------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `enabled`                  | boolean | The Tap-Holds switch on macOS and Linux. Absent: the manifest default. Windows keeps its switch as `[category_enabled] tap_holds`. |
| `sticky_timeout_ms`        | integer | How long a one-shot Shift waits for its key, in ms. Absent: `tap_hold.one_shot_shift_timeout_ms`.                                  |
| `lone_modifier_tap_max_ms` | integer | How long a modifier key pressed alone still taps, in ms; `0` is the strict tap-hold.                                               |

### `[mod_combos]` and `[mod_combos.config.<pair id>]` (config.toml)

| Field                        | Type    | Meaning                                                       |
| ---------------------------- | ------- | ------------------------------------------------------------- |
| `enabled`                    | boolean | The key combinations switch. Absent: on.                      |
| `simultaneous_threshold_ms`  | integer | The longest gap between the two keys of a combination, in ms. |
| `symmetric`                  | boolean | `A then B` also fires `B then A`'s combination.               |
| `config.<pair>.combo`        | string  | The action of the combination. Absent or `"none"`: none.      |
| `config.<pair>.tap`, `.hold` | string  | macOS only: the action of the pair's tap and hold slots.      |

Every driver reads and writes this section in `config.toml`, beside the pair
taps and holds (`[shortcuts.key_combination_taps]` and `_holds`) and the
`[category_enabled] key_combinations` switch. A `[mod_combos]` left in
`tap_hold.toml` by a build before schema v22 is warned once and never read.

### `[karabiner]` (macOS only, tap_hold.toml)

`integration_enabled`, `runtime`, `close_other_instances`: « Ergopti uses
Karabiner » and the runtime choice (ADR 011). Windows and Linux never read or
write it.

## Writing

A driver writes only the leaves it owns and changed, and keeps every other
section, key, field and spelling: a file carried between machines keeps the
settings of every driver. A hold chosen on Windows or Linux replaces a macOS
`hold_action`, and a key rebound on any driver loses an `enabled = false`. Two writes replace the whole file: the macOS
« Restore » that clobbers an unparseable file (`save_user_config` with
`overwrite_corrupt`) and the first save over no file at all.

## Old files

The old homes move once:

- macOS `hammerspoon/config_karabiner.toml` (`migrations.toml`
  `[legacy_imports.hs]`): translated by `shared_file.from_karabiner`,
  published as `tap_hold.toml`, then renamed `config_karabiner.toml.migrated`.
  Only while `tap_hold.toml` does not exist; the macOS boot runs it before it
  versions config.toml.
- macOS and Linux `tap_hold.toml` `[tap_hold]` `enabled`, `sticky_timeout_ms`,
  `lone_modifier_tap_max_ms` and `[mod_combos]`: step `v21_to_v22` of
  `_shared/settings/data/config_schema/migrations.toml` (op `import_companion`) copies
  them into config.toml where it holds none, after config.toml's own backup,
  then deletes them from tap_hold.toml line by line after a backup
  `tap_hold.pre-v22-<stamp>.toml` beside it. The config.toml stamp makes it
  run once.
- Windows kept these rows in `config.toml` already: nothing moves.

## Cross-driver corpus

`_shared/tests/corpus/tap_hold_shared_file/` holds, for each driver, the
`tap_hold.toml` its writers write (`<driver>_written.toml`) and the config.toml
rows written beside it (`<driver>_written.config.toml`), and what each driver
must read from every pair (`expected.toml`, `[reads.<name>.<driver>]`). Each
suite pins its own `tap_hold.toml` byte for byte and its own rows as values,
and reads the three pairs with its own readers: Linux
`tests/unit/platform/remap/tap_hold/test_tap_hold_shared_file.lua`, macOS
`tests/unit/platform/remap/config/test_tap_hold_shared_file.lua`, Windows
`tests/unit/platform/remap/tap_hold/test_tap_hold_shared_file.ahk`; the layout
of every pair is pinned by `_shared/tests/lua/keyboard/tap_hold_shared_file_contract.lua`.
