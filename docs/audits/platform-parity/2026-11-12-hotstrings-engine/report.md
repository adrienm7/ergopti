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

## Open

- **HSE-002 (macOS and Linux, medium-low):** the shared reader
  `_shared/lua/toml_codec/reader.lua` `parse_entry` takes only a quoted key
  followed by an inline table. Windows `toml_loader.ahk` also loads a bare key
  (`par = { output = … }`) and the simple form `"bbq" = "text"`.
  - **Effect:** such hand-edited extension or personal entries fire on Windows
    only, with no log line on macOS or Linux.
  - **Why not fixed here:** the same reader parses `constants.toml`, the
    tap-hold defaults and the tooltip config, where those shapes are plain
    values. The fix needs a hotstring-only entry path or an explicit refusal.
  - **Windows (report only):** its fixed-order regex drops an entry whose keys
    are in another order, or one with only `output`, which the Lua side loads.
- **HSE-003 (macOS, low, decision):** a trigger with an inner space, such as
  `la notre`, also fires when typed with a no-break space on macOS only
  (`registry.lua` `add_with_space_variants`). Windows and the shared engine
  register no such variant.
- **HSE-004 (macOS vs Windows and Linux, low, decision):** with a letter as
  the magic key (for example `a`), macOS keeps the magic key out of the case
  variants: `BTWa` expands and `BTWA` does not. Windows and Linux conform
  against the uppercased canonical trigger, magic key included, so `BTWA`
  expands and `BTWa` does not.

Native receiving is unqualified.
