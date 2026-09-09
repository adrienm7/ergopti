<!-- docs/audits/performance/ahk/2026_09_09/sqlite_clone_test/report.md -->

# Readonly clone regression test duplication

## Scope and evidence

The Windows unit test `sqlite-readonly-clone-read-failure` locks the last page
of an owned 8 MiB synthetic SQLite image. Before this change it attempted both
`SQLite_BackupInto` and `SQLite_CloneMemory` while the lock was held.
At baseline commit `16ac0fb92`, the latter creates a memory database and calls
the same `SQLite_BackupInto` implementation. The direct failure control repeats
the native copy failure already exercised through the clone's public boundary.

The complete-suite receipt `metrics-late-publication-gate-01.log` measured this
test at 3008.992 ms. A separate hidden native probe,
`sqlite-locked-page-timing-02`, used the same 8 MiB payload size and byte-range
lock and measured 1445.4851 ms between the backup-step and backup-finish seams.
This attributes most of each failed copy's elapsed time to the native call;
there is no explicit sleep to remove from the AHK test.

## Change and validation

Remove only the direct backup attempt and its extra destination handle. Retain
the fresh readonly source, successful lock acquisition, rejected clone, exact
unlock, successful fresh clone after unlocking, integrity check, and payload
length assertion. A clone that returns success for unreadable pages still fails
the original regression assertion. Production copy behavior is unchanged.

The targeted receipt `sqlite-readonly-dedup-01` passed in 1623.504 ms. This is
one targeted sample compared with one full-suite sample, not a latency
distribution or a controlled estimate of the total suite speedup. The removed
native attempt explains the expected reduction; RAM and CPU were not measured.
All receipts and the standalone probe are in the campaign scratch on D:.
No private journal or derived production database was opened by the probe.
