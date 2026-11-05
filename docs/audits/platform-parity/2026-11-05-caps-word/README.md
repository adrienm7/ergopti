# CapsWord audit metadata projections

`owner.json` is the root reviewer's adjudicated input. Original submitted bytes
remain retained with explicit formatting/editorial provenance in `validation/`.
This helper validates metadata and local artifact custody; it does not
execute an Ergopti driver, establish test coverage, prove intent, or certify
runtime/native parity. It pins this campaign's source and date explicitly.

The root adjudicator normalizes role-specific submitted IDs to canonical
`CWW-001`, `CWM-001`, `CWL-001` and `CWS-001` forms when needed. The original
spelling remains in `submitted_id`; reviewer reports and manifests retain their
submitted values. This mapping does not create an additional finding or change
its implementation status. No synthetic sample finding is audit evidence.

This composite four-role metadata schema is separate from the legacy AHK/HS
report-validator envelope. It does not claim that the legacy validator accepted
a CapsWord composite manifest.

From the campaign directory, with the repository's pinned Node on `PATH`:

```sh
python3 project.py --repo-root /workspace/ergopti
python3 project.py --repo-root /workspace/ergopti --check
python3 check_project.py /workspace/ergopti
```

The first command validates input before writing `index.json`, `findings.json`,
`capabilities.json`, and `capabilities.md`. The second rejects missing or changed
projections. Repository Prettier formats all generated output. `--directory`
selects a different campaign directory. `--repo-root` is explicit for temporary
directories; inside the repository, its nearest ancestor `package.json` supplies
the default. Standard-library validation functions have no Python dependencies.

`sample-owner.json` illustrates the complete schema with synthetic placeholders.
It is **not audit evidence** and cannot be validated until its referenced reports
and proof files exist. `check_project.py` creates all those files exclusively in
temporary directories and exercises both an all-zero owner and a populated
owner. It rejects 22 malformed cases, including changed provenance, omitted role
and coverage, invalid guarantees/severity, missing and altered evidence, traversal,
symlink input/output, unlinked defect claims, and stale generated output.

Each of the four exact role slots (`windows`, `macos`, `linux`, `shared`) has a
distinct report, nonempty evidence, a nonempty coverage list and a findings list
that may be empty. Each report contains the full audited SHA. Evidence entries
are campaign-relative `{ "path": "...", "sha256": "..." }` objects; `sha256`
is optional but, when supplied, must match the file bytes. Evidence must be
regular files inside the campaign without symlink hops or traversal.

Coverage and findings require `basis` (`source`, `actual-owner`, or `native`) and
a nonempty `qualification` explaining the actual boundary or limitation. Finding
IDs are unique across all roles; canonical fields follow the audit report
contract. Findings without G1–G5 must name `additional_properties` instead.
Root adjudication remains responsible for the correctness of those claims and
for re-deriving evidence rather than trusting submitted labels.

Capability rows have separate per-OS `availability` and `observation_basis`
objects, plus per-OS prose and a cross-OS `basis` qualification. Availability is
`present`, `absent`, `partial`, `native-alternative`, or `unverified`; it is never
inferred from a successful probe or an absent manifest row. Classifications are
`raw_parity`, `explicit_intent`, `native_constraint`, `unknown_intent`,
`observed_defect`, `observed_limit`, `native_alternative`, or
`documentation_only`. An `observed_defect` requires at least one existing
canonical `finding_ids` reference. Root prose must cite explicit policy before
using `explicit_intent`.

These dated projections remain historical after source changes. They do not
replace the live website's configuration/action inventory or turn source hashes
into proof of complete feature coverage.

## CapsWord continuation and exact counts

The initial four roles retain159 coverage rows and nine new findings. The
synthetic-key countercheck contributes12 more rows and a CapsWord consumer
extension of existing `WRSL-001`:171 canonical rows, ten finding observations,
**nine new findings and one known-root extension**, not ten new roots. Raw
Windows/macOS/Linux/shared IDs are retained as `submitted_id`; canonical IDs
are `CWW-001`, `CWM-001`, `CWL-001`, `CWS-001` and so on. `WRSL-001` deliberately
keeps its existing global identity.

`check_sources.py` compares pinned Git and current bytes for177 overlapping
claims over136 named paths. It refuses drift; it does not refresh hashes,
prove semantic equivalence or inspect every transitive dependency.

```sh
python3 check_sources.py /path/to/ergopti --output /tmp/capsword-sources.json
python3 replay.py /path/to/ergopti --output /tmp/capsword-replay
```

The parent replay runs53 processes with a separate TMPDIR for each. Its records
distinguish Windows lexical checks, real Lua owners over recorded native ports,
generated graphs, metadata controls and registered tests. `validation/` retains
failed initial diagnostics, qualified corrections and final successful receipts.
The source checker and replay tools support an explicit dated audit; they are
not perpetual runtime-parity certificates or automatic undeclared-feature
discovery.

The helper-adaptation receipt describes the initial scaffold before this root
README was extended. Its exact initial README is retained at
`validation/original-submissions/helper-scaffold/README.md.txt`; the two validator
programs retain the reviewed validation logic.
