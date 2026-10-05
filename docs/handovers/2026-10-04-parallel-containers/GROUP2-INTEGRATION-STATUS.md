<!-- docs/handovers/2026-10-04-parallel-containers/GROUP2-INTEGRATION-STATUS.md -->

# Group 2 integration checkpoint

The hotstring source candidate is `0649967eae35cf9c3f368051ad8cbbc44dc15539`
on `feat/hotstrings`. It contains the shared/macOS/Linux implementation and
prepared Windows sources for TODO 34/37/102/104/105. All five parent items remain
partial; no item was removed. Items 16/38 remain byte-identical to the current
`origin/dev` baseline `02ad69e06ecea424de11facf3dced404a6fdd602`.

Windows-dependent implementation and qualification were explicitly deferred to
the maintainer PC. Follow [the Windows continuation](GROUP2-WINDOWS-TODO.md);
in particular, TODO 34 still needs the actual Windows custom terminator-record
consumer/editor. Existing delimiter strings are not that implementation. Before integration,
continue on the published feature source SHA above; the old dev baseline does
not contain these features. After integration, qualify the actual integrated SHA.

## Published corrections

- `eea838e2d`: preserve explicitly ordered hotstring records in the formatter,
  retaining decoder equality and the unmarked formatting contract.
- `5a077157a`: source-owned personal controls, common-family migration and
  programmable hotstrings, with the clean shipped-pack relocation.
- `caa1ef045`: provision native LuaFileSystem in Linux unit fixtures.
- `c04072754`: keep the actual Linux entry within the portable ceiling of 60 upvalues;
  strengthen the existing compiled-function budget guard on LuaJIT.
- `0649967ea`: provision native LuaFileSystem before the Linux scripted daemon
  E2E harness, retaining every source/admission and assertion boundary.

## Exact validation

Local selected gates pass format, JS 358/0, macOS portable units 14,358/0,
Linux units 6,892/0 and scripted E2E 188/0. The macOS stub E2E result is 101 passed,
zero failed and one skipped. These are portable/scripted results, not native
Windows or physical macOS acceptance. Actual local X11 source and libuv/curl
streaming/owner-settlement controls also passed. AHK BOM/LF checks cover 1,830
files; no actual AHK runtime or compiled Windows probe was run here.

The Linux dependency proof uses the unchanged 188-assertion harness. With
neither actual filesystem provider it gives 166 passed/22 failed, including
byte-identical hosted failure receipts; actual LuaFileSystem alone gives 188/0.
Actual libuv alone also gives 188/0. No source or assertion was rewritten and
no native provider was replaced with a stub.

Manual [Linux CI 37266856722](https://github.com/adrienm7/ergopti/actions/runs/37266856722)
tests `b85d3f6ad5e6c24fbec05bdbc01d09fad866d432` on owned
`codex/ci-hotstrings`. Its tree `28f5220fab04cce6db2c0faf8860b65842eb8885`
is identical to source candidate 0649967ea. Its final result is recorded below.

The run is terminal **failed**. Core JS 358/0, core properties, Linux units 6,892/0
and the scripted keyboard harness 188/0 pass. Native GTK gives 3/4 passed
(ordinary-app did not launch); updater validator association gives 5/6 passed
(HTTP-error changed its prior validator); native audio gives 2/6 passed
(fr_FR/de_DE gettext catalog not active); notifications give 0/12 passed
(caller text changed native urgency). Linux package and installation are skipped.
Windows, macOS and Release are skipped in this Linux-only correction run.
The unchanged mandatory verdicts remain failed; no archive/install success is
inferred from passing unit or scripted tests.

Manual [macOS/Linux CI 37262961306](https://github.com/adrienm7/ergopti/actions/runs/37262961306)
at `db5c95f40ac4c005be434e0797b95611a575c0b3` tests the exact source tree of
`caa1ef04599650be3fa841ae577a58cc322a061a`. It is terminal failed. Portable macOS
units 14,358/0 and stub E2E 101/0 plus one skip passed. Native Swift executed 308
cases, with seven failure assertions/two unexpected across the Homebrew
AppleEvent-receiver and Sparkle process-census/server-retirement methods.
Native package completion and installation were not qualified. Its Linux
6,886/4 entry/CLI regression was causally fixed by c04072754 and the corrected
hosted Linux unit suite passes 6,892/0.

## Required continuation

- Keep native GTK, updater-validator, audio-locale and notification corrections
  under their current owners. Obtain bounded reviewed fixes and native receipts;
  preserve every existing assertion and refusal/retirement requirement.
- Group 6 retains Homebrew/Sparkle archive acceptance. Its latest inspected run
  [37263453529](https://github.com/adrienm7/ergopti/actions/runs/37263453529) at
  `9a95d5ce4bb20179a1e01860c07eed1231eaf8b2` still fails those two methods:
  309 Swift cases executed, six failure assertions/two unexpected. Those
  unqualified archive patches have not been imported into this feature.
- Fetch actual `origin/dev`, merge subsequent changes without losing owners,
  and requalify affected final sources. Only final integration owns
  `codex/ci-lock` plus `codex/ci-validation`; preparatory CI uses its own branch.
- Reserve the final lock through an empty commit from the latest origin/dev
  naming group, branch and candidate SHA, pushed without force. An existing
  lock blocks reservation. Merge without squash/no-ff, immediately push dev,
  cancel exact-SHA automatic workflows and let manual integrated CI finish.
- Confirm all feature commits are in origin/dev and that required integrated
  qualification passed before deleting only feat/hotstrings. Its owner alone
  deletes the lock after terminal CI. No release is authorized by these tests.

No final lock was acquired, no shared validation branch was moved, no dev
merge/push occurred and the feature branch remains published. The original main index with 307 staged paths and unrelated working files were
preserved. All prepared product corrections are committed; retained local evidence is supplementary
and never substitutes for the missing native/Windows qualification.
