<!-- docs/audits/performance/ahk/2026_09_08/present_followup/report.md -->

# Tooltip content positioning follow-up

## Scope and verdict

Source: `f91ba439b47dd92cdb74e3f87b626393186a754e`.
This is a measurement pass, not a production optimization or a claim that the
intermittent latency defect is resolved. No threshold or assertion was removed.

The preceding full gate completed 5700 cases with 5699 passing. Complete
preparation failed its 5 ms p95 budget. Its newly correlated diagnostic reported:

| Observation | Total ms | Clamp | Show | Corners | Border |
| --- | ---: | ---: | ---: | ---: | ---: |
| p95, sample 29 | 5.301 | 0.061 | 4.045 | 0.017 | 1.178 |
| maximum, sample 49 | 6.738 | 0.196 | 6.272 | 0.019 | 0.251 |

Receipt: TEMP `ergopti-shutdown-verify.log`; the exact values are also retained
in the source commit's message. This is one failing run, not a latency distribution
across sessions. The older report in the parent directory instruments a different
path and must not be combined with these observations as one population.

## Instrumentation and limitations

The attached patch modifies only a private archive of the source commit.
It records three QPC timestamps inside `_TooltipPositionPreparedContent`:
entry, after `_TooltipPrepareContent`, and after `SetWindowPos`.

- `prepare_ms`: entry through preparation; production rows have already been
  prepared by `_TooltipBuildGui`, which runs outside the measured interval.
- `move_ms`: preparation timestamp through return of the native movement call.
  This includes instrumentation overhead and any synchronous window processing,
  waiting, scheduling or callback work; it is **not exclusive native CPU time**.
- `outer_show_ms`: original outer show interval minus those two segments.
  It includes call/return work, probe activation and timestamp overhead.
- Original clamp, corners, border and total intervals remain measured.

Timestamps use a preallocated 100-row buffer. CSV formatting and stdout writes
occur only after the measured loop. Extra QPC calls, condition checks and buffer
writes perturb the execution; no overhead subtraction was attempted. This probe
cannot distinguish message dispatch from native waiting. No thread CPU or stack
samples were collected. No uninstrumented/instrumented randomized comparison was
performed; successful instrumented runs do not refute the earlier failure.

The test still builds 100 detached rows, positions them, applies corners, builds
borders and disposes each surface. Reuse assertions and the 5 ms p95 limit remain.
First-iteration border construction is included; no warmup samples were removed.

## Results

Both runs completed normally. Each yielded 100 aligned observations in
[samples.csv](samples.csv). The parser verified numeric nonnegative fields and
outer/inner sums within 0.0003 ms, allowing four-decimal CSV rounding.
Percentiles use nearest rank, matching the production test helper.

| Run | Test result | p95 total ms | p95 sample | Maximum ms | Maximum sample | Samples >= 5 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Isolated complete preparation | 1/1 | 3.9914 | 83 | 5.6375 | 1 | 1 |
| Original registry prefix | 359/359 | 2.9911 | 73 | 6.2904 | 1 | 1 |

At the isolated p95 row, show was 3.6838 ms, including 3.6504 ms in the
movement interval. At the prefix p95 row, show was 2.7642 ms, including
2.7311 ms in movement. Both maxima instead occurred on the first iteration:
border construction contributed 4.6669 and 4.8320 ms respectively.

These are measured successful runs. They identify where observed costs accrue,
but did not capture the failing p95 event inside the movement probe. They do not
justify GUI caching, priority changes or omitting native positioning.

## Provenance and replay

- Windows, AutoHotkey v2.0.26; the same workstation as the preceding pass.
- Output completion times: isolated 2026-09-08T06:16:58.759Z;
  prefix 2026-09-08T06:19:18.647Z.
- The resident driver and two UIA workers were present at the initial snapshot.
  One UIA worker subsequently exited; machine load was not controlled.
  Resident PID 11412 started September 7 at 18:42 local time, before direct-native
  launcher commit `672acf7a5` at 23:09. Workers 7156 and 8668 had different
  parent PIDs 12440 and 5388 (both absent at inspection), while their parent HWND
  20054448 still belonged to resident 11412. This is consistent with the old
  in-memory launcher, not proof of a current-code leak. Worker 8668 exited
  without intervention; the exact reason for 7156 remaining alive is unknown.
  A separately authorized resident restart and fresh-worker ownership check
  would distinguish current behavior; neither was performed in this pass.
- Only one owned AHK runner ran at a time. No existing process was terminated,
  suspended or reprioritized.
- The prefix probe keeps exactly the registry entries through the named complete
  preparation test and fails if that endpoint is absent. This restriction exists
  only in the temporary archive, not in the repository's test runner.
- An initial prefix launch failed to parse a probe-local reserved variable name
  before executing tests. The attached patch fixes it; that launch supplies no
timing evidence.

Review found that the added QPC could overwrite the failed native call's last
error. The replay patch now captures that error immediately before QPC and uses
the captured value when throwing. The two successful measurements predate that
probe-only safety correction; their native-error path was not exercised. The
extra assignment in the replay version slightly changes instrumentation cost.

Create a new private directory, archive the source commit's Windows and shared
trees into it, extract, then apply [probe.patch](probe.patch) there. Do not apply
the probe to an active worktree. Launch AutoHotkey64 hidden with
`/ErrorStdOut run_all.ahk` from the archived Windows tests directory, capturing
stdout/stderr. This runs the 359-case prefix. Add
`--only "100 complete ordinary"` for the isolated case.

Raw temporary receipts: `ergopti-present-profile-isolated.out/.err` and
`ergopti-present-profile-prefix.out/.err`. The archived probe is under TEMP
`ergopti-present-profile-c15fef31477c4229b87906f5305c17ba` and is instrumented,
not a pristine baseline.

## Next discriminating check

Capture a failing preparation run with this finer movement boundary, then use a
bounded stack/message-dispatch trace to separate native waiting from reentrant
AHK work. Preserve ownership, ordering, visibility and cancellation guarantees.
The uninstrumented p95 failure remains open; no production fix is justified by
these two successful observations alone.
