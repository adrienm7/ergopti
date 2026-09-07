<!-- docs/audits/hammerspoon/2026_09_07/handoff/report.md -->

# Hammerspoon audit handoff snapshot — 2026-09-07

Audited commit: `44e0a8e57659994eb3af293440f44d03d66960a8`.
Scope: Hammerspoon driver, extension preview semantics, application picker
ownership/discovery, and selected test organization.

## Executive summary

Seven confirmed, actionable findings are recorded in [findings.json](findings.json).
Two are medium severity; five are low severity. Confidence is high for the
reproduced behavior, not a claim of exhaustive native macOS coverage.

The detailed, mutable implementation and test-refactoring checklist is
[TODO.md](TODO.md). Read it before applying a fix. Findings in this snapshot
remain evidence about the audited commit; checkboxes belong in the TODO.

The user changed the assignment to audit and handoff only. No implementation
was started after that change. HS-273 already had an uncommitted candidate:
its selected HS and HS-E2E gates subsequently completed successfully, with
9,198 unit tests in 1,009 modules. It remains uncommitted in the existing HS
worktree, with a recovery copy in this directory. The other six findings have
no implementation in this handoff.

## Evidence and provenance

The standard `validate-report` CLI rejects this second same-day subdirectory:
it only accepts `docs/audits/<scope>/<date>/findings.json`, already occupied by
an earlier immutable report. That report is preserved. The local
[handoff validator](validate-handoff.cjs) checks manifest fields, the source
commit, unique IDs against the previous report, LF and documentation links.
It is a documented fallback, not a claim that the standard CLI accepted this path.

All five supplied probes were read and replayed by the coordinating reviewer
against the audited commit in a separate documentation worktree. Each exited
zero while asserting the original faulty behavior. They execute real Lua
controllers/readers; OS boundaries use explicit doubles. See the TODO for
commands, expected observations and conversion into proper regression tests.

- HS-267: [out-of-order picker](evidence/probe-app-picker-out-of-order.lua).
- HS-268: [failed partial discovery cache](evidence/probe-app-picker-partial-cache.lua).
- HS-269: [repeated section rendering](evidence/probe-counter-repeated-sections.lua).
- HS-270/HS-271/HS-272: [parser siblings](evidence/probe-counter-parser-siblings.lua).
- HS-273: [trailing metadata](evidence/probe-counter-trailing-metadata.lua).

The repeated-section rendering probe deliberately supplies only the menu
dependencies needed by that scenario. Warnings from unrelated LLM/language
rows are fixture limitations, not additional production findings.

## Coverage register

| Surface | Evidence in this pass | Boundary |
| --- | --- | --- |
| Extension section counts and detail rendering | Canonical reader, registry and actual menu builder probes | Specific valid inputs; not exhaustive TOML grammar |
| Extension names | Canonical string parsing versus counter output | Shared discovery has the same escape weakness; do not use it as the sole oracle |
| Application picker ownership | Real controller with reversed native completions | Headless callback ordering, not native visual testing |
| Application discovery cache | Real controller with failed process receipt and partial stdout | Optional-root handling must be designed before fixing |
| Metadata candidate | Six red-before/green-after cases, selected full gates | Candidate is not part of audited HEAD or committed delivery |
| LLM activation tests | 44 executed cases; responsibility and fixture review | No new false-green or redundant case proven |
| Large test inventory | 1,043 tracked Lua test/support files; 28 over 1,000 split-on-newline lines | Static call-site counts are not executed case counts |
| Other input/clipboard flows | Brief search_web reading only | No completion claim, no new finding |
| Native latency, CPU, memory, real keyboard hosts | No new native measurement | G4 remains unmeasured |

## Refutations and non-findings

- Do not report `ShellRunner.spawn()` returning nil as a confirmed picker bug:
  the inspected adapter supplies a refusal handle. An invented nil stub is not
  evidence of that production path.
- Repeated section declarations do not lose mappings or corrupt the grand
  total in the supplied probe. Their demonstrated defect is duplicate UI rows.
- A false-green ratchet result of zero does not prove semantic test quality.
- No test deletion is recommended merely because two tests look similar.
- The earlier same-day report contains 13 findings at commit
  `f6d387ff85cdbac5cf8ded0c88994bf1948fbd67`. Do not automatically reopen that
  historical list: inspect the intervening fixes and reproduce current behavior.
- The health-probe and activation fixtures exercise different real dependency
  boundaries; their similarity is not proof they should be merged.

## Memory watch-list and performance status

Retain the routed memory invariants: exact native return receipts, publication
after activation, stale-callback fencing, module-cache isolation, native JSON
semantics, classified filesystem absence, and no synchronous hot-path I/O.
The picker findings show why native chooser identity and request identity are
different. The counter findings show why a second grammar can disagree with
the actual loader even when file transactions are correct.

There is no new measurement of keyboard latency, memory growth or native
Hammerspoon startup in this pass. Long Windows-hosted test execution is not
evidence that the live macOS driver is slow. Follow the profiling skill before
making or implementing a G4 performance claim.

## Explicit completion limits

This is not a claim that seven bugs are all remaining bugs. Two consecutive
complete no-finding sweeps have not been performed; native macOS validation is
unavailable here. The TODO records further coverage work without falsely
promoting hypotheses to confirmed findings.
