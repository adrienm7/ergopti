# Windows AHK implementation and test-quality handoff

Audited base: `110994043919438d407859865d1098adcbc2be70`.
Date: 2026-09-07. Scope: `static/ergopti_plus/windows/` and its verification boundary.
This is the mutable checklist. The accompanying [report](report.md) and
[manifest](findings.json) preserve the evidence snapshot.

## Read this before implementing anything

The owner requested audit and planning only, to conserve their weekly quota.
Do not resume an autonomous implementation campaign without a new request.
This document is detailed, but it is NOT proof that every driver bug has been
found. The coverage register at the end explicitly lists unfinished sweeps.
Unchecked items include bugs, test debt, and investigations; they are not all
confirmed production bugs. Never advertise the checklist length as a bug count.

The metrics dashboard works again, confirmed by the user. Do not undo that repair.
Two independent causes were involved: trailing-backslash argument corruption,
and an uncommitted cache experiment removing a still-used global constant.
The latter also violated durable cache isolation. It was backed up, tested,
and replaced with the coherent committed private-copy implementation with the
owner's permission. Do NOT reapply the experiment as an optimization shortcut.

### Working and delivery rules

- [ ] Read `AGENTS.md`, routed memory, and the skills matching the chosen item.
- [ ] Inspect current HEAD, worktree list, status, and incoming commits; paths and
      line numbers here are navigation hints, not immutable anchors.
- [ ] Use the owned Windows worktree or a newly authorized worktree; do not edit
      the macOS sibling. Preserve every unrelated index/worktree change.
- [ ] Choose ONE root cause. Record its original failure before editing production.
- [ ] Prefer a small behavior test. Do not implement the subject inside its mock.
- [ ] Run the test against the unfixed state in an isolated fixture; do not stash,
      reset, or overwrite an active checkout to manufacture red evidence.
- [ ] Implement; run the same test; require it to fail for the original mechanism
      and pass for the correction, with a healthy control.
- [ ] Run `node tools/test/verify-change.cjs --plan`, then all selected gates.
- [ ] Preserve UTF-8 BOM + LF for AHK. Run encoding and strict conventions.
- [ ] Commit one fix with regression coverage, exact staged paths, English
      Conventional Commit subject. Do not push. Rebase and fast-forward only.
- [ ] Record commit SHA, red/green command/results, validation and limitations
      under the item's completion receipt. Only then tick the parent box.

Current local runtime: AutoHotkey v2.0.26, executable
`C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe`. The Node version pinned by
the repository must be used; the ambient Node was not the required version.
Use the RTK launcher for human output, raw commands for parsed/captured output.
Never run `/validate`: on this interpreter it executes the script.
Never run two `run_all.ahk` processes concurrently: single-instance behavior
can kill the earlier run and manufacture incomplete evidence.

## Execution order and decision boundaries

1. Capture ownership (AHK-901), literal arguments (AHK-902), worker diagnostics
   (AHK-903): independent commits, but coordinate edits to the shell adapter.
2. Logger compensation ownership (AHK-904): isolated native-file regressions.
3. SQL checkpoint test quality (AHK-905), fixture ownership (AHK-906).
4. Real metrics publication integration, then the high-value test splits.
5. Measured latency investigations; only then design a safe cache optimization.
6. Remaining module/flow sweeps. Promote hypotheses only after reproduction.

For a less capable implementation model: do not invent a new abstraction to
resolve uncertainty. Stop and request review for transaction nesting, native
HANDLE ownership, parser/quoting changes, or ambiguous shared-driver contracts.
Small mechanical test moves are independent; production lifecycle fixes are not.

## Confirmed actionable findings

### AHK-901 — Capture files are not exclusively owned

- [ ] Fix capture ownership across the shell adapter.

Priority: high. Confidence: high for the legacy collision; source-derived risk
for synchronous and stale-PID tree collisions. Guarantees: G2, G3.
Source: `adapters/shell_runner.ahk`; `ShellRunner_Exec`, `ShellRunner_Spawn`,
`ShellRunner_SpawnTreeOwned`, legacy/tree terminal claims and cleanup.

**Evidence and cause.** Sync uses `A_TickCount`, legacy uses a process-local
counter, tree uses PID + counter. None reserves the path exclusively. A legacy
task numbered one collided with another process's open `ergopti_sr_1.tmp`.
The redirection failed and the callback looked successful with empty output.
Moving only the scratch probe's counter into an unused range made the child run.
The native argv test currently skips occupied legacy capture names to avoid
damaging foreign captures; that is fixture isolation, NOT a production fix.

**Implementation sequence.**

- [ ] Introduce one capture owner abstraction shared by the three paths.
- [ ] Acquire a private per-launch directory exclusively, e.g. successful native
      `CreateDirectoryW`; use a fixed child name such as `output.tmp` inside it.
      A nonce only proposes a name; successful creation grants ownership.
- [ ] Use a bounded collision policy and a distinct diagnostic for allocation
      failure. Do not fall back to the old global name.
- [ ] Allocate synchronous capture after validation, immediately before launch.
- [ ] Allocate async capture inside `start()`, after claiming STARTING, not in
      the constructor. A never-started handle must create no artifact.
- [ ] Build the command after allocation. Transfer the capture owner into the
      native/legacy claim along with exact process ownership.
- [ ] Cover start refusal, native creation failure, cancellation during start,
      normal completion, detach, callback exception, size limit and shutdown.
- [ ] Remove the file and then the empty directory only after writers are
      quiescent. No recursive deletion; never clean a failed acquisition target.
- [ ] With `CaptureOutput=false`, allocate nothing.
- [ ] Remove the temporary counter-skipping workaround in
      `tests/unit/test_shell_runner_native_argv.ahk` only after ownership is fixed.

**Required regression matrix.** Two real parent AHK processes, each performing
its first spawn under a private TEMP/TMP, with a barrier holding both children
alive. Distinct markers must arrive exactly once, in the correct owner. Add a
preoccupied candidate, never-started handle, allocation refusal, creation refusal,
cancel-before-adoption, duplicate start/terminate, detached completion, and a
callback that throws. Assert surviving foreign sentinel contents and zero owned
residue. Exercise sync, legacy and tree paths; do not infer one from another.

**Avoid.** PID + counter alone; deleting an existing path to make room; trusting
`FileExist` followed by creation as atomic; releasing while a child can write;
resetting the global task counter in the real suite.

Completion receipt: commit `___`; red `___`; green `___`; gates `___`.

### AHK-902 — Literal percent arguments undergo environment expansion

- [ ] Preserve literal argument values across the native process boundary.

Priority: high. Confidence: high, native TreeOwned reproduction. Guarantee: G2.
Source: the same shell adapter, `_SR_QuoteArgument`, command composition, and
`tests/support/argv_echo.ahk` / `tests/unit/test_shell_runner_native_argv.ahk`.

**Reproduction.** Set synthetic environment variable
`ERGOPTI_AUDIT_LITERAL_20260907=synthetic-expanded`. Request arguments
`%ERGOPTI_AUDIT_LITERAL_20260907%`, `a"b`, `after`. A real child received
`synthetic-expanded`, `a"b`, `after`. The contract promises no shell expansion.
The root cause is `cmd.exe /c` interpreting quoted argument text; quotes do not
disable percent expansion. Legacy uses the same shell mechanism but was not
executed in this additional probe. The tested embedded quote is NOT a finding.

**Implementation decision.** Prefer a direct native executable launch with
explicit inherited stdout/stderr handles for APIs accepting executable + argv.
Keep intentionally shell-oriented `ShellRunner_Exec(Cmd)` separate. If a smaller
CMD-preserving design is proposed, require real transport tests and authoritative
CMD semantics first; do not guess an escaping substitution. Rejecting all percent
arguments is a contract restriction, not equivalent behavior: seek owner review.

- [ ] Inventory callers requiring shell syntax versus literal argv.
- [ ] Preserve the job-before-resume guarantee in TreeOwned; do not introduce a
      window in which descendants escape ownership.
- [ ] Preserve independent executable validation, Unicode, empty args, newline
      refusal, trailing slash handling, stdout/stderr contract and cancellation.
- [ ] Add the percent vector to both native launch variants.
- [ ] Test unset variables, adjacent percent pairs, spaces, `&`, `|`, `<`, `>`,
      parentheses, embedded quotes and trailing slashes. These are test vectors,
      not claims that each currently fails.
- [ ] Verify delayed-expansion behavior explicitly if any shell remains.

Healthy control: `a"b` and `after` are preserved by the current tested path.
Never use actual secrets or dump the environment in the test or diagnostic.
Completion receipt: commit `___`; red `___`; green `___`; gates `___`.

### AHK-903 — Metrics worker swallows the useful exception

- [ ] Make terminal worker failures observable without leaking typing data.

Priority: high diagnostic impact. Confidence: high. Guarantee: G2.
Source: `modules/keylogger/keylogger_prefetch.ahk`, `KLPF_WorkerMain`,
`KLPF_WorkerDiagnostic`, `KLPF_OnWorkerDone`, `KLPF_WorkerRefuse`.

**Evidence.** After the argument fix, live warnings reported `exit=1: no output
captured`. The worker's catch deletes the stage and calls `ExitApp(1)` without
reporting the caught exception. A synthetic direct call reproduced the hidden
`UnsetError` at the cache cadence read. `/ErrorStdOut` cannot reveal an exception
that the program has already intercepted. The cache cause is fixed; this masking
mechanism remains.

- [ ] Name the current worker phase before each expensive boundary: argument
      decode, DB build, projection, serialization and stage publication.
- [ ] Catch the actual exception and produce a bounded diagnostic containing
      phase, exception class, source basename and line number.
- [ ] Do not blindly print Message, Extra, Stack, SQL, paths, app titles, typed
      text, URL, tokens or complete arguments. They can contain private payloads.
- [ ] Emit to the captured worker output channel before cleanup and nonzero exit;
      let the initialized parent route it through the central logger.
- [ ] Handle false-return failure paths too: no DB, refused stage write, invalid
      range projection. They need an explicit reason even without an exception.
- [ ] Keep cleanup failure distinct from the original failure; neither may turn
      the exit into success. Do not launch the full resident driver in a test.
- [ ] Keep malformed invocation refusal distinct from a computation failure.

**Tests.** Real isolated worker entry, invalid timing conversion, exception during
DB/projection, refused publication, healthy payload. Assert exact nonzero outcome,
phase/type/location, no final stage, and absence of a synthetic private marker.
Verify the parent transcript remains informative after its 400-character bound.
Do not settle for a source test asserting that a `catch` or log token exists.

Completion receipt: commit `___`; red `___`; green `___`; gates `___`.

### AHK-904 — Logger forgets failed compensation authority

- [ ] Fence subsequent log appends behind successful compensation.

Priority: high for diagnostic integrity. Confidence: high for unchecked return;
the full corruption sequence is code-derived and still needs native reproduction.
Guarantees: G2, G3. Source: `infra/logger.ahk`, `_LoggerAppendComplete`,
`_LoggerTruncateAppend`, `_LoggerFlush`, bounded debug writes and terminal flushes.

**Mechanism.** A short native append or failed stable flush enters the catch.
`ResolvedTruncate.Call(...)` has its result ignored; the handle closes and the
logical batch remains queued. If truncation failed, its byte boundary is forgotten.
A later flush can append the whole batch after the surviving prefix, corrupting
or duplicating logs. Returning false is not sufficient repair ownership.

- [ ] Model recovery debt by exact destination and pre-write boundary.
- [ ] Retain that debt if truncation OR the compensation durability fence fails.
- [ ] Before any successor append to that destination, repair the debt and verify
      the exact receipt. A failed repair leaves the queue and boundary owned.
- [ ] Decide and test how rotation, purge, fan-out destinations, forced flush,
      bounded debug logs, reentrant flush and exit interact with outstanding debt.
- [ ] Keep native I/O outside long Critical regions. Claim/release state in short
      non-pumping sections; restore the caller's Critical state on every path.
- [ ] Never diagnose a broken logger by recursively invoking that same sink.

**Native proof.** Reuse existing WriteFn/TruncateFn seams. Actually write a short
prefix, refuse compensation, request another flush, and prove no successor bytes
appear. Allow repair and retry; require exactly one logical batch and one BOM.
Repeat with a full write + refused durability fence + refused compensation.
Include new/existing files and multibyte payloads. A mock that reports a short
count without writing bytes cannot prove this defect.

Completion receipt: commit `___`; red `___`; green `___`; gates `___`.

### AHK-905 — SQL checkpoint meta-test admits missing subjects

- [ ] Replace the weak SQL ordering assertions with causal coverage.

Priority: medium, confirmed test-quality defect. Guarantee: G2 verification.
Source: `tests/unit/test_keylogger_today_fh_flush.ahk`,
`_KLTF_DataSqlDurabilityPrecedesCheckpoint` (AHK-075).

`ShortWritePos` and `StableFailurePos` can be zero while `RollbackPos > ...`
passes. The checkpoint search starts after the append, so a newly inserted
premature checkpoint can be missed. Some assertions also pin diagnostic strings
and local variable spelling rather than durable behavior.

- [ ] Map every assertion to the existing native SQL receipt/compensation cases.
- [ ] Retain the caller-level invariant: a refused SQL append must not advance
      the durable offset or call `KL_SaveState` for that failed SQL batch.
- [ ] Prefer an ingest/checkpoint behavior seam, with real append failure and
      observable offset/state publication, over helper text inspection.
- [ ] If a structural remainder is necessary, assert every subject exists before
      ordering comparisons and identify the SQL branch, not the whole function.
- [ ] Preserve the legitimate no-statements checkpoint branch. A blanket ban on
      every checkpoint before every append would encode the wrong behavior.
- [ ] Mutation proof: remove the failure subject; insert a SQL-path premature
      checkpoint. Both mutations must fail the replacement for the right reason.

Only retire the superseded spelling assertions after this proof. Never remove
the real native tests because both tests mention the same historical finding.
Completion receipt: commit `___`; mutations `___`; replacement coverage `___`.

### AHK-906 — Durable-cache fixture recursively deletes a shared temp root

- [ ] Give the durable-cache fixture exclusive cleanup ownership.

Priority: medium. Confidence: high from source; no foreign directory was deleted
as part of this audit. Guarantee: G3/test isolation.
Source: `tests/unit/test_klr_durable_cache.ahk`, `_KLRDC_Root`, `_KLRDC_Reset`.
The root is fixed at `A_Temp\ergopti_klr_durable_cache\`; reset recursively deletes
it without proving this test invocation owns it. Another process or a prior
artifact can occupy that name. A successful suite does not prove safe cleanup.

- [ ] Acquire a per-suite private directory exclusively before any fixture write.
- [ ] Store the exact canonical acquired root; cleanup is permitted only for it.
- [ ] Separate initialization from reset: reset cannot claim an existing root by
      deleting it. Do not silently ignore failed setup/teardown.
- [ ] Share the fixture through `tests/support/metrics/` or an equivalent cohesive
      support module, with explicit lifetime and no production side effects.
- [ ] Test a preexisting sentinel candidate, setup failure midway, two independent
      processes, and cleanup after an assertion throws.
- [ ] Prove unrelated sentinels remain unchanged. Do not reproduce by deleting an
      actual shared directory. Use a private outer TEMP for destructive fixtures.

The recent cache probes used separate private TEMP/TMP directories specifically
to avoid this existing fixture hazard. Apply the same audit to other fixed-root
fixtures; do not count every search match as a confirmed destructive path.
Completion receipt: commit `___`; isolation proof `___`; gates `___`.

## Test architecture: exact work packages

### T-01 — Preserve a manifest before moving tests

- [ ] Capture registered stable test names, source owner and executed case count.
- [ ] Capture which support helpers run at include time and which state they seed.
- [ ] Move one cohesive group per commit using exact paths; register every leaf.
- [ ] Compare test NAME sets before/after, not merely total counts. Equal counts
      can conceal a removed test and an accidental duplicate.
- [ ] Reject duplicate registration, missing includes, new side effects on include,
      and any moved test not selected by its stable `--only` slug.
- [ ] Run the registration-depth guard and git-move resilience guard.
- [ ] Do not create an independent second registry in package.json or a parallel
      generated list that can drift from `run_all.ahk`.

Suggested layout, adapted to actual ownership rather than a mandatory taxonomy:

```text
tests/
  unit/
    updater/{admission,network,staging,publication,teardown}/
    llm/{hotkey_ownership,trigger_transactions,providers,prediction}/
    config/{personal_toml,persistence,transitions}/
    metrics/{journal,sql,cache,worker,publication}/
    logger/{formatting,filtering,queue,durability,lifecycle}/
  integration/{shell,metrics,filesystem}/
  meta/{boot,registration,contracts}/
  support/{filesystem,process,metrics,config,llm}/
```

This is a proposal, not permission to bulk-move everything. Preserve useful
existing modules. Three levels are useful only where real ownership warrants it.

### T-02 — Split the largest mixed-responsibility tests

Line counts below were measured as physical lines at the audited SHA. They are
triage signals, NOT defects by themselves and NOT a size ceiling.

| Current file under tests/ | Lines | Proposed responsibility boundaries |
| --- | ---: | --- |
| unit/test_updater.ahk | 4403 | network outcome; staging ownership; config admission; tray publication; cancellation/teardown |
| unit/test_llm_hotkey_cross_owner_collision.ahk | 2071 | cross-owner reservation; navigation policy; stale callback/retirement |
| unit/test_personal_toml_io.ahk | 1786 | section loading; atomic writes; metadata round trips; metadata patch transactions |
| run_all.ahk | 1621 | inspect bootstrap versus explicit registry; do not blindly split include order |
| unit/test_llm_trigger_shortcut_transactions.ahk | 1574 | admission; trigger dispatch; recovery; watchdog and retry caps |
| unit/test_llm_prediction_engine.ahk | 1461 | scheduling; response ownership; cancellation; rendering eligibility |
| unit/test_hotstring_engine_main.ahk | 1420 | candidate selection; expansion; pause/context; retirement |
| unit/test_logger.ahk | 1359 | formatting/filtering; pending queue; fan-out; initialization/exit |
| unit/test_llm_api_remote.ahk | 1235 | request contract; streaming chunks; error/terminal outcomes |
| unit/test_config_persistence_transactions.ahk | 1207 | admission; durable writes; publication; rollback/recovery |
| unit/test_hotstrings_config.ahk | 1199 | validation; precedence; reload; publication |
| unit/test_llm_api_ollama.ahk | 1166 | provider request; stream protocol; cancellation; terminal result |
| unit/test_adapter_contract_vectors.ahk | 1145 | contract families; preserve one registration per actual vector |
| unit/test_hotstrings_full.ahk | 1142 | inspect overlaps with engine tests before deciding boundaries |
| unit/test_features_manifest.ahk | 1134 | loader contract; resolution; generated manifest invariants |

For EACH row:

- [ ] Read only its section/function/test-name inventory first.
- [ ] Identify shared mutable globals and setup/teardown ownership.
- [ ] Extract stable neutral fixture helpers into a small support module.
- [ ] Move tests without changing assertions in that commit.
- [ ] Preserve stable names and independently runnable slugs.
- [ ] Verify before/after name sets, registration and selected gates.
- [ ] Review assertion quality in a separate commit after the move is proven.

Do not split a cohesive state machine merely to reach 200 lines. Do not replace
multiple explicit owners with a generic mega-fixture controlled by dozens of flags.

### T-03 — Merge duplicate setup, not independent guarantees

- [ ] Build an overlap table: original finding, production entry, failure injection,
      observable assertion and platform boundary for each candidate pair.
- [ ] Treat tests as duplicates only if these dimensions and mutation sensitivity
      are equivalent. Similar names or both checking `false` do not suffice.
- [ ] Merge provider setup for remote/Ollama only where contracts actually agree.
      Keep provider-specific wire shapes, streaming completion and auth behavior.
- [ ] Reuse native filesystem fixtures across journal/SQL/logger, but keep separate
      owner-level queue, checkpoint and durability assertions.
- [ ] Parameterize path/encoding/result vectors when failure messages retain the
      precise vector and each case remains individually registered.
- [ ] Keep boundary controls: healthy writes, valid config and normal completion
      prove the harness can succeed, not merely that failure is always returned.
- [ ] Before deleting a duplicate, mutate the old bug and show the survivor fails.

### T-04 — Replace symptom tests with root-cause tests selectively

- [ ] Inventory `AssertThrows` cases: require exception type/reason and post-failure
      state when the scenario depends on a specific refusal, not arbitrary throws.
- [ ] Audit tests checking only file existence; add content, byte boundary, BOM,
      identity and publication assertions where these are the actual contract.
- [ ] Audit callback tests checking only call count; assert owner, result, payload,
      order and zero stale side effects.
- [ ] Audit source-position tests for zero positions, comments, renamed helpers,
      conditional branches and hidden earlier matches (AHK-905 is confirmed).
- [ ] Keep structural tests for load order, pause registration and startup graphs
      when runtime tests cannot cover their guarantee. Do not mass-convert them.
- [ ] Assert mocks expose the real API and faithfully preserve return shape/type.
- [ ] Audit source scans under meta/ that actually execute behaviors; reclassify
      only after preserving include and state initialization semantics.

Mechanical `find-false-greens.cjs` currently reports zero against baseline zero.
That does NOT prove the human-only categories above are absent. Historical skill
counts are not current findings; never copy them into a new bug estimate.

### T-05 — Metrics integration must exercise the full observable chain

- [ ] Build synthetic SQL fixtures, never use the user's real typing contents.
- [ ] Launch an isolated worker through the REAL shell adapter, with the actual
      entry argument vector and configured trailing-backslash path.
- [ ] Verify worker exit, staged bytes, JSON decode and nonzero expected counters.
- [ ] Drive parent completion/publication with the real generation owner.
- [ ] Assert the actual delivered payload revision and meaningful counter values,
      not just that ExecuteScript was called.
- [ ] Add wrong generation, cancellation, missing/empty/malformed stage, refused
      rename, newer range selection and closed/reopened window.
- [ ] Include no-data legitimate zero, date-range mismatch and wrong app filter
      controls so the test distinguishes absence of data from broken transport.
- [ ] Add worker failure diagnostics and visible failure-state coverage; a blank
      UI must not silently masquerade as a successfully loaded zero-data result.
- [ ] Where CI cannot run WebView2, keep an explicit native integration gate and
      document the remaining visual smoke. A JS mock alone is not native proof.

### T-06 — Commit-state versus running-state coverage

- [ ] Record tested SHA and dirty-path inventory with every validation receipt.
- [ ] Clearly label when a running driver uses a dirty file excluded from the
      worktree under test. The recent missing constant was caught by existing
      tests as soon as that file was included: 5 passed, 4 failed.
- [ ] Add a lightweight explicit pre-launch validation workflow for maintainer
      experiments, including targeted cache tests after cache edits.
- [ ] Do not silently stage all dirty files or block unrelated worktrees.
- [ ] Document that an old in-memory driver may require reload; new workers read
      current source but resident module state can still come from an older load.

### T-07 — Test failure-path setup must be safe itself

- [ ] Search fixture setup outside try/finally; verify resources are owned before
      the first failing operation and remain cleanup-owned if setup throws.
- [ ] Search shared temp names, unconditional recursive delete and path reassignment.
- [ ] Replace silent fixture setup failure with an assertion naming the failed
      precondition. A skipped fault injection is not a passing regression.
- [ ] Give child processes exact ownership and bounded teardown; do not kill by
      broad image name or an unverified reused PID.
- [ ] Snapshot and restore globals/critical state in finally; never restore a
      stale owner over a live successor created during a callback.

### T-08 — Make verification cheaper without making it less truthful

- [ ] Measure actual per-test/gate durations before deciding where time is spent.
- [ ] Use stable --only slugs during red/green iteration; final selected gates
      remain mandatory for each production commit.
- [ ] Separate expensive real-process tests conceptually from pure function tests,
      but keep them selected whenever the corresponding adapter changes.
- [ ] Do not parallelize two single-instance AHK runners. Independent JS checks
      or read-only reviews can run alongside one native runner when safe.
- [ ] Reuse immutable source manifests, not live mutable fixtures across tests.
- [ ] Keep execution manifests and partial-timeout reports; a timeout without a
      terminal handle is not permission to restart the same gate.

## Open investigations: NOT yet confirmed production bugs

### I-01 — Design a genuinely atomic write-through cache

- [ ] Preserve the private-copy behavior until a replacement proves all invariants.
- [ ] Re-read `KLR_CacheAttach`, `KLR_BuildDatabase`, `KLR_ApplyIncremental`,
      `SQLite_ExecReturnCarry`, typing projection, aggregate/walker rebuild,
      `KLR_PublishCandidate`, `KLR_CacheSaveIfOwned` and `KLR_ResetCache` together.
- [ ] If choosing one shared SQLite write transaction, acquire it BEFORE reading
      ledger offsets; revalidate identity/offset under the same authority.
- [ ] Handle nested BEGIN/COMMIT in ledger SQL and projection helpers explicitly.
      Wrapping the current pipeline in BEGIN IMMEDIATE alone is not correct.
- [ ] Commit raw rows, derived rows, identity/offset metadata and cache version
      together; expose memory state only after successful durable publication.
- [ ] Roll back every failure and abort; prove two workers cannot publish stale
      offsets or observe each other's partial projection.
- [ ] Check PRAGMA outcomes and lock/busy errors. Do not turn errors into success.
- [ ] Test process crash between every publication boundary and restart recovery.
- [ ] Test cache invalidation for replaced/truncated/new ledgers and changed schema.
- [ ] Benchmark same-size synthetic cold/warm data under the same machine load.

Mandatory controls: the newly added failed-refresh test, cached/cold equivalence,
unchanged input, complete batch followed by torn batch, failed rollback, concurrent
typing/apps workers, large UTF-8 payload and a surviving last-good projection.
Do not implement this architectural item without review of the transaction design.

### I-02 — Latency observations require attribution

- [ ] Re-measure keyboard/tooltip paths without a full test suite competing for CPU.
- [ ] Use the resolved config path from `%APPDATA%/Ergopti/paths.toml`, then
      `autohotkey/logs`; do not double-count the errors mirror.
- [ ] Inspect `infra/hotpath_profiler.ahk` thresholds and nested/exclusive timings.
- [ ] Record workload, timestamp window, process count, sample denominator, QPC
      distributions and maximum. Warning-only samples cannot yield all-input p99.
- [ ] Separate synchronous I/O, COM/UIA, remap emission, tooltip construction and
      scheduling contention before proposing an optimization.
- [ ] Profile metrics manifest versus full projection separately; a manifest
      success does not prove the expensive full build meets a latency target.

Observed, not a controlled benchmark: the main runtime log's 18:42–18:43 window
contains 21 RemapEmit warnings with maximum 612.44 ms; Gesture.Invoke maximum
18.23 ms, Tooltip.Build 18.03 ms, Hook.KeyDown 14.08 ms. Concurrent campaign
activity is a confounder. The successful manifest at 18:54:15 took 13,860 ms
overall (DB 5,016; projection 5,906; JSON 2,891; write 47). These observations
justify investigation, not a claim that a particular function is the root cause.

### I-03 — Full-build retry ownership under continuous ingest

- [ ] Reproduce sustained input while the metrics worker repeatedly fails.
- [ ] Check whether each ingest restarts an exhausted full-build budget; runtime
      logs contained repeated `retry 1/2`, but this is not sufficient causal proof.
- [ ] Distinguish intentional recovery on genuinely new data from unbounded
      reprocessing of the same failed snapshot.
- [ ] Test no busy loop, bounded work per revision, recovery after a changed
      snapshot, cancellation and no starvation of a newer requested range.
- [ ] Do not make exhaustion permanent: live recovery is part of the UI contract.

### I-04 — Bounded logger privacy and hot-path feedback

- [ ] Inspect HotPath detail strings: logs observed during the investigation
      included individual remap characters. Establish intended privacy policy
      before adding more detail; do not copy those payloads into reports.
- [ ] Test that warning-triggered synchronous flush cannot recursively amplify
      the slow-path event it is measuring.
- [ ] Throttle repeated failures by mechanism while retaining the first failure
      and an aggregate suppressed-count signal.
- [ ] Verify file/path diagnostics use redaction at the producer and remain
      bounded after parent aggregation. No secrets in test fixtures.

### I-05 — Native file receipt coverage still needs sibling review

- [ ] Audit CloseHandle/close outcomes in `FSWriteCreateDurable` and callers.
- [ ] Do not call this a data-loss bug without a concrete failing receipt path.
- [ ] Inventory buffered file writes outside the already corrected journal,
      SQL and logger owners; identify their final size/readback/native receipts.
- [ ] AHK File.Write and RawWrite small-buffer counts are not OS receipts. Use
      real LockFileEx denial and real short prefixes, with healthy controls.
- [ ] Inspect migration/TOML staging validators before claiming that buffered
      writes necessarily publish corrupt output: some have final readback guards.

## Completion and handoff acceptance

Tooling limitation discovered during delivery: `tools/audit/workflow.cjs`
accepts only `docs/audits/<scope>/<YYYY_MM_DD>/findings.json`. It refuses this
second-pass `handoff/` location. The earlier same-date evidence must remain
immutable; do not overwrite it or forge another date to satisfy validation.
Use this Markdown directly for the authorized implementation handoff. If machine
workflow support is needed, first design/test same-day pass identifiers in a
separate tooling change, including report discovery and commit attribution.
The supplemental JSON is not claimed to have passed the canonical validator.

- [ ] Every confirmed finding has a current reproduction or explicitly identified
      code-derived failure sequence, a root cause and a meaningful regression.
- [ ] Each implementation preserves unrelated user changes and native process/data
      ownership. No broad cleanup, no live-driver test launch, no silent fallback.
- [ ] Refactors preserve test-name sets and executed registration, not just counts.
- [ ] Each proposed deletion has survivor/mutation evidence and no lost guarantee.
- [ ] Full selected gates pass for each commit. Documentation-only checks do not
      certify a production fix; AHK tests do not certify shared JS contracts.
- [ ] Update each item with commit, exact commands, evidence and remaining limits.
- [ ] Keep hypotheses open until confirmed or refuted with reproducible evidence.
- [ ] Do not declare the whole driver bug-free after this checklist is exhausted.

## Coverage register and next audit passes

### Implementation progress and follow-up evidence

Completed commits must be inspected before reimplementing their findings:
`71a3fba19` (tree-owned native argument transport and private capture),
`2b8a9cd1d` (private synchronous capture), `56b124ff4` (worker diagnostics),
`6f45d9fd5` (append compensation fence), `3e37bc792` (SQL checkpoint guard),
and `34a588197` (durable fixture isolation). These receipts do not close the
entire cross-process capture or logger lifecycle matrices above.

- [ ] Native launch cleanup: `_SR_TreeCreateSuspended` adopts PROCESS_INFORMATION
      handles after closing inherited stream handles. If a stream close throws,
      cleanup has no process handle and can leave the suspended child behind.
      Adopt all returned handles immediately after successful creation, before
      fallible cleanup. Exercise an injected stream-close failure with a real
      suspended child; require that exact child to exit and no callback publish.
- [ ] Logger rotation with compensation debt: reproduce in
      `test_logger_native_write.ahk` using existing native prefix-write seams.
      Seed eight bytes, append four actual bytes of `BROKEN`, refuse truncate,
      then append `xyz` with a 16-byte cap. Correct result is thirteen bytes
      `12345678xyz\r\n`, no archive. Current source rotates the damaged file
      first, then repairs a newly created file to the old eight-byte boundary.
      The new `(logger-debt-rotation)` regression reproduced the premature
      archive on the unfixed code: one failure and one healthy control passed.
      Repair-before-rotation now passes both cases, including exact final bytes.
      Delivered in `2e027a732`. Retention and external path replacement
      still need separate coverage and repair-identity protection.
- [x] Logger shutdown with debt only: `_LoggerHasPendingDebt` did not include
      append compensation or active repairs. Inject a real partial auxiliary
      append, refuse compensation, keep queues empty, and attempt shutdown.
      Require bounded independent repair or explicit refusal; merely adding a
      debt check would make recovery impossible without another append.
      Delivered: the new
      `(logger-shutdown-append-debt)` cases both failed on the original code
      (false terminal success and surviving `priorBRO` bytes) and pass after
      independent repair was added. They cover native sharing denial, quiet
      recovery to exact `prior` bytes, active repair ownership and deferred
      forced flush. The full AHK run passed 5629/5630, with only the complete
      tooltip preparation timing failing (22.328 ms against 5 ms). Encoding,
      parse, e2e (5/5) and all 216 JS checks passed. A subsequent complete AHK
      run passed 5630/5630, including the strengthened metrics test. Rebased
      fix `fc3935356` is integrated into `dev`; the intermittent timing issue
      remains open rather than being dismissed because of that green run.
- [ ] Clipboard native admission race (hypothesis, not runtime-confirmed):
      `CB_RetryRestoreDebt` checks sequence before `CB_RestoreAll` assigns
      `A_Clipboard`. A concurrent external copy during native clipboard
      contention may be overwritten. Test with an isolated helper that holds
      the clipboard and publishes a synthetic successor before releasing it.
      Preserve the external clipboard fixture. If reproduced, admission must
      check sequence under the native clipboard lock; a second unlocked check
      is insufficient.
- [ ] Logger test quality: replace the assumed inaccessible `Z:` drive in
      `TestLogger_ErrorsWriteFailureDoesNotCrash` with a proven native denial;
      assert retained debt and successful retry, keeping its ring guarantee.
      `TestLogger_AllFlushSinksUseCompleteAppend` counts concatenated calls and
      needs per-sink runtime refusal/retry evidence before removing its guard.

The proposed logger split follows existing execution order: sink delivery,
queue ownership, append receipts, queue recovery, emission contract, retention,
observer sink, error sink. Move `_ResetLogger` to a support fixture and preserve
the initializers at their original include positions. Compare registered name
and callback sequences before/after, then use the existing suite transcript
manifest and recursive include coverage tools; do not add a second registry.

Additional test-quality finding: the complete tooltip preparation test compared
the lifetime `TooltipBorderPoolStats.reused` counter with 99, so the preceding
test's 100 hits could satisfy it. Integrated commit `caf57553a` snapshots and checks
the current case's delta. An isolated native mutation suppressed reuse-counter
increments and seeded the predecessor's 100 hits: the original guard accepted
`before=100 after=100` and its whole case passed; the delta guard rejected that
same faulty receipt. The probe checked the receipt before timing assertions to
attribute its failure; all timing thresholds remained unchanged. Disabling the
entire pool was also tried and was already detected by the latency assertion,
so that broader scenario is not claimed as a previously missed regression.

Final targeted comparison: a fresh, unmodified archive of `66ac5e761` passed
3/3, and the current worktree immediately afterward passed 3/3 (both native
exit 0, Normal priority). Earlier Normal/AboveNormal measurements passed 2/3
and 3/3 respectively, but were a single fixed-order pair under uncontrolled
load; they do not establish priority as the cause. Neither priority nor budgets
were changed. Full-run latency remains an open investigation, not exonerated
by either targeted pair. Logs: `ergopti_shutdown_final_verify.log`,
`ergopti_tooltip_clean_baseline.out`, `ergopti_tooltip_current_pair.out` in TEMP.

- [x] Replace `_MLH_WatermarkNeverOvershoots` source-token checks with native
      behavior in `test_metrics_and_locale_honesty.ahk`. The real
      `KL_Hook_AdvanceContextWatermarks` is now included by the runner; the
      source-only scope note was obsolete for this function. Its former test
      accepted one unclamped field as long as the other still contained `Min(`.
      Save both `KLHook` watermarks and restore them in `finally`. Seed distinct
      past values, assert exact small increments, then overshoot and repeat the
      compensation; both resulting fields must fall between the tick readings
      immediately before and after each call. Mutate each clamp independently
      in an isolated fixture to prove detection. Retain the separate producer
      routing guard. Delivered in `60276fae7`: the old guard passed with an app
      `Max` mutation; the new test rejects it and independently rejects a
      missing title clamp. Healthy focused cases pass 7/7; the full selected
      gate passes 5630/5630 plus encoding. No production clamp defect was found.

Logger identity investigation: reopening a remembered path with `a` can create
a missing file or truncate its replacement. Capturing the original handle's
`FSHandleSnapshot` triplet and comparing an existing-only reopened handle would
reject ordinary replacement, but cannot guarantee ownership after file-ID reuse
and strands debt when the original is renamed. Prefer evaluating transfer of
the original `FileObject` into the debt record, retaining the existing repair
claim and releasing ownership only after truncate/flush/close succeed. Native
tests must establish the actual sharing semantics, preserve replacement bytes,
and cover renamed-original recovery and missing-path non-creation. Account for
external writes allowed by the handle's sharing flags; retained identity alone
does not make those writes safe to truncate. The retained-object implementation
is committed in `89f587950`, with independent review finding no new regression.
The selected driver gates pass: encoding, full AHK 5632/5632, parse and e2e 5/5.
All 216 JS checks also pass. Native original-owner tests passed 0/2 before it:
a replacement became `unrel`, and a vacated path
was recreated. They pass 2/2 afterward, including repair of the displaced
original. Shutdown refusal/recovery passes 2/2 with a real mapped view denying
truncation; the former exclusive-open fixture no longer models this ownership.
Logs in TEMP: `ergopti_logger_original_owner_red.out`,
`ergopti_logger_original_owner_green.out`, `ergopti_logger_retained_shutdown.out`.
Keep same-path append reentrancy and shared external writes as separate open
ownership investigations; this fix does not claim to serialize those writers.

Native legacy transport commit: `672acf7a5`.
Current native transport verification: `--only shell-native` passes 8/8,
including caller-array mutation after handle construction; `--only
"UIA worker process"` passes 1/1 through the real native child and checks a
wrong root identity; `--only shellrunner-legacy` passes 29/29. The native launch
required updating UIA admission from wrapper-parent identity to exact root PID
plus the actual driver parent. The real worker regression caught this dependency.
Selected encoding, parse, e2e and 216 JS checks passed. Full AHK runs exposed
stale structural route inventories (corrected and replayed) and a tooltip
latency threshold. Targeted tooltip tests pass 3/3 both on an isolated `2b8a9cd1d`
archive and the corrected worktree; this does not explain or dismiss the full-run
latency failures. The final full AHK run completed with exit 0 and 5628/5628
passing; all selected gate components are now green. Preserve the intermittent
latency observation for controlled follow-up rather than lowering its budget.

Reviewed/revalidated in this handoff: native shell transport; metrics worker
exception boundary; the reverted cache experiment and persistence failure proof;
logger compensation return; SQL source guard; cache fixture cleanup; largest
test-file inventory; mechanical false-green ratchet; selected runtime logs.

The following are NOT exhaustively covered in this handoff. Each requires a
bounded module pass, followed by an end-to-end flow pass; list new findings with
the same proof contract rather than assuming a search hit is a bug.

- [ ] Boot/pre-init globals and native callback registration, valid-entry smoke.
- [ ] Every hook/InputHook/timer/OnMessage under suspend, pause and teardown.
- [ ] Remap and gesture modifier ownership across interrupted input sequences.
- [ ] Hotstring precedence, boundaries, case, group enable/disable and preview parity.
- [ ] LLM request/cancel/stream/recovery across reload and competing shortcuts.
- [ ] UIA password fail-closed state, worker restart and stale verdict ownership.
- [ ] Clipboard restoration and native UI/COM failure paths.
- [ ] Updater download/stage/admit/publish and cancellation at each native boundary.
- [ ] Config/TOML initialization, partial reads, rejected values and concurrent saves.
- [ ] Metrics date/time-zone/DST/range/app filters and no-data versus failed-data UI.
- [ ] Durable journal/SQL/cache shutdown, midnight rollover and crash recovery.
- [ ] Logger rotation/purge/exit debt and bounded debug-file ownership.
- [ ] Long-session memory, idle CPU and unbounded retained callback/state growth.
- [ ] Shared contracts affected by any later changes; macOS/Linux are not audited here.

Two consecutive no-new-finding passes have NOT been completed. This is an honest
handoff of confirmed defects and executable next work, not an exhaustive certificate.
