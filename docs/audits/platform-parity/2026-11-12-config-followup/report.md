# Configuration: enum case variants and the gesture cleanup

Audited source: `c7e5bd20` (`claude/ergopti-todo-parity-audit`), against the
[configuration campaign](../2026-11-11-config/report.md). Date: November 12, 2026.

## Scope

- **The campaign's open row:** the enum readers other than `[script]` still
  compared values exactly, where Windows' loader
  (`TomlConfigValueMatchesManifest`) admits a case variant of every enum and
  keeps the manifest spelling.
- **Every Lua reader of a manifest enum:**
  - Linux: AI preferences, hotstring preferences, number row, gesture modes;
  - macOS: the preference loader, its manifest child tables, the native
    settings reader;
  - shared: the layout emulation settings and the healthcheck rows.
- **The unused-key cleanup** of the same leaves, which marks what the
  reader takes.

The campaign's fixes, CFD-1 and its refuted list are not repeated.

Checked and kept:

- **Healthcheck rows:** Windows compares a string with
  `StrCompare(Value, Accepted, true)`, which is case-sensitive, as the shared
  `healthcheck/configuration.lua` does. A case variant is reported as text on
  every OS.
- **macOS native settings reader:** `config_overrides.read_native_value` reads
  only `llm.enabled`, a boolean.
- **Setters:** the Linux trigger setter and the macOS prediction setter take
  values from the menu, always in the manifest spelling.

## Fixed

| Id      | OS                                                             | Sequence                                                                                                                              | Windows                                                              | Before                                                                                               | Regression                      |
| ------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------- |
| CFX-001 | Linux (AI, hotstrings, number row, gestures), shared emulation | `agent_mode = "Auto"`, `direct_access_digits = "Symbols"`, `ergopti_variant = "Ergopti_Plus"` or a gesture mode `"X1"` in config.toml | Admitted in the manifest spelling (`TomlConfigValueMatchesManifest`) | Reported outdated, read as the default, offered for deletion                                         | `config-enum-case`              |
| CFX-002 | macOS                                                          | The same, plus `menubar_icon = "V2"` and `virtual_keyboard = "ISO"`                                                                   | Same                                                                 | Same                                                                                                 | `config-enum-case`              |
| CFX-003 | Linux                                                          | Save a swipe mode or step, then run the unused-key cleanup                                                                            | The keys are manifest features, kept (`config_unused_keys.ahk`)      | The cleanup offered every saved `[gestures.modes]` and `[gestures.sensitivities]` entry for deletion | `gesture-slot-settings-cleanup` |

Each reader adopts the spelling through the shared
`config_outdated.canonical_enum_value` before its own rule, so the value it
stores, and every rule after it, sees the manifest spelling, never a looser
comparison. The shared emulation settings take the enum entries from the
generated `features.manifest_data`, so no caller changed. The Linux gesture
marker runs the loader's own admission and marks what the loader takes.

## Preference hydration beyond `load` and `current_view` (November 17, 2026)

Which config.toml rows reach the live owners when the file changes after boot,
on macOS against Windows (which reloads the script) and Linux. Source read at
`c4311153`; no Mac was used, the fix is replayed with Lua 5.4.

| Rows                                                                               | Trigger                                    | macOS                                                                                                     | Windows                                                | Linux                                          | Verdict                                  |
| ---------------------------------------------------------------------------------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ | ---------------------------------------------- | ---------------------------------------- |
| Every row                                                                          | Reload                                     | `hs.reload` replaces the Lua state: `config_overrides.apply`, `Preferences.load`, `sync_state_to_modules` | The script reloads                                     | The daemon restarts                            | Aligned                                  |
| Every row                                                                          | Backup restore                             | Files restored, then `request_reload_owned("config_restore")`                                             | `ConfigBackup_Restore`, then `ReloadPreservingSuspend` | The daemon restarts                            | Aligned                                  |
| config.toml                                                                        | External edit while running                | Ignored (both watchers drop config.toml)                                                                  | No watcher                                             | Any `.toml` change rescans the hotstrings only | Intended; Linux partial (question below) |
| `[layout]` emulation rows (emulated layout, base, variant, AltGr, row switches)    | Global « Restore recommended » / « Clear » | The layout participant reloaded only the number-row layout; the running emulation kept its old session    | Scope commit, then Reload                              | Same as macOS                                  | **Fixed: CFX-004**                       |
| Same rows                                                                          | Keyboard-layout submenu restore            | `layout_emulation.reload_if_started()` after the scope                                                    | Reload                                                 | Reload of the emulation                        | Aligned                                  |
| Number-row order and edges                                                         | Any scope                                  | `number_row_live` through the participant                                                                 | Reload                                                 | Same participant                               | Aligned                                  |
| `llm.*`, `metrics.*`, `mod_combos.*`, `[script]` locale / log level / error dialog | Scope                                      | Each scope's runtime port applies them to the live owner                                                  | Reload                                                 | In-process owners                              | Aligned                                  |
| Menubar icon, pause switch rows                                                    | Scope                                      | Written to state and read from state when used                                                            | Reload                                                 | n/a                                            | Aligned                                  |
| `[script]` row **absent** from a restored or edited file                           | Restore or edit, then reload               | `hs.settings` keeps the old value (not in the backup; only present rows are adopted)                      | The file is the only store                             | Not traced                                     | Question below                           |
| Menu setters (icon, number row, emulation switches, metrics, AI)                   | Menu change                                | Each updates its live owner                                                                               | Live or Reload                                         | Live                                           | Aligned                                  |

The other macOS readers of config.toml are read-before-write guards
(`tap_keys`, `keyboard_shortcuts`, gesture actions, `registry_index`) or owners
re-read by their own transaction (`platform/remap/config.lua`,
`layout_emulation` through `reload`); `settings/engine/overrides.lua` runs at
boot only, which the reload covers.

**CFX-004 (macOS, Linux).** The global restore or clear composes the
keyboard-layout owner directly, so it skipped the emulation reload the
submenu's own restore does: a clear set `ergopti_base` and `emulated_layout`
back in the file while the running emulation kept typing the old layout and
layers until the next reload. The layout participant now reloads a started
emulation once its rows are committed, and again after a revert, whether or not
the number row moved; a refusing or raising emulation is logged and the stored
rows stay committed (`menu/ui/transactions/global_scope.lua`,
`linux/infra/keyboard_layout_scope.lua`; the Linux submenu, which runs the same
participant, no longer reloads a second time). Regression
`layout-scope-emulation-reload`. Windows: no change (Reload).

Questions for the maintainer are in TODO.md (« Maintainer decisions pending »).

## Open

NFD and NFC paths on macOS need a Mac. Native receiving is unqualified.
