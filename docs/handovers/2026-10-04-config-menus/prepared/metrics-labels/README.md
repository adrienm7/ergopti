# Fixed Metrics migration-status labels

This 14-path candidate is unapplied. The actual checkout was not edited; no
network, Git mutation, full JS/native suite, CI or release action was performed.

Prerequisite: the frozen Tap-Hold complete-head candidate and its shared
`template_rows` / `MenuRenderer_TemplateRows` APIs. Its patch SHA256 is
`98020999760ad87aaff015e82871635f0aac85a78ef99c894072801c6e71f93b`.
The current patch is incremental against that exact candidate source, based on
905b plus the previous staged native-command overlay. Its complete preimages
and SHA256 hashes are saved in this packet. The root must adapt later source
changes and regenerate artifacts rather than overwrite them.

`metrics-migration-labels.patch` SHA256:
`a9a2ba6ba7b94c8ddb8b17347cda22d3bd3c4e0a68426ecb075e4f6dc559af4d`.
It passes `git apply --check` against its saved preimages.

## Bounded production behavior

The two existing Linux unavailable/idle migration readouts are shared inert
`label` declarations. The explicit label primitive returns only a translated
caption and `disabled = true`; it cannot carry an action, check or child menu.
Both the shared Lua owner (Mac/Linux) and the native Windows port implement
that same template capability. Behavior/private metadata, missing identity and
missing caption are refused by the generator and readers. The declarations are
Linux-only with `unavailable = "hide"`; no new translations or configuration
schema/defaults are introduced. This capability is for provider templates,
not an extension to ordinary full-menu building.

Linux retains exactly its method-availability and idle-state branches. Only
those two returned row declarations move into shared data. The complete running
caption (%d/%d) and cancellation closure remain byte-exact with the prerequisite:
see `unchanged-running-source-sha256.txt`. Existing cancellation receipts are
not reinterpreted. App-exclusion counts, parent captions and other computed
Metrics rows remain separate work; TODO54/81 stay partial.

The exact complete prior byte prefixes of all three registered native owner
test files are retained. Every previous shared corpus is byte-identical. New
expectations are handwritten in `migration_status_menu.json`; formatting did
not change any of its decoded values. Canonical Prettier formatting also
normalizes inherited/new generator and guard layout, preserving assertions.

## Focused evidence

- Linux actual owning module: 40 passed, 0 failed. Its original 23 cases remain;
  17 appended cases cover actual unavailable/idle rows, caption/platform
  mutations, unchanged running progress/cancellation false/nil/truthy behavior,
  all 21 locales and all three platform projections, inert callback/child
  injection refusal, and seven malformed-reader vectors.
- Mac actual shared renderer module: 18 passed, 0 failed. Original 17 cases
  remain; the appended case proves the statuses stay hidden, then explicitly
  projects each synthetic applicable label through the actual Mac renderer and
  proves supplied callback/child payload cannot attach effects. The existing
  owning module emits cold-start Karabiner bridge warnings in this Linux
  environment; these are not physical capture or deployment validation.
- Windows: two appended registered cases cover platform hiding, actual native
  provider data, real Win32 drawing/disabled state, callback inertness and bad
  reader metadata. These cases are NOT EXECUTED: no native Windows runtime or
  runner was used.
- Manifest/choice guard passed, including eight new actual compiler refusal
  vectors. The compiler cannot publish after an invalid label. Wrong provider
  and wrong status-section wiring mutations are rejected. Parity passed:
  48 menus, 228 label keys in 21 locales, zero unreasoned hidden rows. Existing
  handler bijection is unchanged and passes with zero unresolved behaviors on
  all three drivers; no ID allowlist exception was added for labels.
- AHK encoding: 1814 BOM/LF files; syntax antipatterns: 1802 production files;
  registration: all 1376 native test files reachable. Strict conventions and
  targeted canonical format checks passed.
- Owner generators succeeded and final repeated generation was byte-identical.

`census-proof.json` records 95/152/96 -> 95/152/94, with old Linux provider source
restoring 95/152/96. `census-source-retirement-proof.json` compares every counted
source signature, independently of line shifts: precisely the unavailable and
idle Linux caption lines retire, no new sites appear, and every Windows/Mac
signature is identical. No scanner or baseline rule is altered.

Causal inverses retained with the full expected assertions:

- Restoring only the original Linux provider gives 36 passed / 4 failed, and
  the actual JS provider wiring assertion fails.
- Restoring only the original shared renderer gives Linux 35 passed / 5 failed
  and Mac 17 passed / 1 failed: its missing label capability is exposed.
- Restoring only the original compiler fails the new real malformed-label
  refusal vectors (an invalid source is incorrectly accepted).

All receipts are `final-*.log` and `inverse-*.log`. Passing, failing and unrun
checks above are separate; no cases were ignored to obtain these results.

Full verify-change selection/execution, full JS/Lua/AHK, E2E, packaging,
installation, native three-OS CI and physical input acceptance remain with the
root's serialized qualification workflow. This patch does not finish Metrics
migration, TODO54/81 or the group and claims no integrated commit or release.
