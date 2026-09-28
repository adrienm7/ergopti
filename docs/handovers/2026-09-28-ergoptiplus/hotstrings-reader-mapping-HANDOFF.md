# Hotstrings scope: current macOS readers

Read-only inventory of the current root source; no aliases or migration proposal.
`hotstrings-exact-reader-map.tsv` lists all 115 operations emitted by
`Manifest.scope_plan("hotstrings", "clear", {}, {})`. Its sibling Lua script
derives the list from the generated manifest and parses the actual bundled TOML
corpus. Treat a row's `canonical_candidate` as an integration target only when its
status proves an owner; missing inventory and missing native readers are explicit.

## Classification

| Count | Existing owner |
| --- | --- |
| 8 | Exact Preferences scalar reader and runtime state |
| 1 | Dormant dynamic master scalar; actual runtime uses the registered group |
| 57 | Actual registered section leaf, including six programmatic dynamic sections |
| 33 | Delay resolver in a separate file; engine section override hookup is incomplete |
| 4 | Manifest section absent from the bundled registered corpus |
| 1 | Personal-info scalar with a real runtime owner |
| 1 | Personal-info pattern limit with no macOS native reader |
| 10 | Personal sections whose ownership depends on the actual user catalogue |

## Groups and sections

The persisted source consumed by Preferences is `hotstrings.groups.<group>` and
`hotstrings.modules.<group>.<section>` (`infra/preferences.lua:158`). The snapshot
writer enumerates the real `keymap.get_sections` result and skips placeholders
(`infra/preferences.lua:855`). RegistryGroups only registers parsed corpus
sections in declared order (`modules/keymap/registry_groups.lua:385`).

The current corpus-derived category mapping is:

| Conceptual manifest category | Actual group |
| --- | --- |
| autocorrection | autocorrection |
| distances_reduction | distancesreduction |
| sfbs_reduction | sfbsreduction |
| rolls | rolls |
| magic_key | magickey |
| french_distancesreduction | french_distancesreduction |
| french_autocorrection | french_autocorrection |
| french_magickey | french_magickey |
| personal | personal, only when the real descriptor exists |

This is an inventory description, not a proposed runtime alias map. The shared
`hotstrings.languages.section_default` already normalizes category spellings for
default lookup; a future source declaration must retain a single persisted form.
Do not infer ownership just from a matching prefix or manifest id.

Four static ids have no corresponding current corpus section: `distances_reduction.space_around_symbols`,
`rolls.chevron_equal`, `rolls.hashtag_quote`, and `magic_key.replace`. No Mac scope
should write these as if runtime could consume them. Preserve other drivers'
ownership until inspected there.

Extra personal groups are `personal_ext_<stem>` with nested path components
joined by `__` (`infra/personal_hotstrings.lua:136`). Ordinary layout extension
groups retain their exact registered `ext:<pack>:<stem>` identity. Inventory must
come from `list_groups/get_sections`, not directory-name guesses.

## Dynamic hotstrings

The actual runtime checks group `dynamichotstrings` and the section guard
(`modules/dynamic_hotstrings/rules_engine.lua:220`, `:227`, `:567`):

| Conceptual feature | Consumed persisted leaf |
| --- | --- |
| dynamic.enabled | hotstrings.groups.dynamichotstrings |
| dynamic.date.enabled | hotstrings.modules.dynamichotstrings.date |
| dynamic.date_fr.enabled | hotstrings.modules.dynamichotstrings.datefr |
| dynamic.date_long_fr.enabled | hotstrings.modules.dynamichotstrings.datelongfr |
| dynamic.iban_prefixes.enabled | hotstrings.modules.dynamichotstrings.ibanprefixes |
| dynamic.phone_prefixes.enabled | hotstrings.modules.dynamichotstrings.phoneprefixes |
| dynamic.ssn_prefixes.enabled | hotstrings.modules.dynamichotstrings.ssnprefixes |
| dynamic.text_expansion_personal_information.enabled | hotstrings.modules.personal_info |

Preferences also contains older scalar mappings `hotstrings.dynamic.datefr`,
`date`, `datelongfr`, `ibanprefixes`, `phoneprefixes`, `ssnprefixes`, and `enabled`.
Their flat `dynamichotstrings_*` state fields have no live runtime consumer beyond
default construction/serialization. They must not become a second accepted
format. Remove them from reader/writer/default state in the same integration
that replaces their manifest declarations, so cleanup can report old keys.

Personal-info is a module placeholder, deliberately excluded from section cache
projection. `MenuState` applies `state.personal_info` through dynamic module
enable/disable (`ui/menu/menu_state.lua:665`), which forwards to PersonalInfo.
Those native setters currently return nil and lack an enabled query; add exact
commit/readback before using them in the terminal scope. Do not modify personal
information data. `pattern_max_length` has no non-generated macOS reader.

## Timings

Do not translate `*.time_activation_seconds` into another `config.toml` leaf and
claim success: Preferences has no such reader. The existing resolver stores
seconds in the shared `hotstrings_config.toml`, `[<group>.<section>].delay`, with
category `[<group>].delay` as the next rung. Its owner is
`modules/hotstrings/hotstrings_config.lua`: `resolve` at 631, `set_override` at
742, `clear_override` at 799, `get_user_override` at 938. This is a separate
source/baseline/publication owner and needs an explicit cohort if included.

The native activation gate `State.resolve_mapping_delay` reads `DELAYS` and
`SECTION_DELAYS` (`modules/keymap/state.lua:186`). RegistryGroups populates the
latter from corpus `[_meta.section_delays]` only (`registry_groups.lua:483`).
MenuState resolves category delays through HotstringsConfig (`menu_state.lua:289`),
but per-section user delay overrides are not projected by RegistryGroups there.
Therefore the 33 timing rows need a real reader hookup or a declared narrower
scope; merely deleting the file overrides would not establish the full runtime
postcondition. The TSV marks this as a limitation, not a working mapping.

The existing category delay state `hotstrings.delays.<key>` maps
`STAR_TRIGGER -> magickey`, and `autocorrection`, `rolls`, `sfbsreduction`,
`distancesreduction` to themselves (`modules/keymap/init.lua:73`). It currently
has precedence over resolved category overrides in MenuState. Avoid introducing
a third representation; choose one source and remove the unused reader/writer
surface together. Shared Windows/Linux behavior must be verified separately.

## Integration recommendation

1. Apply the delivered six-path canonical-cache packet: it is already consumed
   before capture and in MenuState and preserves unknown inline neighbors.
2. Declare only actual reader-owned Mac group/section paths in the shared planner;
   keep Windows/Linux mappings unchanged until their owner evidence is collected.
   Recommended values must come from the corresponding feature declaration, not
   blindly from generic dynamic `recommended=true` (personal/consent cases differ).
3. Complete exact scalar runtime/readback and the separate timing owner before
   publishing the terminal Hotstrings menu action. Compose through the existing
   PreferencesScope/ScopedPreferences transaction, retaining inverse debt.

No root or export source files were modified during this inventory.
