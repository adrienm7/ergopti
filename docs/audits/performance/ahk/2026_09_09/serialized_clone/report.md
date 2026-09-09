<!-- docs/audits/performance/ahk/2026_09_09/serialized_clone/report.md -->

# Private serialized clone experiment

Both prototypes were rejected: direct source serialization hides a reproduced
read failure; checked buffered backup regresses growth memory and imposes a
contiguous-allocation ceiling. Production keeps the ordinary memory-pager backup.
Sections below preserve the experiments chronologically; the final section
records the decision and the two retained native regression guards.

## Scope and provenance

Measured on 2026-09-09 against `fdd821508`, using AutoHotkey v2 x64 and the
vendored SQLite DLL. The source was the real derived `reader.sqlite`, opened
with `SQLiteConst.OPEN_RO`: 171482 pages, 702390272 bytes. No authoritative
`data.sql` was opened, no source writes were attempted, and no private content
was emitted. The resident and its UIA worker remained running. Every benchmark
ran hidden, sequentially, after the AHK verification process had exited.

The baseline calls production `SQLite_CloneMemory`. The scratch candidate
calls `sqlite3_serialize` on the same readonly connection, then transfers the
native buffer to a separate in-memory connection with `sqlite3_deserialize`.
This experiment preserves the private-candidate architecture; it does not open
the shared image read-write.

## Reproduction

Scratch directory:
`D:/Documents/GitHub/ergopti-ahk-verification-temp-2026-09-08`.
Script: `metrics-serialized-clone-probe.ahk`. Set both `TEMP` and `TMP` to that
directory and launch the interpreter hidden with these arguments:

```text
/ErrorStdOut <scratch>/metrics-serialized-clone-probe.ahk backup
/ErrorStdOut <scratch>/metrics-serialized-clone-probe.ahk serialized
```

Each process opens the readonly source once, then times three clones with QPC.
After each timed clone, it compares page and schema-object counts and executes
a private create/insert/rollback transaction, then closes the candidate. The
memory receipts are process-lifetime peaks from `K32GetProcessMemoryInfo`;
they include these post-timing checks and are not whole-system memory usage.
Disk-cache state is uncontrolled, and no full-dashboard latency was measured.

## Measurements

The final reverse-order pair retained the process handle before waiting, and
both native exit codes were captured as zero:

| Mode | Clone samples (ms) | Peak working set (bytes) | Peak commit (bytes) |
| --- | --- | --- | --- |
| Serialized candidate | 1105.841, 1117.541, 1111.381 | 720322560 | 709640192 |
| Production backup | 1639.999, 1752.203, 1599.140 | 822886400 | 849563648 |

Receipts: `metrics-serialized-clone-candidate-03.out/.exit` and
`metrics-serialized-clone-backup-02.out/.exit`.

Earlier runs, in order, were backup `1649.572/1653.885/1627.969`, candidate
`1258.303/1146.605/1135.078`, then candidate `1202.772/1140.890/1099.495` ms.
All printed their final structural/memory receipts, but their PowerShell
launcher did not retain a native exit code. The second candidate run was
incorrectly classified as failed by comparing that null code with zero; it
was an orchestration failure, not a recorded native assertion failure.
These preliminary receipts remain available as `backup-01`, `candidate-01`,
and `candidate-02` under the same filename prefix.

## Decision and remaining proof

The measured copy phase is promising, with lower process memory peaks. Do not
ship the prototype yet: structural counts do not prove complete row or JSON
equivalence, and the small mutation does not prove growth behavior.

Before adoption, verify full projection equivalence, realistic incremental
refresh cost, memory growth beyond the initial allocation, allocation/native
failures, buffer ownership, retained resident isolation, and failed aggregate
publication. Existing backup fault-injection guarantees must remain covered.

The [SQLite serialization contract](https://www.sqlite.org/c3ref/serialize.html)
defines the allocated buffer ownership. The
[deserialization contract](https://www.sqlite.org/c3ref/deserialize.html)
documents buffer release on failure, resize flags, and WAL restrictions.
These require explicit tests and an intentional supported-input contract;
they are not reasons to silently fall back or weaken snapshot atomicity.

## Contract investigation and rejection of direct source serialization

The original prototype reproduced complete production JSON output byte-for-byte:
1910238 bytes for the manifest, 15139586 for historical n-grams, and 42506 for
the complete today index. `metrics-serialized-clone-equivalence-01` exited zero.
This was a successful-input proof, not a failure-isolation proof.

Native contracts exposed WAL header incompatibility and the memdb VFS's default
1073741824-byte growth ceiling. The scratch prototype converted its private WAL
header and derived its byte ceiling from native page geometry. Empty schemas,
growth beyond initial capacity, rollback, and source isolation then passed.

More importantly, the [SQLite implementation](https://raw.githubusercontent.com/sqlite/sqlite/master/src/memdb.c)
can zero a page when `sqlite3PagerGet` fails while serializing an ordinary source.
The wired `sqlite-readonly-clone-read-failure` regression reproduces this with
real Windows `LockFileEx`, making an uncached final page of an owned fixture
unreadable through other handles. The native backup rejects the read error;
the direct serialization candidate returned a nonzero handle. Receipt
`sqlite-readonly-clone-read-failure-02.out/.exit` records the failure, exit 1.
No real user database was altered. Direct source serialization is rejected.

Two fixture assumptions were also corrected rather than treated as product bugs:
an empty image need not retain a zero physical page count, and the shipped DLL
did not reject deserialize solely for a destination read transaction/cursor.
The final native-failure fixture denies the internal ATTACH through SQLite's
authorizer, then verifies buffer release and preserved destination data.

## Checked buffered-backup candidate

The replacement allocates a native buffer sized from source page geometry and
adopts it as an **empty** memdb with `sqlite3_deserialize`. It fills every source
page through the existing `SQLite_BackupInto`, preserving checked reads and
backup cleanup. Only readonly inputs select this destination; writable resident
inputs keep the ordinary memory pager. The shared source remains OPEN_RO.

After successful backup, a no-copy borrow of the **destination** buffer permits
normalizing WAL header bytes and resetting the idle pager. This does not invoke
the rejected source-reading serialization path. The memdb byte ceiling follows
native page-size and max-page-count values instead of adding a 1 GiB limit.

Initial sequential native samples from `metrics-buffered-backup-bench.ahk`:

| Mode | Clone samples (ms) | Peak working set (bytes) | Peak commit (bytes) |
| --- | --- | --- | --- |
| Original memory-pager backup | 1518.241, 1467.494, 1321.208 | 821940224 | 849334272 |
| Buffered-backup prototype | 1044.463, 1006.533, 1188.086 | 722558976 | 711864320 |

Both processes exited zero. Receipts are `metrics-buffered-backup-legacy-01`
and `metrics-buffered-backup-buffered-01`, with `.out/.err/.exit` extensions.
The script's `legacy` mode explicitly opens a normal memory DB and calls the
unchanged backup primitive, so it remains an independent baseline after routing
is changed in `SQLite_CloneMemory`. `production` mode calls that public helper.

The first production pair (`legacy-final-01` / `production-final-01`) was slower
and a foreign Hammerspoon verification process was found active immediately
afterward. Preserve those receipts, but do not use them as final isolated timing
evidence. New native runs were paused until that specific process terminated.

The candidate reproduced the three complete JSON outputs above in
`metrics-buffered-backup-equivalence-01`, exit zero. Nineteen native cases passed
in `sqlite-readonly-clone-buffered-02`, including nondefault page sizes, held WAL
snapshots, growth, rollback, eight ownership failure stages, allocator failure,
native authorizer rejection, and the locked-page read error. Additional early
ownership guards were subsequently added to the scratch prototype. They were
not validated before the design was rejected below and are not shipped.

## Final decision: retain the ordinary memory-pager backup

Both runtime prototypes are rejected. Direct source serialization can hide read
failures. Checked buffered backup preserves those failures but introduces a
contiguous-allocation limit and an unacceptable small-growth memory regression.

The vendored DLL reports SQLite 3.50.4. Its
[allocator implementation](https://raw.githubusercontent.com/sqlite/sqlite/version-3.50.4/src/malloc.c)
rejects any single allocation above 2147483391 bytes, including requests through
the 64-bit allocation APIs. Increasing the memdb logical file-size limit does
not remove this allocator ceiling. An ordinary pager allocates separate pages;
the proposed contiguous image would impose a new limit on larger histories.

The [memdb growth implementation](https://raw.githubusercontent.com/sqlite/sqlite/version-3.50.4/src/memdb.c)
doubles the required allocation when growing, subject to the logical limit.
A native 8 MiB synthetic payload followed by a 1 MiB insert reproduced the
consequence: both paths produced a 9453568-byte database, but checked buffered
backup retained 18995008 native bytes versus 10181416 for the ordinary pager.
`sqlite-readonly-clone-growth-rejected-01.out/.exit` records the failing guard,
exit 1. This uses SQLite allocation accounting, not process RSS or timing.

A later timing pair also failed to establish a stable benefit under memory
pressure. `production-final-02` measured 1987.405/3025.009/1861.980 ms, while
`legacy-final-02` measured 2004.158/2673.240/1955.048 ms; both exited zero.
Approximately 1 GiB of physical RAM was free and browser activity continued.
These samples do not establish an isolated latency improvement.

The runtime is restored to the previously committed backup implementation.
Only two native guards are retained: unreadable-page rejection with a successful
post-unlock control, and small-growth allocations against the existing pager.
The complete prototype and its broader experimental tests are archived in the
campaign scratch directory. Neither this investigation nor its successful-input
comparisons measure complete dashboard opening or prove that no bugs remain.

The two retained cases passed against restored production in
`sqlite-readonly-clone-retained-01.out/.exit`, exit 0. Their failing prototype
receipts above establish that the guards can reject the unsafe alternatives.
