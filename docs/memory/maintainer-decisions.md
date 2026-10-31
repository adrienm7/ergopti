<!-- docs/memory/maintainer-decisions.md -->

# Maintainer decisions

Settled product and engineering choices. Do not raise them again unless the
named constraint changes; a change of mind comes from the maintainer.

## French sticky modifiers are « rémanents » (2026-10-31)

The French sticky-modifier labels say « rémanent »: `📌 Maj rémanente`,
`📌 Ctrl rémanent`, `📌 Option rémanente`, a chord `📌 Cmd+Shift rémanents`, and
the delay strings say « modificateur rémanent ». Other Latin-script locales keep
their own wording. The French rows of
`_shared/tests/corpus/menus/script_action_original_catalogue_projection.json`
pin the labels.

## Dutch rolls are "Rolbewegingen" (2026-10-31)

Dutch names the rolls category "Rolbewegingen" (`category.rolls`,
`hs_config.cat_rolls`, and the `nl` description of the registry's
`ergopti/hotstrings/rolls.toml`): "Rollen" means "roles". The locale
completeness gate fails if Dutch falls back to the English "Rolls", which is no
longer allowlisted.

## The local servers "none" row is one sentence (2026-10-31)

When a finished sweep found no local AI server, the menu row says
`menu.llm.local_servers.none_detected` (« Aucun serveur local détecté ») and
lists no server; the names stay in the local servers panel and the "other
address" submenu. The row of a running sweep (`searching`) keeps the list. The
shared `_shared/lua/llm/local_server_menu.lua` owns the rule; the Windows twin
follows through the PC handoff.

## config.toml `[script]` wins at start on macOS and Linux, without migration (2026-10-31)

A `config.toml` `[script]` row (`locale`, `log_level`, `show_error_dialog`) wins
over the native store (hs.settings, storage.json) at start, as on Windows:
`_shared/lua/script_config_authority.lua` writes it into the native alias
(`infra/script_scope.lua` `adopt_configured`) before the error window, the log
level and i18n read it, and every menu or wizard change rewrites the row first
when the file holds one (`rewrite_configured`). There is no migration or
adoption marker (sole user, clean state): a file without the row leaves the
native value in force, and nothing is copied between the stores. Only a
shipped locale code is adopted.

## Decisions without code of 2026-10-31

- **Published release notes** that carry agent session lines are rewritten
  once by the coordinator; `build_changelog.py` already strips them from new
  notes.
- **The `WH_KEYBOARD_LL` probe** (`windows/.../input_probe.ahk`) stays in the
  release exe, flagged or not by a corporate proxy.
- **Windows builds the timer-delay ceiling and key-chord policies** that macOS
  and Linux replay (`_shared/tests/corpus/timer/delay_ceiling_vectors.json`,
  `_shared/tests/corpus/tap_hold/key_combination_chords.json`); the work is in
  the PC handoff.
- **`dev` history is kept as it is**: the October 22 commits whose message
  belongs to another change are not rewritten.
- **Item 109 (branded debug GUI) and a real `Comments` field in the exe's
  version resource** go to the PC agent (handoff).
- **L115 is closed**: the provider error envelope guard did not reproduce
  under WSL LuaJIT (6 of 6 runs pass); reopen only on a new failing run.
