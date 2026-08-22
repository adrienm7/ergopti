<!-- docs/memory/rejected_proposals.md -->

# Rejected proposals

These ideas were measured and rejected. Re-open one only when the named code,
constraint, or evidence has materially changed; re-measure before proposing it.

## Generated manifests at runtime

Do not replace checked-in `_generated/` feature manifests with a runtime TOML
read. The 2026-08-03 audit found consumers for every generated artifact; parsing
roughly 130 KB on every driver boot would trade 134 KB of committed output for
startup cost and undo ADR-002. See
[the simplification audit](../audits/2026-08-03-mise-en-commun-et-simplification.md#21-supprimer--_generated).

## Native single-field dialogs as webviews

Do not replace every remaining native single-field dialog with a webview. A
host, bridge contract, and native fallback are more machinery than the small
dialogs they replace. Reconsider only if several dialogs can share an existing
host and measured UX benefit outweighs that lifecycle surface.

## File-size-driven module splitting

Do not split large driver files merely because of their line count. Several of
the largest files are cohesive walkers; arbitrary splits make shared-core work
harder without reducing behavioral complexity. Split around ownership or an
independently testable boundary instead.

## One npm alias per gate

Do not mirror every suite entry in `package.json`. Most direct gate scripts have
no alias, and duplicating the entire runner adds a second registry. Add an alias
only for a command developers invoke directly; the wired-gate ratchet verifies
that every gate still runs.

## One logical `mod` token

Do not collapse `ctrl` and `cmd` into one cross-platform modifier token. The
2026-08-03 measurement found that only 2 of 24 actions share that spelling; the
abstraction would conceal real per-OS behavior rather than remove duplication.

## Moving OS helpers out of adapters

Do not move native Hammerspoon helpers from `adapters/` into `lib/` merely for
folder symmetry. The `hs.*` purity boundary deliberately keeps native calls in
adapters, and the raw-line ratchet enforces it. See
[the refactor guide](../REFACTOR_GUIDE.md#3-ce-que-ce-guide-refuse-de-proposer).

## Porting Windows to the shared Lua matcher

Do not make the Windows driver execute the shared Lua matcher. Windows shares
the behavior contract and cross-driver corpora, not a Lua runtime. The 2026-08-04
measurement found no production Lua in the Windows tree.

## Converting every source test to a behavioral test

Do not mass-convert source-introspection tests. Some protect boot paths and
structural guarantees unreachable by the runtime harness. Replace a meta-test
only when a behavioral test can demonstrably fail for the same root cause.

## General-purpose repository graph index

Do not add a CodeGraph, Graphify, GitNexus, or similar always-on index merely to
reduce agent context. The repository already exposes explicit manifests,
cross-driver contracts, targeted tests, routed memory, and targeted file/text
discovery; current graph products do not cover its AHK, Lua, and JavaScript
surfaces reliably enough to repay their index, MCP, maintenance, and
supply-chain cost. Reconsider only after measuring repeated cross-file discovery
as the dominant token cost and proving incremental, offline support for the
languages actually queried.
