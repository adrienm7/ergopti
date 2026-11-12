# Hotstrings engine: drift since the cascade campaign, sending and entry shapes

Audited source: `943cabf4` (`claude/ergopti-todo-parity-audit`), against the
[cascade campaign](../2026-11-11-hotstring-cascade/report.md) (fixes rebased on
`b42d3cb8`). Date: November 12, 2026.

## Scope

- **Drift since `b42d3cb8`:** `macos/modules/keymap/expander.lua` and
  `init.lua`, `linux/modules/hotstrings/injector.lua`, the dynamic-hotstring
  `prefix_rules.lua` and `rules_engine.lua`, and the shared
  `hotstring_engine/init.lua`.
- **Engine parts the cascade campaign did not take:** how an expansion is sent,
  the entry flags and shapes, and case conform.

The cascade campaign's fixes, its decisions HCD-1 to HCD-5 and its observations
are not repeated.

Checked and kept:

- **The drift itself:** apart from the Linux erase pause (HSE-001), it carries
  only the cascade campaign's own fixes (HCL-001, HCM-001 to HCM-008).
- **Entry flags:** the TOML flags (`is_word`, `auto_expand`,
  `is_case_sensitive`, `is_case_sensitive_strict`, `final_result`, `priority`)
  map to the same exact, fold and conform modes on all three OSes.
- **Case conform:** lowercase, Title, UPPER and mixed case give the same result
  on Windows `_HSE_ConformReplacement` and the shared `conform_replacement`.
- **Erase:** the Backspace count is in codepoints on every OS.

## Fixed

| Id      | OS    | Sequence                                       | Windows and macOS                                                           | Before                                                                                                                         | Regression                      |
| ------- | ----- | ---------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------- |
| HSE-001 | Linux | Expand `xgboost` at a TUI prompt in a terminal | A wait of `[debounce] terminal_hotstring_key_delay_ms` after each Backspace | One burst of Backspaces, then one 20 ms pause: the prompt can judge every deletion against one stale render (`xgboostXGBoost`) | `hse-001-terminal-erase-pacing` |

## Decided and fixed after review (2026-11-12)

- **HSE-002:** the shared reader loads the bare-key and simple-form entries in
  a section `[_meta] sections_order` lists, as Windows does. Other sections
  keep their plain values. Regression `hse-002-short-entry-forms`. The Windows
  side (any key order, only `output`) has a TODO line.
- **HSE-003:** the shared engine, so Linux, registers a trigger's no-break and
  narrow no-break space variants, as macOS did. Regression
  `hse-003-nbsp-trigger`. Windows has a TODO line.
- **HSE-004:** macOS follows Windows. A letter magic key follows the word's
  case, so `BTWA` expands and `BTWa` does not. Regression
  `hse-004-magic-key-case`.

Native receiving is unqualified.
