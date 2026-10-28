# Linux audit closeout, 28 October 2026

This archive preserves the completed Linux audit work and the known outstanding
items before the execution container is deleted. All times use Europe/Paris.
The audit is closed at the user's request; it does not certify that every bug
has been found or that physical keyboard behavior has been validated.

The fix branch is `fix/linux` in `adrienm7/ergopti`. Only that branch is authorized
for publication. The final upstream integration includes dev
`18d69a24c06586186a221c1afb5ce703732ac4a1`. Earlier dev commit
`42acb5cdcf2c027925a672b94b30bcbc79bccc34` already contained both narrow
repairs authorized by the user: five gesture-information captions and the
Windows generated command constant. No duplicate local patch was applied.
No gesture engine, default recommendation or timing threshold was changed for
these two repairs.

## Fixes and regression evidence

[COMMITS.md](COMMITS.md) provides a readable bug, cause, proof and test list
for every atomic commit. [The machine catalogue](fix-catalogue.json) lists all
30 atomic audit commits with
full SHA, English subject, bug, root cause, regression proof, changed test files
and OS scope. These include test-infrastructure repairs and comments-only gate
repairs; they are not 30 independent production defects. Normal upstream merges
are excluded from the atomic-fix count.

[evidence.tar.gz](evidence.tar.gz) contains the selected original receipts and
old-red/new-green diagnostics. [The manifest](evidence-manifest.json) records
archive paths, original provenance paths, sizes and SHA-256 digests. Extract
with `tar -xzf evidence.tar.gz` and use archive-relative paths from that manifest.
Identical file contents may use standard tar hardlinks to earlier members;
every logical file is readback-verified against its own size and hash.
The archive also contains 32 original Linux-native proof receipts in a nested
verified archive, with its manifest and retained-profile inventories. Cleanup
was conservatively deferred where exhaustive reader observation was unavailable;
the recorded retirement decision does not claim those profiles were deleted.
Original workspace paths inside historical JSON are provenance only: they will
not remain accessible after container deletion. The permanent regression tests
and all implementation commits remain in Git.

## Qualification and hosted CI

The final integration qualification is recorded separately in
[closeout-status.json](closeout-status.json). That status must distinguish actual
runs at a source SHA from earlier source-scoped evidence. Pending or skipped
commands are not passed commands.

Final Linux qualification on source
`d80243b30d3647e07e1290e7430c0a18eea8afeb`, tree
`2521d1ab5297f82342a6be9546391346bd3c63c5`, completed at
**21:12:01.951995 Paris on 28 October**. All **14 commands exited 0**, source
integrity was verified across 12,841 tracked files, and results were
**19,841 tests passed, zero failed**, **302 E2E passed**, full-output reporter
**zero failures and zero timing errors**. Native HTTP **18 plus 30** and native
descriptor **12 plus three real path controls** passed. The archive includes
the terminal receipt, original raw outputs, complete reporter JSON and source
inventories. Common qualification remains separate and is not implied by these
Linux results. The conventional merge-subject amendment produced
`9b3f03f3ba9a202f69e4f7dcc248541b9092fad2` with the exact same tree. These
results qualify that source tree; they do not claim an execution on the later
archive-documentation commit. The tested commit's raw payload and recovery
metadata are archived under
`evidence/dev-merge-20261028/closeout-20261028/tested-source-commit.txt` and
`tested-source-provenance.json`. To restore the tested commit object in a clone
containing `9b3f03f3ba9a202f69e4f7dcc248541b9092fad2`, run
`git hash-object -t commit -w` on that extracted text file; the resulting SHA
must be `d80243b30d3647e07e1290e7430c0a18eea8afeb`. Its tree and parent objects
are reachable through the retained metadata-only replacement, so removing the
local validation worktree does not lose source provenance.

A later terminal Common run exposed one remaining inherited test-premise defect:
check 487 still required the retired raw Windows gesture command string. That
actual d802 run ended at **21:23:29 Paris**, exit **1**, with **529 PASS and
1 FAIL** across all **530 checks**. The single existing native-AHK host case
was explicitly not executed on Linux; this is not native Windows evidence.
`b49ab43c850467e914ddebf0b8259c57b3590451` changes only the registration regex
in `tools/test/test-recommended-defaults-rule.cjs` to follow the generated
constant already used by production. The direct test was red before the edit
and green afterward; seven targeted gates and normal hooks passed. The corrected
composition then passed a fresh whole Common run, qualified separately below. The archive
retains the original complete red run rather than relabeling it successful.
The only source-path difference from the Linux-qualified d802 tree to b49 is
that one Common test file. Linux, shared data, Linux runners and production
code remain byte-identical; the Linux subtree object is
`eff5229a8c4ad8bb7b214e5c6f83ca1e7eed77ef` in both. This component identity
supports the existing Linux results without claiming a new full Linux
execution at b49.

The corrected full Common run at
`b49ab43c850467e914ddebf0b8259c57b3590451`, tree
`66d7a8744e68726c860b7c7d63ed962d485f5ef4`, completed at
**21:44:03.989111 Paris on 28 October**: **530 of 530 registered checks passed,
zero failed, exit 0**. Source identity, file modes, index, HEAD, working-tree
status and the dependency cohort were unchanged. The archived terminal
receipt, full raw output and before/after inventories preserve this result.
One existing native-AHK host case was explicitly **NOT EXECUTED** on Linux;
it is not counted as a native Windows success. There is no remaining pending
local Common run. Hosted CI is a separate post-publication step, and its status
is not inferred from these local results.

Before publication, the latest dev guard correction was merged normally as
`adccf8b5dc4b55dafc21dda1d1fe7a3f20b9d7ff`. Its complete source tree is
exactly `66d7a8744e68726c860b7c7d63ed962d485f5ef4`, identical to the corrected
Common-tested b49 tree: upstream independently made the same one-line test
repair. The archive includes both the pre-commit merge comparison and the
post-commit Git verification. The future archive-documentation commit adds
these reports; no full local test execution at that documentation commit is
claimed. Hosted CI will test the published composition.

Historical qualified Linux source `13f2d9b584a40f0ba226eb973a3a885cd639f245`
completed 14 canonical commands at 18:24:45 Paris: 19,841 tests passed, zero
failed; 302 E2E passed; the full-output reporter admitted the complete output
with zero failures and zero timing errors. Native HTTP controls (18 plus 30),
native descriptor controls and false-green checks passed. Later upstream and
package changes require the final composition qualification recorded in the
status file rather than automatic transfer of this source's result.

The historical 530-check Common run on that source actually finished with
527 passes and three failures. One was the missing npm alias, fixed by
`5d0bf5fbb44f972b40494d99672b2c34a32e3f3f`; the other two were inherited gesture
captions and the Windows command literal, subsequently fixed in dev. Its npm
wrapper was killed during an environment restart; the surviving Node body and
shell supplied the actual failure. No killed wrapper is credited as successful.

The last hosted CI known before closeout publication was
[40424391590](https://github.com/adrienm7/ergopti/actions/runs/40424391590),
completed **failure**, at old published SHA
`fe2413797f34653c93d0ed0ad10252cae043994b`, 27 October 01:07:55–01:28:32 Paris.
It does not qualify the current fixes. The final workflow dispatch follows the
archive commit and push; consult the recorded final run or the
[fix/linux workflow history](https://github.com/adrienm7/ergopti/actions/workflows/ci.yml?query=branch%3Afix%2Flinux)
for its actual SHA, run ID and outcome. No current CI success is implied here.

## Outstanding TODO and maintainer questions

1. **Confirmed Mac production path bug:**
   `macos/modules/llm/network_env.lua` normalizes POSIX backslashes into slashes
   while locating the driver root, losing a real checkout's policy/receiver.
   The archive retains the real filesystem reproduction. This Linux campaign
   did not change the Mac production owner. Locate the module by the archived
   proof if its path has moved in dev; preserve path bytes at the POSIX boundary.
2. **Confirmed Mac MLX fingerprint bug:** filename-mode `shasum` can prefix an
   escape character for backslash-containing names. Taking the first awk field
   then admits the escaped digest with the wrong value/width in
   `macos/modules/llm/ensure-mlx-deps.sh`. The genuine
   producer proof is archived. This Linux campaign leaves the Mac production
   owner unchanged; no speculative cross-OS patch was applied.
3. **Unresolved portable Mac CPU failure:** the full portable Hammerspoon suite
   at source 13f reported 25,331 passes and one failure in
   `test_ledger_replay_bounded`, maximum per-step CPU 71.2 ms versus the unchanged
   20 ms limit. One isolated case also failed around 30 ms. A genuine unmodified
   dev463 baseline control passed its one case; it did not print the numeric
   per-step maximum. Component files were identical across the inspected
   sources, but causality remains unresolved. Do not classify this as a proven
   pre-existing defect, environmental flake or branch regression. Full-suite
   case elapsed time is not the per-step CPU measurement. HS E2E and reporter
   stages after this failure were not executed. No threshold or test was
   weakened. Which Mac owner/hardware can localize the cost?
4. **Unproved Mac candidates:** updater cadence may ignore timer receipts, and
   another MLX download path may normalize POSIX names. These are static leads,
   not demonstrated runtime defects. Keep them separate from confirmed bugs;
   reproduce before correcting.
5. **Linux physical acceptance remains required:** native HTTP, inotify,
   descriptor, CLI and filesystem receipts do not establish physical
   evdev/uinput grabs, polkit prompts, session autostart, real application
   injection or Wayland/X11 behavior. Which machine/session can run the
   repository's hardware tests? No native Windows or Mac qualification is
   claimed from static/model tests on Linux.
6. Base-layout Python controls ran on Python 3.12.14: 176 executed passes and
   14 existing xkbcli-dependent unexecuted cases. Python 3.8 floor checks were
   structural, not a native Python 3.8 run. Retain the CI/distro requirement.

No new audit search is planned after the known fixes, their final validation
and publication are finished. Unresolved findings are intentionally preserved
here rather than in the separately reserved maintainer TODO documents.
