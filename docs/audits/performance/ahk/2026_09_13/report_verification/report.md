<!-- docs/audits/performance/ahk/2026_09_13/report_verification/report.md -->

# Performance report verification cost

## Scope and preserved coverage

The previous planner selected all 225 JS checks for every Markdown change.
Its explanation overstated `test-doc-paths.cjs`: that check only searches driver
documentation for obsolete driver roots; it neither checks arbitrary Markdown
links nor reads archived performance reports. The AHK runner-reference scanner
also excludes `docs/audits/`, as its streaming regression test establishes.

Only Markdown under `docs/audits/performance/` now selects `report-style`, the
existing strict convention lint. Driver documentation, memory, skills, audit
manifests and code keep their prior gates. Mixed changes retain all relevant
checks. Since JS already invokes this exact lint command, it subsumes the
standalone gate in mixed and full plans. A covering JS failure remains blocking
for the report in full diagnostic mode; unrelated driver failures retain their
historical classification. No general link-validation guarantee is introduced.

## Local command-cost observations

Windows on 2026-09-13, pinned Node 22.22.2, TEMP/TMP on campaign scratch D:.
One suite at a time, resident AHK unchanged, uncontrolled other host activity.
PowerShell Stopwatch surrounds the complete command including startup/output.

| Command scope | Observed elapsed time |
| --- | ---: |
| Full selected JS gate for planner/skill edits | 305.029 s |
| Report-only verification of `a77743380~1..a77743380` | 6.263 s |

Both commands exited 0. The former passed all 225 JS checks; the latter executed
strict conventions and the planner's prechecks. The old selector would have
sent that report-only range to the same full JS command. These are one local
observation per command scope, not repeated old/new binary measurements or a
RAM/CPU profile. About 299 seconds of verification work were avoided in this
comparison; no runtime driver speedup is implied.

Receipts in campaign scratch: `performance-report-gate-01.out`,
`performance-report-full-duration-01.json`, `performance-report-only-01.out`
and `performance-report-only-duration-01.json`.

## Regression evidence

The initial selection test failed with actual `js` versus expected `report-style`.
Updated tests cover report-only and mixed changes, preserved non-report gates,
and complete plans without repeating subsumed commands. A CLI control-flow
fixture also exposed a diagnostic false green while developing the change:
the covering JS failure was incorrectly classified as non-blocking history.
The corrected CLI exits nonzero for standalone lint or covering JS failures,
while an unrelated Hammerspoon failure remains historical. Platform commands
are replaced by explicit child-status receipts in that fixture; it starts no
real driver or suite and does not modify a working tree.
