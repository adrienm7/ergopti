# Shared Lua installed-record preservation candidate

Base: ef278416ee26c74c1ffd88b3ec86416b2b7036e4. The immutable Windows
semantic snapshot and Windows installed-record v3 packets are separate.
This packet modifies only the three shared/Mac/Linux installed-record owners,
four append-only registered test modules, two new shared test contracts, one
independently handwritten corpus and the TODO33 block. It was built from a
Git archive, not a Git worktree; no branch, checkout edit, commit, network
operation, generator or full/drift suite was performed.

The candidate patch hash and all exact eleven path identities are in
patch-manifest.json. Eight existing paths have complete saved preimages.
freeze.py verifies their hashes, every original test module as an exact
prefix, only the TODO33 block changed, BOM-independent LF text, protected
Windows JSON/catalogue and shared generic codec/corpus/remap owners unchanged,
a sparse source-only git apply --check, and byte-exact application postimages.
The TODO note must be composed with root's newer notes. No obsolete item or
assertion was removed.

## Root cause and bounded change

The unchanged dev689d/pushed ef278416 writable_copy started an empty record
and carried only obsolete layout rows, deleting unknown root members on
any successful install/remove. Both production registries decoded the
installed file with the generic lossy JSON decoder; null and an empty
array inside an ignored row became object tables and were serialized as {}.
The baseline diagnostic in the sibling TODO33 audit evidence directory
measured seven violated policy expectations and five passing controls on
LuaJIT and Lua 5.4; a lossless decode alone still erased root members.

Only installed-record consumption now uses the existing lossless JSON
owner, with a dedicated optional decoder port. Index/default/generic
decoders and the shared codec bytes are unchanged. Tagged arrays and null
cannot be admitted as the owned root, layouts object, or a usable layout
entry. Syntax/header/schema refusals remain strict.

A private weak-key source identity retains detached original root members
and ignored rows. An actual source root named outdated is preserved separately
from public runtime classification; neither the runtime registry nor mutated
runtime/candidate copies can become original source proof. Builders propagate
that identity, clone publication values including tagged array/null values,
and preserve ignored rows on a later builder. Verified same-id installation
explicitly replaces an ignored row; a later remove does not resurrect it.
Valid untouched layout rows retain their models. Ordinary saves preserve
JSON models, not whitespace, escape spelling, number tokens or comments.

Fresh/programmatic records retain the existing public obsolete-registry
fallback. Source identity across arbitrary
foreign table cloning, newly introduced opaque programmatic values, and
unknown fields inside a changed owned extension container are not newly
qualified. Unknown-root warning completeness is also outside this bounded
retention slice. TODO33 remains partial.

## Exact focused verification

The same four registered modules run against exact original three source
owners and the corrected owners. Every old assertion is retained.

| Module/runtime           | Original owner       | Candidate owner     |
| ------------------------ | -------------------- | ------------------- |
| Mac catalogue / Lua 5.4  | 15 passed, 8 failed  | 23 passed, 0 failed |
| Mac manager / Lua 5.4    | 18 passed, 4 failed  | 22 passed, 0 failed |
| Linux catalogue / LuaJIT | 5 passed, 8 failed   | 13 passed, 0 failed |
| Linux manager / LuaJIT   | 18 passed, 4 failed  | 22 passed, 0 failed |
| Total                    | 56 passed, 24 failed | 80 passed, 0 failed |

All 28 new registered case executions have the existing suite owners.
The corpus contains seven complete handwritten source/expected models plus
the independent manager source and seven genuine refusal sources. Python's
standard JSON decoder independently checks full inputs/expectations and the
critical false/null/array/case/collision models; no expected model came from
this implementation. The generic decoder compatibility control deliberately
pins its prior untagged behavior.

The actual driver managers execute ordinary install/remove, verified same-id
replacement, refused-record publication and retry admission. The installed
record uses private real files read and closed with native standard I/O.
Transport, SHA, conversion, installation, input-source and other native
artifact ports remain controlled by the existing manager fixtures. This is
portable production-owner evidence, not real XKB/Hammerspoon installation,
native physical input or packaging acceptance.

The macOS owner already copies a native artifact before its record. Refused
record publication therefore leaves the controlled copy, and retry still
refuses it as foreign. The new regression checks that refusal and unchanged
record bytes, then explicitly repairs only that earlier controlled native
copy before retry. Production partial-effect/foreign-file policies remain
unchanged. The initial incorrect retry expectation is retained in
initial-partial-copy-retry-boundary.log. Initial helper/API and fixture syntax
mistakes were corrected before baseline/candidate qualification; the syntax
failure is retained in initial-manager-fixture-syntax-failure.log and the
helper error remains in the tool transcript.

Strict conventions passed (1774 AHK / 2743 Lua / 340 TOML files), and scoped
Prettier formatting passed. verify-change-plan.log uses the gate owner's
exported selector on all exact candidate paths; it selects format, JavaScript,
AHK units, Mac/Linux units and Mac/Linux E2E. Those complete selected gates,
Windows v3 native execution, hosted CI, real installation, packaging and
physical acceptance were NOT run here. Parent owns final composition,
selected full gates, all affected native CI and delivery.
