<!-- docs/audits/windows-2026-10-28/README.md -->

# Windows audit handover, 28 October 2026

The audit stopped at the maintainer's request. This handover preserves the
implemented fixes, their before/after evidence, and the unfinished findings so
that deleting the execution container does not discard the investigation.
All human-readable timestamps use Europe/Paris (CET on this date).

The authoritative final commit index is `report.json`. Each atomic fix records
its SHA, subject, bug and root cause, regression files, and proof packet. The
final integration and qualification receipt supersedes earlier checkpoint
status. `historical-report.json` retains the previous checkpoint without
claiming that its tests qualify a later head.

`evidence.tar.gz` contains original proof packets, complete atomic source diffs,
and recoverable snapshots of unfinished work. The archive includes its own
`SHA256SUMS`, `path-map.json`, and `wip/index.json`. Original proof JSON retains
its original paths and timestamps; `path-map.json` maps those paths to portable
archive members. Extract it beside this document, then verify its manifest:

```sh
sha256sum -c ARTIFACT_SHA256SUMS
tar -xzf evidence.tar.gz
sha256sum -c SHA256SUMS
```

`owned-windows.bundle` preserves local Windows branch history that may not have
been pushed separately. `bundle-receipt.json` records its exact refs, excluded
remote prerequisites, SHA256, and successful verification. The final pushed
`fix/windows` history and the recorded `origin/dev` provide its prerequisites.
In a clone containing those histories, inspect it before recovering local refs:

```sh
git bundle verify owned-windows.bundle
git bundle list-heads owned-windows.bundle
```

Unfinished work under `wip/` is research material, not approved production code.
Each snapshot records its base SHA, branch, status, staged and unstaged binary
patches, and complete captured bytes for changed or untracked files. Earlier
snapshots are immutable: a different dirty state receives a fingerprinted
follow-up folder, while `wip/final-status.json` separately records worktrees that
subsequently became clean. Do not
apply every snapshot together: several are earlier prototypes of the same fix.
Use the final commit index to distinguish integrated fixes from retained drafts.
The archive omits installed runtimes, package caches, credentials, and complete
duplicate checkouts. Its omissions receipt identifies any excluded large file.

## Remaining findings

1. **Crash-torn SQL ingest can acknowledge an unreadable ledger.** The actual
   public ingestion path was run against complete, torn-literal, torn-commit,
   fake-commit, and torn-UTF-8 predecessors. The healthy control passed and four
   interrupted cases failed on the original implementation. A resident full
   history scan was rejected after measured UI-blocking cost. The unfinished
   admission prototype uses detached validation, native identity and change-time
   certificates, and a short-lived exclusive append handle. Focused cases pass,
   but lifecycle transfer, cold-reload validation, and withdrawal of a lazy task
   remain unsafe or incompletely qualified. The latest four-case lifecycle run
   contains one healthy case, one real task-retirement failure, and two missing
   child receipts; those missing receipts do not prove their intended product
   failures. Preserve the canonical reader's `r-w` protection. Do not replace it
   with a permanent writable handle or a synchronous whole-history scan.
   Evidence: `evidence/scratch/windows-ledger-admission-r19/`, including
   `review.json`, `native-old-final/`, `native-group-qualification-r26/`, and
   `native-genuine-lifecycle-baseline-r26/`. Source: `wip/ergopti-windows-r19-ledger/`.

2. **Configuration restore can publish a substituted staging file.** The actual
   public restore path verified one file and later published different bytes
   after a pathname substitution. The separate integrated restore-authority fix
   prevents pending RAM saves from overwriting a backup restored through the
   Versions-page action. The low-level restore remains a disk-only operation;
   this does not close the staging identity race. A raw-copy prototype was rejected
   because it loses native metadata, streams, or encryption semantics. A pinned
   `CopyFileW` prototype still allowed a replacement ancestor to be written before
   identity refusal. Any successor must own destination creation and cleanup
   through ancestor/reparse changes without overwriting foreign files, and must
   preserve the native copy contract. Wine did not qualify EFS or alternate
   streams, and a read-only claim refused write-attributes access. Real Windows
   tests are required before accepting a replacement design.
   Evidence: `evidence/scratch/windows-restore-r22/` and
   `evidence/scratch/windows-audit-round6/delivery-review/restore-publication-identity/`.
   Rejected source snapshots remain under the restore proof directory.

3. **Uninstall can recycle a foreign replacement.** In the genuine public
   PowerShell removal function, the unregister callback moved the confirmed
   executable and installed a foreign replacement. The function returned success
   and selected that replacement for recycling. A healthy control passed. This
   is a host PowerShell 7 logic proof; native Windows PowerShell 5.1 and the
   physical Recycle Bin were not qualified locally. Another pathname hash leaves
   the same race; replacing recycle with permanent deletion breaks the contract.
   A future fix needs an identity-preserving removal/quarantine capability.
   Evidence: `evidence/scratch/windows-packaging-r30/uninstall-unregister-race-proof.json`
   and `uninstall-custody-design-review.json`. The exact macOS ordering differs;
   analogous Linux/macOS source leads are not native reproductions.

4. **Stored n-grams cannot distinguish literal bracket text from control
   markers.** Two real histories can produce identical encoded bytes, and valid
   literal n-grams disappear from the UI. A new versioned token representation
   and an explicit historical-data policy are required; the old intent cannot
   be reconstructed reliably from the ambiguous bytes.
   Evidence: `evidence/scratch/windows-audit-round6/ui-metrics/typing-bracket-ngram-review.json`.

5. **Native Windows builder validation has literal-path and schema defects.**
   Real PowerShell AST controls reproduced wildcard interpretation of bracketed
   directories and coercive manifest acceptance. Review-only source patches are
   retained. The tracked native binaries and fingerprints were not forged or
   manually refreshed. The official MSVC regeneration and native validation are
   still required before delivery.
   Evidence: `evidence/scratch/windows-audit-round6/delivery-review/builder-boundaries/`.

6. **Diagnostic archive acknowledgement remains intermittent.** Native Windows
   CI run `40709098135` failed one acknowledgement case. Run `40724503912` passed
   the full Windows lane with unchanged collector production and stronger
   refusal diagnostics. The cause is not established. The exclusive diagnostic
   namespace fix is separate and does not claim to resolve this failure.
   Evidence is indexed in the historical report and CI annotation packets.

7. **macOS optional callback regression can falsely accept `error(nil)`.** The
   complete original regression falsely accepts a genuine `error(nil)` thrown
   after the genuine `api_common` callback, because its no-throw sentinel checks
   only the nil error payload rather than the `pcall` status. The inspected test
   and producer match the recorded `origin/dev` checkpoint. This proves a test
   defect, not that `api_common` itself swallows the error. This is distinct from
   Windows empty-message errors; macOS source was left unchanged in this audit.
   Evidence: `evidence/scratch/windows-adapter-contract-followup/macos-nil-error-report-r29/`.

8. **Developer interpreter native qualification and an unproven harness lead.**
   The developer-interpreter selection correction is implemented and has genuine
   host PowerShell controls. Actual PowerShell 5.1 execution remains a
   Windows-runner requirement. The local native-entry test correctly rejected
   Wine's empty PowerShell stub and retained that failure. The final cancellation
   and editor-cohort caught-state guards have healthy/mutation proofs and are
   indexed as separate commits. Their broader 156-case Wine run retained three
   unchanged Ollama DELETE acceptance failures, whose cause remains unclassified.
   A personal-info void callback guard remains only an unproven lead; do not
   apply its proposal without a real original-path reproduction.
   Evidence: `evidence/scratch/windows-dev-interpreter-r34/` and
   `evidence/scratch/windows-final-r29/`.

## Scope and qualification limits

The final supplementary Wine meta/E2E batch is recorded in
`evidence/scratch/windows-final-native-qualification/qualification.json`, with
its exact held head, per-stage actual exit codes, complete TAP receipts, and
source manifests. It is separate from the earlier 156-case R29 guard cohort.
At source head `cc705f5ae4ae466469e80feb5c77b5ad825c3912`, meta produced
3,079 numbered results: 3,077 passed and two failed (system `tar.exe` launch and
invalid HKL). Nine existing brace-balance labels are reused for different source
paths. Although all 3,079 numeric IDs/results are present with no skips or
warnings, the strict unique-label parser therefore reports
`structurally_complete=false`; this is not a green or fully qualified meta run.
E2E produced 90 numbered results, with 89 passes and one native Unicode-erase
failure; its structural manifest is complete. Both failing exit codes and the
raw TAP remain unchanged. Earlier Wine evidence supplies context for these
boundaries, not an automatic passing classification.

The archive is created before the final shared JavaScript run and hosted
Windows dispatch; their final run identifier and result are supplied in the
delivery response and persist in the branch's GitHub Actions history.

Every qualification receipt names its exact tested head. A later archive-only
documentation commit can retain a source receipt only with explicit source-byte
equivalence; the final hosted run must qualify the delivered branch. A green
test from an earlier head does not qualify changed source. Wine evidence is useful for
real AutoHotkey parsing and many logic, native GUI, timer, file, and process
boundaries, but is not native Windows qualification. Local retained failures
include Unicode erase, missing system `tar.exe`, and filesystem identity/ACL
preconditions; comparisons against the same baseline are preserved where made.
No test was skipped or quarantined to obtain a green result.

Earlier cross-driver findings include genuine shared Lua rejection of escaped
request-schema keys and escaped pending-null successor keys, plus actual Linux
shell acceptance of malformed completion JSON. Both Lua drivers share the
inspected policy; macOS shell execution was not tested. Their exact historical
receipts and executable probes are preserved in the lifecycle proof packets and
`evidence/scratch/windows-audit-round6/delivery-review/control-cli-boundaries/`.
They remain unmodified in this Windows audit and require current-branch
reproduction before a different operating system is changed. Historical source leads and rejected fault injections are not promoted
to proved bugs.

The picker constructor ownership race is resolved by commit
`2b553eb9b40cf1d624ac5791c39b7ea99ae71416`, whose final integrated SHA is indexed
in the report. The original healthy control passed while both real native
reentrancy cases failed. The private 49-case cohort passed; after removing two
newly introduced cleanup catches so that native destruction failures propagate,
the exact final three registered regression cases also passed with normal
hooks and quick gates. The separate native teardown fix remains independently
covered. Full proof: `evidence/scratch/windows-picker-create-followup-r31/`.

The remote layout staging finding was resolved by native output custody and
retirement ownership, followed by explicit propagation of inline subscriber
failures. Its older unresolved checkpoint row is superseded by the final commit
index. The original seven-file protected-zone proposal was not applied as a
batch. Dev supplied the menu constant and five translations, then supplied the
same one-line JavaScript registration assertion correction independently made
on this branch. The final synchronization imports that upstream correction with
an identical tracked tree; gesture behavior, defaults, and the hotstring engine
were not changed by this assertion fix.

## Maintainer decisions

- Choose a versioned n-gram encoding and a historical-data migration policy.
- Identify the official MSVC environment to regenerate the builder outputs and
  verify their tracked fingerprints.
- Assign the remaining crash-torn ledger, restore-publication identity, and
  uninstall identity work with native Windows qualification. The archived
  rejected designs explain why small pathname-only patches are insufficient.
