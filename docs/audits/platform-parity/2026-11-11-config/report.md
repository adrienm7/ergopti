# Configuration, scopes and migration: Windows, macOS, Linux and shared

Audited source: `a80f7834` (`claude/ergopti-todo-parity-audit`). Date:
November 11, 2026.

The second slice of the adapters and infrastructure census areas: the Lua
drivers' configuration read and write, their scopes and the shared
transactions (`_shared/lua/config_scope_transaction.lua`,
`script_config_authority.lua`, `config_outdated.lua`, `toml_codec`). The
2026-11-04 configuration and folder-migration findings (LCF-, MCF-, WCF-,
LFM-, MFM-, WFM-) are not repeated. Windows (`windows/infra/config_io.ahk`,
`toml/toml_helpers.ahk`, `logger.ahk`) is the read-only reference.
Candidates were replayed with LuaJIT 2.1 and Lua 5.4 against the real
modules in scratch folders; no user configuration was touched.

## Fixed

| Id      | Sequence                                                               | Windows                                                                                      | Before                                                                     | Regression                   |
| ------- | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | ---------------------------- |
| CFS-001 | `[script]` `log_level = "debug"` in config.toml, then start            | Enum admission accepts a case variant and keeps the manifest spelling (`logger.ahk:564-571`) | macOS and Linux ignored the row and offered it for deletion                | `script-config-enum-case`    |
| CFL-002 | Change the log level, locale or error window three times from the menu | No copy per edit (`config_transition.ahk` keeps one bounded transition log)                  | Linux left a full `storage.edit-*.bak` (and `config.toml.edit-*.bak`) each | `script-edit-backups`        |
| CFL-003 | Any setting saved on the LuaJIT runtime under umask 022                | (ACL of the user profile)                                                                    | Linux published `storage.json` 0644 (0600 only under Lua 5.4)              | `linux-storage-private-mode` |

CFS-001 is fixed for the `[script]` rows through the shared
`config_outdated.canonical_enum_value`; the other enum readers (AI and
hotstring preferences on Linux, the macOS preference loader) still compare
exactly, where Windows' loader (`TomlConfigValueMatchesManifest`) admits a
case variant of every enum. Each of them stores the value it admits, so
they need the same canonical spelling, not a looser check.

## Decisions pending (behaviour left unchanged)

- **CFD-1, a staging file left by a crash.** Linux stages every TOML write
  as `<file>.tmp` and `storage.json.tmp`, created exclusively; a stage the
  driver itself left behind at a kill or power cut blocks every later write
  of that file until it is deleted by hand (`toml_codec/writer.lua`,
  `adapters/storage.lua`). Windows names each stage per process and reaps a
  stage whose owner is gone (`toml_helpers.ahk` `_TOML_ReapStaleTemps`).
  Linux deliberately refuses a foreign stage file (memory
  `project-linux-json-store-publication`); recognizing its own needs a
  per-process name or an owner record.

## Refuted

The `paths.toml` rewrite (canonical form on Windows and macOS alike); a
malformed locator; a string `show_error_dialog`; an unknown locale; the
same-directory atomic rename and its absent fsync (recorded intentional
difference); a symlinked `config.toml`; writes to a refused or newer-schema
file; case-twin keys; `scope_owner` double installation; the number-row and
pause preferences; the macOS `hs.settings` namespace migration; quoted Linux
configuration paths.

## Remaining work

The other enum readers' case variants (above); the macOS preference
hydration beyond `load` and `current_view`; NFD and NFC paths on macOS.
Native receiving unqualified.
