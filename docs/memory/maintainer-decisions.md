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
