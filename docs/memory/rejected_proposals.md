<!-- docs/memory/rejected_proposals.md -->

# Rejected proposals

These ideas were measured and rejected. Re-open one only when the named code,
constraint, or evidence has materially changed; re-measure before proposing it.

## Compilation reuse around MLX ownership test groups

Do not extend the registry-property compilation optimization to every MLX
ownership test group by analogy. A baseline/candidate/candidate/baseline trial
preserved all 49 cases but showed small, variable CPU differences and increased
sampled root-process peak working set from 8.7-8.9 MiB to 14.6-14.9 MiB.
Reconsider with a changed workload or evidence of a worthwhile tradeoff. See the
[MLX test compilation experiment](../audits/performance/hammerspoon/2026_09_09/mlx_test_compilation/report.md).

## Grouping metrics SQL rows into JSON only to decode them again

Do not replace the hourly/five-minute manifest row reader with grouped JSON
arrays decoded back into AHK Maps. On the real derived image, three paired
samples increased the two-helper cost from 924–938 ms to 1821–1855 ms despite
equivalent output. Reducing SQLite calls did not repay the extra AHK decoder.
Reconsider only with a pipeline that retains encoded output, or changed evidence.
See the [candidate measurements](../audits/performance/ahk/2026_09_09/candidate_clone/report.md).

## Serializing a readonly SQLite source instead of checking page reads

Do not replace the AHK reader's checked backup with `sqlite3_serialize(source)`.
The vendored implementation can return an allocated image containing zero-filled
pages after native read failures. An exclusive lock on a fixture's last page
made `SQLite_BackupInto` fail while direct serialization returned a nonzero handle.
Normal-output equality and lower copy latency did not detect this data-loss
path. The checked contiguous-buffer variant was separately rejected for growth
regressions below. See the [clone experiment](../audits/performance/ahk/2026_09_09/serialized_clone/report.md).

## File-backed reader clones as a direct latency shortcut

Do not replace the AHK memory-pager clone with ordinary checked backup into a
private file merely to accelerate refresh. Sequential memory/file/file/memory
processes on the 702390272-byte derived image gave six-sample clone medians of
1710 ms and 3503 ms respectively. Process memory fell sharply, but complete
opening and system-wide memory were not measured. Reconsider only with a changed
memory-pressure workload or publication design and fresh end-to-end evidence.
See the [private-file clone experiment](../audits/performance/ahk/2026_09_09/private_file_clone/report.md).

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

## Contiguous SQLite clone buffers for incremental history growth

Do not replace the ordinary memory-pager clone with a deserialized contiguous
buffer, even when checked backup fills it. SQLite 3.50.4 limits each allocation
to 2147483391 bytes; raising the memdb logical size ceiling does not remove this
restriction. Its doubling growth strategy also retained 18995008 native bytes
versus 10181416 for the ordinary pager after a 1 MiB insert into the synthetic
8 MiB fixture. Initial copy savings do not establish safe incremental behavior.
The native growth guard reproduced the regression before restoring the original
runtime. See the [clone investigation](../audits/performance/ahk/2026_09_09/serialized_clone/report.md).

## File-size-driven module splitting

Do not split large driver files merely because of their line count. Several of
the largest files are cohesive walkers; arbitrary splits make shared-core work
harder without reducing behavioral complexity. Split around ownership or an
independently testable boundary instead.

## Skipping individual gate aliases

Do not omit an npm alias when adding a JS gate. The former advice to avoid
mirroring suite entries is obsolete: `test-npm-aliases-match-the-suite.cjs`
requires zero aliasless gates as well as zero aliases pointing at dark gates.
Add the suite entry and its `test:<name>` alias together, then run that parity
guard. Direct script invocation still works; the alias is a discoverability
contract, not a runtime requirement.

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

## Querying every pooled tooltip border before repositioning

Do not add an unconditional GetWindowRect allocation/query to avoid same-position
SetWindowPos calls on borrowed AHK borders. A fixed baseline/candidate/candidate/
baseline experiment lowered the same-position border median but did not show a
consistent complete-preparation gain; both moving-position candidate medians
were slower than both controls. One candidate run failed both unchanged p95
budgets. Desktop variation prevents assigning every stall to the query, but the
evidence does not justify shipping it. Reconsider only with a changed mechanism
and matched moving-position controls. See the
[native border experiment](../audits/performance/ahk/2026_09_08/border_position/report.md).
