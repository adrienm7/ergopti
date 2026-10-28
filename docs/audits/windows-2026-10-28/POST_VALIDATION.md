<!-- docs/audits/windows-2026-10-28/POST_VALIDATION.md -->

# Post-validation Windows corrections

The first hosted qualification of `3b33225970415794481337525e4cc23cb15f2922`
exposed a fixture dependency failure in Windows unit group
`hotstrings-shortcuts`: 1,679 tests passed and one failed. The failed job is
[123111092749 in run 40771445154](https://github.com/adrienm7/ergopti/actions/runs/40771445154/job/123111092749).
The same run also found a developer-CLI test receipt failure in
[core job 123111092631](https://github.com/adrienm7/ergopti/actions/runs/40771445154/job/123111092631):
1,941 tests passed and one failed. Exact annotations and source heads are
preserved; these failed qualifications are not results for the corrected source.

The isolated user-program shutdown fixture extracts and executes the genuine
shutdown handler. It omitted the newly mandatory
`LayoutRegistry_PrepareShutdown` dependency, so the actual handler caught an
undefined dependency and refused before program retirement. The correction
supplies that dependency in the isolated include graph without changing the
program-retirement assertion. The original failure was reproduced under the
real AutoHotkey interpreter before correction; the unchanged focused case then
passed 1/1 after repair.

Review of the same shutdown flow also identified a production refusal path:
the registry shutdown guard returned after navigation preparation but before
entering the compensation `finally` block. A refused registry shutdown could
therefore leave navigation prepared after exit was vetoed. False, Error and empty-message Error refusal controls failed on the original
code while both healthy controls passed. The corrected focused cohort passed
5/5, and the complete user-program cohort passed 17/17. The registry gate now
runs inside both existing compensation scopes, preserving exact configuration
bundle and navigation ownership. The proof executes genuine shutdown/reload
bodies and ProgramActions_Stop in AutoHotkey under Wine; surrounding navigation
and configuration owners are faithful stateful ports, with no physical Windows
DLL or keyboard-hook qualification claimed.

The second hosted failure came from PowerShell 5.1 test serialization: the
explicit-missing interpreter case reported a correct refusal, but serialized
its selected-null receipt as `{}`. The JavaScript assertion correctly rejected
`{} !== null`. The correction uses one canonical JSON null receipt producer
across PowerShell versions; it changes no interpreter-selection policy, adds no
version branch, and keeps the strict-null and all eight complete entry checks.
Four direct value controls supplement the original 17 host checks: literal
null, an actual empty pipeline, `AutomationNull.Value`, and a nonnull path. The
exact wrapper type on the first Windows runner was not captured; the controls
do not assert that AutomationNull was its independently diagnosed type. Actual host
PowerShell 7.5.2 controls passed 21/21. Corrected-head native PowerShell 5.1
qualification remains pending.

The complete original 160-commit index, initial evidence archive, and initial
Windows branch bundle remain unchanged. `post-validation-evidence.tar.gz`
supplements them with both failed hosted jobs, the first batch's actual 531/531
shared-test receipt, the three bounded corrections and regression results, and their
integration receipts. Raw packets retain their original bytes; the readable
summary uses Europe/Paris timestamps.

The corrected batch still requires its own complete shared test run and hosted
Windows qualification. Focused AutoHotkey evidence under Wine does not claim
native Windows qualification. The delivery response supplies the final run ID
and conclusion; the branch's GitHub Actions history remains authoritative.

## Urgent stop and unresolved keymap qualification

The maintainer requested immediate termination before container deletion. Only
three completed corrections are included. The corrected batch did not receive
a new full shared test run or native Windows CI dispatch. CI is **not green**.
The original run completed with failure at the last observation on 28 October
2026 at 23:18:40 Paris. Its three failed unit groups are core,
hotstrings-shortcuts and keymap; aggregate verdict failures follow from them.
The UI group passed. No corrected-head CI run was started after the stop.

[Keymap job 123111092632](https://github.com/adrienm7/ergopti/actions/runs/40771445154/job/123111092632)
reported 1,386 passes and 21 failures. No fourth production correction is
claimed. Read the two archived `STOP_HANDOVER.md` notes before resuming:

- Nine custody failures compare busy activity at a raw temporary path with a
  download owner's authoritative canonical `Owner.Path`. Source review
  establishes this coordinate mismatch. The shared `FileReadActivityKey` is
  deliberately lexical and publishes before native I/O; do not add a dual-alias
  shim or filesystem resolution to it. Actual short-path causal execution was
  not completed.
- Two late-completion fakes write new bytes after `Abort()` has acknowledged
  quiescence. That violates the real transport's acknowledgement contract.
  Model queued readiness after acknowledgement without another write. Preserve
  an independent foreign-file replacement control; never restore blind deletion
  to make these cases pass.
- Teardown drops queued polls and callback bookkeeping before the live successor
  owner retires. Leaked global read activity can explain the later eight
  configuration-scope refusals, but the native cascade remains unproved.
- A separate raw/canonical path mismatch in configuration bundle selection is
  also an unproved alternative. The peer did not finish inspecting downstream
  borrowed-owner selection. Do not label all eight failures as cascades.

One unqualified test draft is saved with its exact bytes, index/worktree
patches, base SHA and branch in
`post-validation-evidence/evidence/windows-final-registry-path-proof/`.
There are no untracked draft files or production changes. Its native job was
never submitted. The peer performed source review only. Preserve these limits.

## Resume from a fresh checkout

Clone `github.com/adrienm7/ergopti`, fetch `fix/windows`, and create a local branch
from its remote tip. Read `AGENTS.md`, the routed Windows memory, and the driver,
ship-fix, verify-change, false-green-tests and commit-and-push skills. Use Node
22.22.2 as pinned, run `npm ci`, then `npx husky install`; never bypass hooks.

Verify the original and supplemental archive checksums. The supplemental bundle
contains the completed original source branches; its prerequisite is the pushed
`3b33225970415794481337525e4cc23cb15f2922` baseline. The registry draft branch
also starts at that baseline, already reachable from the delivery history.
Recreate a separate worktree at that exact base, apply the archived binary
working-tree/index patches as appropriate, and compare every restored file with
`STOP-manifest.json`. The draft is research material, not a ready fix.

Use real Windows, the pinned AutoHotkey 2.0.26 and native Windows PowerShell 5.1
for authoritative qualification. Linux PowerShell 7 host checks and AutoHotkey
under Wine supply narrower logic evidence; Wine's empty PowerShell executable
is not qualification. Retain all genuine failures.

For a Linux execution container, the previous host used Lua 5.4, real PowerShell
7.5.2 and Ruff 0.15.8 alongside pinned Node 22.22.2. Run as a non-root user with
`USER` and `LOGNAME` set; the shared gate rejects a mismatched host. The old
`/workspace/toolchain/env.sh` and installed runtimes are not repository files.
Recreate your own tool paths while preserving the managed proxy, CA trust and
injected authentication; no credential or environment dump is archived.

The narrower AutoHotkey probes used Wine 9, Xvfb and the official AutoHotkey
2.0.26 x64 runtime. Tests that launch Windows `node` or `git` additionally used
the Windows Node 22.22.2 distribution and MinGit 2.56.0.4 on `WINEPATH`. Use one
owned `WINEPREFIX` and serialize native runs. Follow the repository's
`tools/test/run-ahk-under-wine.sh` interface; do not recreate the discarded
parallel lane without qualifying its process ownership. None of this replaces
the native Windows PowerShell 5.1 and Windows CI requirements above.

First run the eight configuration-scope cases alone in a fresh process. Then
run the two late-completion cases followed by those eight in another process,
recording owner counts before and after cleanup. Separately prove genuine
short-name/long-name file equivalence using Win32 APIs and compare raw paths,
`Owner.Path`, lexical keys and native file identities. Repair faithful fixture
completion and exact-owner teardown before assigning a production cause. Then
run the complete keymap cohort and the normal full Windows lane.

Keep hotstring engines, tap-hold thresholds, gesture behavior, recommended
settings, model-browser work, workflows and protected CI tooling outside this
follow-up. Preserve current dev behavior during a normal merge; never rebase or
force-push this delivery. Push only `fix/windows`, never `dev` or `main`, and do
not open a pull request. Existing audit TODOs still apply.

Concrete checkout commands, after installing the pinned Node and Git:

```sh
git clone --branch fix/windows https://github.com/adrienm7/ergopti.git ergopti
cd ergopti
node --version
npm ci
npx husky install
cd docs/audits/windows-2026-10-28
sha256sum -c ARTIFACT_SHA256SUMS
sha256sum -c POST_VALIDATION_SHA256SUMS
tar -xzf post-validation-evidence.tar.gz
git bundle verify post-validation-evidence/post-validation-owned.bundle
cd ../../..
git worktree add ../ergopti-registry-resume -b windows/registry-resume 3b33225970415794481337525e4cc23cb15f2922
git -C ../ergopti-registry-resume apply --check ../ergopti/docs/audits/windows-2026-10-28/post-validation-evidence/evidence/windows-final-registry-path-proof/STOP-working-tree.patch
git -C ../ergopti-registry-resume apply ../ergopti/docs/audits/windows-2026-10-28/post-validation-evidence/evidence/windows-final-registry-path-proof/STOP-working-tree.patch
```

`node --version` must print `v22.22.2` before installing dependencies. The draft
index patch is empty and there are no untracked files. Its restored custody
fixture must have SHA256
`4007e997168c7d8e0324f23b2ed79571da03d80616550957ccf2bb06ee3f7387`.
Do not treat applying that test draft as a qualified correction.

## Integrated fixes

Source checkpoint: `0d524fa308358dc54fcca497686ce90411ef2d21`.

- `a2fc97973e4f2d9a67e384a7b2b3e92006401cb3` fix(test): include registry shutdown in the program envelope
- `2ad1daa5405a2ab9dada5cef2a1212933e6a3f5d` fix(windows): resume native admission after registry refusal
- `0d524fa308358dc54fcca497686ce90411ef2d21` fix(test): serialize absent interpreter choices as null

Verify and extract the supplement in its separate namespace:

```sh
sha256sum -c POST_VALIDATION_SHA256SUMS
tar -xzf post-validation-evidence.tar.gz
cd post-validation-evidence
sha256sum -c SHA256SUMS
```
