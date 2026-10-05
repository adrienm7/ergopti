<!-- docs/handovers/2026-10-04-parallel-containers/GROUP2-INTEGRATION-STATUS.md -->

# Group 2 delivery and device continuation

The last published composition is `880d3a5a9cd8bf87ca3430ac5a895d67ba81449f`
on `feat/hotstrings`. It contains the shared/macOS/Linux implementation and
prepared Windows sources for TODO 34/37/102/104/105. All five parent items remain
partial; no item was removed. Items 16/38 remain byte-identical to the latest adopted
`origin/dev` baseline `a550193ebc31aa819c369f701a61ebed72d86216`.

Windows-dependent implementation and qualification were explicitly deferred to
the maintainer PC. Follow [the Windows continuation](GROUP2-WINDOWS-TODO.md);
in particular, TODO 34 still needs the actual Windows custom terminator-record
consumer/editor. Existing delimiter strings are not that implementation. The maintainer now explicitly requests advancing dev with all feasible container
and CI work, documenting genuine remaining device/foreign-owner work and deleting
the feature after integration. This permits delivery with reported native failures;
it does not convert those failures into acceptance. After integration, qualify
the actual dev source SHA. See [device and native continuation](GROUP2-DEVICE-TODO.md).

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

- `1cb339207`: merge the current dev, retaining all published Linux corrections.
- `d561cbf57`: install actual audio translation catalogs and require observed native
  notification urgency-rule receipts, with an independent wrong-rule rejection.

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

## Subsequent native prerequisite qualification

The selected d561cbf57 gate passes formatting, all 359 JS checks, Linux units
7,607/0, actual X11 source controls and actual libuv/curl streaming/retirement.
The JS count includes the subsequently integrated Linux owner's additional gate.
The unchanged native audio fixture passes six/zero on both LuaJIT and Lua 5.4
with actual French/German PulseAudio catalogs, versus six/four without them.
The Ubuntu runner now installs its two language packs. Original native GTK
application operands pass four/four locally; no GTK assertion, deadline or source
was changed. This does not explain the earlier intermittent hosted failure.

The original notifications pass twelve/zero on actual Dunst 1.12.2. The corrected
fixture preserves every vector and exact literal-text/application/timeout check;
actual urgency rules classify native receipt categories independently of expected
inputs, and history urgency is additionally checked when exported. Its actual
wrong-rule negative control is rejected; all thirteen checks pass locally.
Debian Dunst 1.9.0 lacks the required ClearHistory method, so its failed local
probe does not qualify Ubuntu Dunst 1.9.2. Manual [37274473330](https://github.com/adrienm7/ergopti/actions/runs/37274473330)
at `3321b957fb5465be57b810841c686b27fb5e23c2` is terminal failed, but
confirms audio six/zero on each interpreter, notifications thirteen/zero and
unchanged GTK four/four. Its tree is exactly d561cbf57. Core JS/properties and
Linux units pass. Twelve native E2E steps fail: seven shared-module import
prerequisites, three missing xkbcli controls and two distinct HTTP-owner controls
(POST NUL body dispatch acknowledgement, HTTP503 ETag). Packaging/installation
are skipped and Release/Publish skipped. The next bounded workflow correction
provides the real XKB compiler and shared Lua namespace before their first use,
retaining all original fixtures. Actual local XKB gives64/0+72/0+64/0; absence
reproduces the exact hosted line83 refusal. Hosted final confirmation is pending.

## Final source composition

The source adopts current dev a550193 without discarding the configuration/menu
owner's publication inverse. Private hotstring table receipts and ordinary
configuration cleanup callbacks retain their separate native owners. Actual
Dunst1.12.2 and1.9.0 each pass13/0 after composing typed D-Bus byte validation,
exact notification operands and the independent wrong-rule refusal. The six new
configuration/menu ETag controls remain; a seventh restores the original E2-on-503
counterexample with the unchanged canonical E1 expectation. Actual Curl8.14 passes
all seven modes on both Lua ABIs. Supported older Curl still needs hosted proof.

The selected composition passes Linux7,805/0. Mac portable units give14,648/12;
all twelve failures reproduce the already integrated dev baseline. The independently reviewed follow-up passes formatting, JS359/0 and the full
Mac portable suite14,662/0. It fixes three explicit fixture dependency inventories and the JSON stub's
missing b/f byte escapes. Production strict validation and independent golden
corpora remain unchanged. Two new independent controls first give1/1 against the
old stub, distinguishing decoded control bytes from literal backslash examples.
Final full-suite and integrated hosted results are recorded in the coordination
receipt; neither the earlier red nor an unexecuted device scenario becomes green.

The final phase was reserved using an actually empty commit from current dev,
not by taking a foreign reservation. Its owner keeps both CI refs serialized
through the terminal manual result. Shared changes select all three native OS
lanes. Remaining Windows implementation and physical acceptance are deferred to
the maintainer PC; hosted automated results are reported independently.

The native POST NUL-body failure is now causally qualified: production already
refuses these bytes synchronously before allocation. The old fixture incorrectly
expected positive dispatch; it now requires exactfalse, immediate single callback
and no active/native request. All seven URL/inflight/literal-percent/header/body
cases, socket counts, error receipts and final cleanup assertions remain. Actual
Lua5.4 and LuaJIT each give6/1 before this fixture correction and7/0 afterward.
No production HTTP policy is changed and the distinct ETag control remains open.

## Required continuation

- Follow [the Windows continuation](GROUP2-WINDOWS-TODO.md) and
  [the device/native continuation](GROUP2-DEVICE-TODO.md). Keep all five parent
  items partial until their real remaining scope and acceptance passes.
- The Linux native HTTP owner must preserve canonical E1 after an HTTP 503
  carrying E2 on Curl 8.5, without overwriting a foreign winner or discarding
  cleanup debt. Keep all seven controls, including the restored original E2-on-503 stimulus
  and the additional E1-on-503 control. Curl 8.14 passes seven/zero locally; this does not fix older supported Curl.
- Group 6 retains Homebrew/Sparkle archive acceptance. Latest inspected manual
  run [37267530410](https://github.com/adrienm7/ergopti/actions/runs/37267530410)
  at `4d026ba9abbc8449d68f8be932f21a7e9cac6c0b` still fails: 309 Swift cases,
  sixteen failure assertions. The Homebrew confined positive receiver reports
  target error -10004 with no nonce reply; this is not proven to be TCC or a
  hotstring defect. Sparkle still fails native server retirement/deadline controls.
  These unqualified foreign archive patches have not been imported here.
- Fetch actual origin/dev and preserve subsequent owner corrections. Final
  integration alone owns codex/ci-lock plus codex/ci-validation. Reserve the lock
  with an empty commit from the newest dev naming group, branch and candidate.
  Existing foreign ownership blocks reservation. Merge without squash/no-ff,
  immediately push dev and cancel exact-SHA automatic workflows.
- Let the manual integrated CI reach its terminal result, verify its actual
  tested SHA and that Release/Publish is skipped, and record passes, failures,
  skips and unexecuted work in the delivery receipt linked from
  [coordination issue 86](https://github.com/adrienm7/ergopti/issues/86).
  The latest maintainer instruction authorizes integration/deletion with genuine
  native or device remainder documented; mandatory assertions remain unchanged.
- Confirm every feature commit is in origin/dev before deleting only
  feat/hotstrings. Its owner alone releases the lock after terminal CI.

This document records the source/prerequisite checkpoint before final integration;
the exact final dev merge and CI result are recorded in the linked coordination
receipt and delivery report. The original main index with 307 staged paths and
unrelated working files remains preserved. No parent TODO item is removed and
no release is authorized by manual validation.
