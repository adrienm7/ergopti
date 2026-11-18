<!-- docs/audits/windows-2026-10-28/README.md -->

# Windows audit handover, 28 October 2026

Post-validation update: the first hosted run exposed two fixture failures and
review of the same shutdown flow proved one production compensation defect.
See [POST_VALIDATION.md](POST_VALIDATION.md) for the three saved corrections, the unresolved 21 keymap failures, urgent-stop
recovery instructions and exact before/after evidence. The original
160-commit index and binary archives remain historical and unchanged; the
corrected batch remains unqualified: work stopped before new full shared or
native Windows CI runs at the explicit urgent stop request.

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

Status on 18 November 2026: seven of the eight findings are fixed, each with a
regression test that fails on the code the audit read. Finding 5 still needs
its native binaries rebuilt by the maintainer. The original descriptions and
evidence paths stay in `evidence.tar.gz` and in Git history.

1. **Crash-torn SQL ingest could acknowledge an unreadable ledger.** Fixed by
   `aa1650f51b`: `state.json` now records the ledger's identity and its
   acknowledged length, so boot cuts an interrupted append in O(1) and the
   journal writes those events again. The admission prototype with a writable
   handle or a full history scan was not adopted. Regression:
   `windows/tests/unit/modules/keystats/test_keystats_torn_ledger_tail.ahk`
   (torn literal, torn commit, fake commit, torn UTF-8 and complete control).

2. **Configuration restore could publish a substituted staging file.** Fixed
   by `cd47844355`: the stage and its folders are held by handle from the
   first open to the last close. The stage is copied by handle with
   `BackupRead`, so it keeps the attributes, write time and encryption that
   `CopyFileW` copies, and renamed with `FileRenameInformation`. Regression:
   `windows/tests/unit/modules/updater/test_config_restore_custody.ahk`, with
   a separate same-user attacker process (`fixtures/restore_stage_attacker.ahk`).

3. **Uninstall could recycle a foreign replacement.** Fixed by `4c9448cf7a`
   (maintainer decision of 2026-11-11 in `docs/memory/maintainer-decisions.md`):
   the confirmed executable is renamed to a private quarantine name under an
   identity anchor and recycled only when the Recycle Bin holds that identity.
   Regression: `tools/test/test-windows-uninstall.cjs`.

4. **Stored n-grams could not tell literal bracket text from markers.**
   Resolved by token encoding 2 (`211e7ec7ed`, maintainer decision of
   2026-11-01): a typed `[` is escaped as `[[`, and Windows and macOS rebuild
   every key from the raw events, keeping the old image as a backup.

5. **Native Windows builder validation had literal-path and schema defects.**
   Fixed in source by `7313d78d00` (literal `Push-Location`, strict nav owner
   schema), `ff8610fb53` (the `[long]` PowerShell 7 parses) and `850bf7c1ca`
   (the same integer check on the five version guards of the PAC and Lua
   export builders). Regression: `tools/test/test-windows-builder-boundaries.cjs`.
   Left to the maintainer: rebuild the tracked native binaries and their
   manifests in the official MSVC environment. The PAC source fingerprint
   covers the builder scripts, so `vendor/ergopti_network_pac.json` predates
   these edits until that rebuild.

6. **Diagnostic archive acknowledgement was intermittent.** Fixed by
   `698b2cf2aa`: the worker's exclusive rewrite of `progress.json` met the
   host's progress read and failed with a sharing violation before the ZIP.
   The rewrite now retries a sharing or lock violation for 2 s. Regression:
   `tools/test/test-windows-diagnostic-progress-reader.cjs`.

7. **The macOS optional-callback regression accepted `error(nil)`.** Fixed by
   `df467c0da1`: the test now reads the `pcall` status, not only the payload.

8. **Developer interpreter native qualification and a harness lead.** The
   selection fix is in `tools/dev/run-windows-dev.ps1` (an explicit
   interpreter is authoritative). On 18 November 2026,
   `node tools/test/test-windows-dev-script.cjs` ran on native Windows
   PowerShell 5.1.26100 with 21 checks passed and `native_entry_cases=8`, the
   qualification Wine could not provide. The personal-info void-callback lead
   is closed by `b92cceef52`, which proved it on native Windows. The three
   Ollama DELETE failures only appeared under Wine: the native run of the
   whole suite on 11 November (20,286 tests,
   `docs/audits/windows-2026-11-11-todo-triage.md`) had no Ollama red.

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

- Identify the official MSVC environment to regenerate the builder outputs and
  verify their tracked fingerprints (finding 5).
- The n-gram encoding and the restore custody (2026-11-01) and the uninstall
  identity (2026-11-11) are decided; see `docs/memory/maintainer-decisions.md`.
