# AHK audit handoff — 2026-09-07

Audited SHA: `110994043919438d407859865d1098adcbc2be70`.
Scope: Windows driver and its test boundaries. No new production fixes were
implemented after the owner switched this task to audit-only work.

## Executive summary

The detailed, mutable implementation guide is [TODO.md](TODO.md). Six actionable
findings are recorded in [findings.json](findings.json): three transport/diagnostic
defects, one logger compensation defect, and two test-quality/isolation defects.
Severity and confidence are distinct. Code-confirmed unchecked ownership or
assertion defects are not presented as measured end-user corruption.

The owner confirmed that metrics work again. The previously uncommitted cache
experiment was restored to the committed private-copy implementation with explicit
permission, after an exact backup and native SQLite regression proof. The new
regression is commit `110994043`; 5,620 AHK tests and all selected gates passed.
The earlier native-argv fix is `7e11d6a09`, native journal receipts `3cafe79cf`.
These repaired issues are context, not newly open findings.

## Evidence and provenance

| Finding | Basis | Independent verification |
| --- | --- | --- |
| AHK-901 | legacy collision reproduced during argv investigation | current naming/cleanup code re-read; PID-reuse tree consequence remains unmeasured |
| AHK-902 | new actual TreeOwned child probe | parent scratch source and byte receipt opened by primary auditor |
| AHK-903 | current catch and live no-output failures | source re-read; cache UnsetError reproduced in a synthetic direct call |
| AHK-904 | current unchecked compensation return | source re-read; native combined-failure reproduction required before implementation |
| AHK-905 | current position assertions | source re-read; mutation execution is an implementation prerequisite |
| AHK-906 | current fixed-root recursive reset | source re-read; no foreign directory was deleted to prove the issue |

Local evidence files, not portable dependencies:

- `%TEMP%/ergopti-audit-argv-percent-20260907.ahk` and
  `ergopti-audit-percent-receipt-20260907.txt`: synthetic percent expansion.
  Hex `73796E7468657469632D657870616E646564` is `synthetic-expanded`.
- `%TEMP%/ergopti_metrics_cache_contract_probe.log`: actual UnsetError at the
  removed `KLR_CACHE_MIN_SAVE_INTERVAL_S` read, before SQL or filesystem access.
- `%TEMP%/ergopti-cache-regression-b8bb0bb3d65644858713557a7eb68b27/results.txt`:
  adopted user experiment, existing cache tests 5 passed / 4 failed.
- `%TEMP%/ergopti-cache-regression-71cd04e837e14b9482de50e01e99c5b9/results.txt`:
  missing constant restored only, new isolation test expected 1 row / received 2.
- `%TEMP%/ergopti-cache-regression-a0ec2f4dcfbd43bcb7b79529ecb369ba/results.txt`:
  coherent private-copy implementation, same isolation test passes.
- `%TEMP%/ergopti_cache_isolation_verify.log`: 5,620 AHK cases, complete manifest,
  all selected gates pass. The process was observed terminal with exit zero.
- `%TEMP%/ergopti_handoff_false_greens.log`: mechanical ratchet 0 versus baseline 0;
  explicitly does not detect mock-contract drift and spelling-only invariants.

The authorized exact user-file backup is
`%TEMP%/ergopti-user-cache-backup-bb5830af24604cd59578a516b4a50045/keylogger_reader_cache.ahk`,
SHA256 `D06A506CA9E0AFC6EAA3A505599C2A984CF8C20E4980CBB33A62D1D6685C2AB0`.
It is not a patch to reapply. The working file was restored to committed behavior.

## Performance observations and limits

The config redirection was re-read from `%APPDATA%/Ergopti/paths.toml`:
`D:/Documents/GitHub/config/ergopti_plus/`. Only the main dated runtime log was
aggregated, not its errors mirror. In the 2026-09-07 18:42–18:43 window, parsed
HotPath warnings contained 21 RemapEmit samples, maximum 612.44 ms. Other observed
maxima were Gesture.Invoke 18.23 ms, Tooltip.Build 18.03 ms and Hook.KeyDown 14.08 ms.
These are threshold-censored warnings during concurrent campaign activity, not
a controlled benchmark or all-input percentile. Nested segments must not be summed.

The worker debug log records a successful manifest at 18:54:15 with DB 5,016 ms,
projection 5,906 ms, encoding 2,891 ms, write 47 ms, total 13,860 ms and 1,812,596
JSON characters. The main log records delivery to the typing window at 18:54:30;
the user subsequently confirmed visual success. No universal latency conclusion
is drawn from this single run. Follow TODO I-02 for controlled measurement.

## Refutations and corrected interpretations

- Metrics remaining empty after the argv fix was not proof that the argv fix
  failed: a separate dirty-file cache error was reproduced.
- The existing cache tests did catch the missing global when run with that dirty
  file. The earlier worktree's green suite excluded it intentionally.
- Restoring only the constant is insufficient: the new test proves partial
  disk publication despite a failed refresh.
- One embedded-quote vector traversed the real child unchanged; do not report
  all quoting as broken based on the percent-expansion result.
- A large test file is not itself a functional bug. Splits in TODO are proposals
  around responsibility, with name-set and mutation-preservation requirements.
- Historical false-green counts in skill prose are not the current baseline.

## Memory watch-list and coverage register

Revalidated themes: native file receipt versus buffered acceptance; ownership
across async boundaries; source scans guarding nonempty subjects; cold/warm cache
equivalence; executable process-boundary tests; exclusive fixture cleanup.

No new exhaustive module pass was completed for all hooks, pause paths, LLM,
updater, UIA, clipboard, configuration or preview parity. The detailed checklist
names these gaps and the evidence each next pass must produce. Two consecutive
dry audit passes were not completed. This handoff does not certify a bug-free
driver and does not predict how many further bugs remain.

## Validation

The standard validate-report command was attempted and refused this second-pass
location: it only accepts one canonical report per dated directory. The earlier
2026_09_07 report already exists and was deliberately not overwritten. Therefore
this supplemental manifest is NOT validated by that workflow and must not be
passed to its implementation automation as though it were. Its JSON fields can
be inspected alongside this report; the Markdown checklist is the handoff entry.
Use verify-change for the documentation paths. Keep this evidence snapshot stable;
implementation status belongs in TODO receipts and atomic commit history.
