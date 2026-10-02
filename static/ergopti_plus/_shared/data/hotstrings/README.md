<!-- _shared/data/hotstrings/README.md -->

# Common autocorrection classification

`common_autocorrection_sections.json` is an editorial inventory for a future
split of the common autocorrection section. It does not route runtime entries,
declare menu labels or change configuration keys. The 140 mappings still belong
to the existing `autocorrection.caps` section.

The inventory assigns each trigger exactly once: 34 names, 95 abbreviations and
11 technical terms. Abbreviations include mixed-case plurals and service models
such as `BDDs` and `CaaS`. Names retain their published spelling, including the
accent in `Vendôme`; the classification does not normalize replacements.

The independent reference is
`_shared/tests/corpus/hotstrings/common_autocorrection_entries.json`. It was
captured once from the unchanged legacy source before any split. Its source
commit and digest record that capture. It preserves all 140 triggers, outputs,
flags, original ordinals, metadata, section identity and the common priority
tier. It is not a generated artifact: never refresh its expectations from a
reclassified source. A deliberate change to a rule requires an explicit review
of the affected reference entry.

A selectable runtime split remains separate work. Activation and feature delay
preferences live in `config.toml`; delay, color, tooltip and priority overrides
live in the file selected by each driver's path owner:
`hotstrings_config.toml` on Windows and `hotstrings_overrides.toml` on Linux.
The macOS path owner selects its native override file. Both files need their existing
transactional owners and a migration that copies each legacy choice into every
replacement section while preserving an explicit new choice. The current
configuration migration operations cannot fan out a stored value. Merely
deleting `caps`, or retaining it as a runtime fallback, is not a migration.

The readers currently register one section at a time. The original alphabetical
source interleaves all three proposed sections, so grouping them changes global
registration order. Preserve the captured ordinals through the registration
owner before switching sections, and test collisions with personal and package
sources as well as per-section enable and disable. Menu and section labels must
then be supplied in all 21 locales; the separate French autocorrection pack
keeps its own category and rules.
