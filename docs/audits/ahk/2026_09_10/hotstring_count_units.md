# Windows hotstring count-unit receipts

## Confirmed failure

AHK records hotstring savings in UTF-16 code units (`StrLen`). Its privacy mask
preserves that length. The reader previously reconstructed input counts with
SQLite `LENGTH`, which counts Unicode scalars. A supplementary trigger and an
ASCII replacement of length four therefore produced gross/input counts 3/1 in
clear text but 4/2 after masking. Net savings remained two in both cases.

The native synthetic reproduction is `hotstring-unicode-units-01` in the
campaign scratch. No real journal was read or modified for this finding.

## Compatible declaration

The Windows SQL producer now appends an idempotent insertion into the existing
`meta` table for fired hotstrings:

- key: `hotstring_count_unit:` followed by the exact device ID;
- value: `utf16`, with exact case.

The event and declaration remain inside the ingest batch's transaction. Existing
schemas already have `meta`, so the new statements do not require a column
migration. Older readers can replay them but retain their previous interpretation.
The declaration contains no trigger or replacement text.

The Windows reader uses the declaration to preserve that device's established
counting unit, including its older events. For valid UTF-8 strings, UTF-16 length
is the scalar length plus one per four-byte leading byte (F0 through F4). The
SQL expression counts those bytes without an interpreted callback per row.
Unsupported or malformed declarations reject preparation instead of guessing.

Unmarked devices retain the legacy scalar interpretation. This preserves
existing non-Windows behavior; it does not reconstruct missing Windows origin
information. For example, identical supplementary trigger/replacement strings
can yield the same stored net saving under both unit conventions while having
different gross/input counts. Event text and net saving cannot resolve that
ambiguity. A Windows device that produces a new fired row now declares its unit;
an inactive, unmarked historical device remains outside this correction.

## Incremental and cache behavior

Before applying an incremental tail, the reader captures declared units. The
first newly observed declaration recounts only SQL-owned hotstring fields for
that device's history. It does not replay historical typing or n-grams. An
identical declaration does not repeat the historical recount. A removed or
changed consumed declaration rejects the candidate.

Any failed recount stays in the private candidate: durable rows, offsets and
previous aggregate values remain unchanged. The existing candidate owner handles
cleanup and retry. Cache format 7 invalidates images with the previous aggregate
semantics; this can require one complete reconstruction. No real-history latency
or complete dashboard-opening measurement is claimed here.

## Regression evidence

`hotstring-count-units-before-01` failed on public gross counts (4 versus 3) and
historical input counts after a first declaration (2 versus 1).
`hotstring-count-units-after-03` passed six native cases: mixed devices and
redaction parity; historical correction with a trigger refusing duplicate work;
actual writer replay/idempotence across nine Unicode vectors; failed recount
preserving the disk image and recovering after repair; unsupported and
differently cased unit rejection. SQL-backed tests use the canonical schema.
Full-gate receipts are maintained in the campaign plan; targeted success alone
is not proof of complete coverage.
