# Dead-key composition audit projections

This campaign records source `f2c3ea43542c985fb20e5f0887976f1c02525341`,
dated November 5, 2026. `owner.json` is the root reviewer's adjudicated input;
the four exact roles are `windows`, `macos`, `linux` and `shared`.
Each role needs qualified coverage and evidence. Findings may be empty.
Metadata acceptance does not establish runtime parity or native receiving.

From this directory, with the repository's pinned Node on PATH:

```sh
python3 project.py --repo-root /path/to/ergopti
python3 project.py --repo-root /path/to/ergopti --check
python3 check_project.py /path/to/ergopti
python3 check_sources.py /path/to/ergopti --output /tmp/dead-keys-sources.json
python3 validation/check_source_guards.py /path/to/ergopti /tmp/dead-keys-source-guards
python3 check_custody.py --output /tmp/dead-keys-custody.json
python3 validation/check_custody_controls.py /tmp/dead-keys-custody-controls.json
```

The generator validates `owner.json` before rendering `index.json`,
`findings.json`, `capabilities.json` and `capabilities.md`. Check mode rejects
missing or changed projections. The control program accepts both populated
and zero-finding owners and rejects 22 malformed controls, including missing
roles/evidence/qualification, invalid provenance, unsafe paths, symlinks,
unlinked defect claims and stale projections. `sample-owner.json` is synthetic
schema data, not a real audit observation.

Every finding and coverage summary has an observation basis and qualification.
Each capability has a separate availability and basis for each OS. A source
file, action alias or native provider is not evidence of whole-capability
absence or equivalent native behavior. Intent, constraints, observed defects
and unresolved policy remain distinct. Canonical IDs use `DKW-001`, `DKM-001`,
`DKL-001` and `DKS-001` where applicable; submitted identities remain traceable.

The source checker reads each role's `source-receipts.json` as
`{audited_sha, files: [{path, sha256}]}`. It authenticates named files against
both pinned Git blobs and current bytes, while allowing descendant HEADs.
It does not automatically rehash changed sources or infer transitive coverage.
The guard controls use real Git objects and a private skeleton containing only
the named files and receipts: two positive cases and five distinct failures
(wrong pin, wrong digest, parent traversal, symbolic receipt, current-file
drift while the pinned blob remains unchanged). Their outputs go to the
explicitly selected directory, preserving canonical evidence.

This is a bounded composite metadata/custody schema, not the legacy AHK/HS
report-validator envelope or automatic discovery of all semantic features.
Source-only Windows checks are not AutoHotkey execution. Original Lua owners
over recorded native ports are not a native receiving application. Genuine
XKB/Compose components, where measured, retain their explicit keymap/locale
and component boundary. A successful snapshot replay may reproduce a known
failure; it does not mean the defect was fixed.

Original helper versions and declared adaptation provenance are retained under
`validation/`. Preserve original worker bytes and hashes when archival
formatting needs an explicit, separately recorded transformation. Compact
programs, decisive output and final sweep receipts are preferred over repeated
copies of identical traces. The root TODO is the implementation checklist.

## Independent replay and exact custody

From the repository root (Lua 5.4, LuaJIT and libxkbcommon available):

```sh
python3 docs/audits/platform-parity/2026-11-05-dead-keys/validation/replay_owners.py "$PWD" "$PWD/docs/audits/platform-parity/2026-11-05-dead-keys" /tmp/dead-keys-owner-replay
python3 docs/audits/platform-parity/2026-11-05-dead-keys/validation/replay_shared.py --help
```

The owners output directory must not exist; select a fresh external scratch path.
The shared runner documents its output arguments through `--help`.
The replay runners authenticate the archives, then reconstruct all exact worker
bytes into private scratch with `validation/materialize.py`. This restores
encoded programs and generated inputs, and prevents source witnesses that
publish sibling receipts from rewriting the frozen archive.
Never invoke the frozen worker sweep scripts in place: their historical paths
and write destinations are retained for traceability, not as archive mutation
commands. See `validation/root-replay/` and `validation/root-shared.json` for
actual independent invocations and decisive results.

`check_custody.py` verifies all 86 payload identities and four immutable worker
manifests. Nine JSON output files have only narrowly declared,
type-preserving formatting changes; exact original bytes remain in
`validation/worker-originals/`. Eleven source members (the upstream Hammerspoon source, three exact generated
XKB types files and seven original Python programs) are stored as lossless gzip there, with a declared storage SHA and decoded original SHA in
`validation/worker-encoding-provenance.json`. Unknown codecs, physical/alias
collisions, altered decoded content and undeclared byte drift are rejected.
The upstream Git blob identity is independently recorded in
`validation/external-source-identity.json`. This is external API provenance,
not evidence that the installed native macOS event source was executed.

Metadata generation updates this dated campaign's projections from adjudicated
input. Source checks deliberately fail when reviewed bytes change; maintaining
current feature claims then requires review, not silent receipt regeneration.
This does not automatically discover every semantic feature or replace the
repository's live feature inventory generator.

The local gate receipt is [validation/verification.json](validation/verification.json).
It distinguishes the passing 572-check JS run from its initial formatting failure
and the successful format/replay rechecks after lossless archival correction.
The complete initial log remains available as `validation/full-gate.log.gz`.
