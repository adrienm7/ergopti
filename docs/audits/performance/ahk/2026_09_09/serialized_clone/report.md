<!-- docs/audits/performance/ahk/2026_09_09/serialized_clone/report.md -->

# Private serialized clone experiment

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
