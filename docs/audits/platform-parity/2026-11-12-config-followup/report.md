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

## Open

The campaign's other rows stay open: the macOS preference hydration beyond
`load` and `current_view`, and NFD and NFC paths on macOS, which need a Mac.
Native receiving is unqualified.
