# wrap_symbols (shared data)

## Purpose

Ordered catalogue of wrap-selection symbol pairs (`wrap_symbols.json`) used by the Windows, macOS and Linux drivers to build the "wrap selection" sub-menu and the typed-symbol lookup. Groups (brackets, quotes, angle, CJK, braces, Markdown) carry an `i18n` key that each menu resolves to a named sub-menu; the catalogue is the SSoT so adding a new pair requires only one file edit.

## Key files

| File                | Description                                                                                                       |
| ------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `wrap_symbols.json` | Ordered `groups`, each with an `i18n` label key and a `pairs` array of `{left, right}`; rendered by every menu UI |

## Editing rules

1. Add or reorder entries in `wrap_symbols.json`.
2. For a new group, add its `i18n` key to every locale file in `_shared/core/i18n/data/locales/`.
3. The drivers pick up the change on next reload — no driver-side code edit needed.

## Delimiters and triggers are separate

`left` is also the canonical key of the per-pair enabled state, and `right` may
equal `left` for a symmetric pair. A delimiter may carry spaces so the output
keeps them (the French guillemets are `"« "` and `" »"`), but the key a user
types is the bare glyph, or the glyph with a non-breaking space. Every driver
therefore matches a trigger after normalisation and keeps the catalogue
delimiters for the output; the shared Lua helper is
`_shared/keyboard/engine` (`trigger_keys`, `register`). Two pairs may share a
glyph (the standard curly pair and the lower-quote pair both use `“`); the pair
later in the catalogue wins that typed key, and a disabled pair never takes a key
from an enabled one.
