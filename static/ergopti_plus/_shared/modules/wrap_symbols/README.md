# wrap_symbols (shared data)

## Purpose

Ordered catalogue of wrap-selection symbol pairs (`wrap_symbols.json`) used by both drivers to build the "wrap selection" sub-menu. Groups (brackets, quotes, custom) with i18n key references are rendered identically on both platforms; the catalogue is the SSoT so adding a new pair requires only one file edit.

## Key files

| File                | Description                                                                      |
| ------------------- | -------------------------------------------------------------------------------- |
| `wrap_symbols.json` | Ordered groups of `{open, close, label_key}` triples; rendered by both menu UIs  |

## Editing rules

1. Add or reorder entries in `wrap_symbols.json`.
2. Add the `label_key` string to every locale file in `_shared/data/locales/`.
3. Both drivers pick up the change on next reload — no driver-side code edit needed.
