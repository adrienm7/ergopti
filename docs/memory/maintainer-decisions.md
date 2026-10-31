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

## Every owned-runtime row is decided (2026-10-31)

The maintainer accepted every row's proposal of the owned-runtimes inventory.
The rows live in `_shared/data/owned_runtimes.json` (decision
PIN/SYS/OPT/DELETE/NA, status done/follow_up); where a proposal named two ways,
the first is decided and the second kept as `alternative`. WebView2 stays the
Evergreen system runtime (2026-10-27). Edit the JSON, then run
`node tools/codegen/codegen-owned-runtimes.cjs`; never hand-edit the generated
tables of `docs/design/owned-runtimes.md`. Do not re-raise per-row choices.

## One shared config template for the three drivers (2026-10-31, PAR-73)

The default `config.toml` of the three drivers is generated once, in
`_shared/_generated/config_template.toml`: a shared key appears once, a
driver-only key or a default the drivers disagree on is written
`platform.<driver>.<key>`, and each driver's table order is
`[platform.<driver>] sections`. The `{windows,macos,linux}/_generated/config_template.toml`
files stay committed as byte-exact projections
(`tools/lib/config-template-projection.cjs`, proved by
`test-config-template-shared.cjs`) because the .deb/.rpm, the macOS .app and
the AHK smoke test ship or seed them. No driver reads a template at run time:
the effective defaults come from the features manifest. Change them only
through `npm run build:manifest`.

## Shared local-server ports are told apart by response fingerprint (2026-10-31)

vLLM shares 8000 with oMLX and TabbyAPI 5000 with text-generation-webui. Each
row of a shared default address declares `fingerprint { model_field, equals }`
in `_shared/modules/llm/local_servers.json`, matched against the `owned_by` of
`GET /v1/models` (`vllm`, `tabbyAPI`, `omlx`, `user`).
`_shared/lua/llm/local_server_fingerprint.lua` and the shared discovery
controller keep one row per answering address: the fingerprinted row, else the
address's default row (first in `server_order`), which is also kept on 401/403.
A generic entry at a shared address belongs to the default row only. A merged
row per port and order-only affinity were rejected; add a new port collision
as a new fingerprinted row.

## A clone run reads the published layout registry unless the clone changed it (2026-10-31)

A source run (developer mode or any run from a checkout) reads the published
layout registry like a release, from its channel's branch with the same cache
and ETag, unless `git status --porcelain --untracked-files=all` lists changes
under the clone's `static/layouts/registry` (index.json and the layout files
count, untracked included); then it shows the clone's folder without HTTP. A
git failure shows the clone's folder and logs an ERROR: the clone is the code
being run, and the published registry would hide a local edit. The decision is
shared (`Catalogue.registry_source` and `registry_changes_args` in
`_shared/lua/layouts/catalogue.lua`); the Windows port is in the PC handoff.
