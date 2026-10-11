<!-- docs/audits/performance/ahk/2026_10_11/report.md -->

# Windows test performance measurements

## Scope and provenance

This pass measures test workloads on Windows with AutoHotkey 2.0.26 and
Node 22.22.2. The resident driver and personal configuration were preserved.
Some independent fixture checks overlapped, so these measurements do not
establish exclusive-host latency or an end-to-end CI speedup.

The two JavaScript optimizations are published in `fa94e27337` and
`1f0d4dd37e`. The AHK comment-scanning successor has bounded differential and
native receiving evidence below. Its complete hosted suite remains pending;
no test duration reduction qualifies native behavior.

## Repeated menu source classification

The classifier now reuses header and facade proof results within one parse
invocation over immutable source. It has no cross-call cache. A faithful
selection of the original header and complete About/facade assertions took
28.363 seconds before, 18.888 seconds after, and 18.845 seconds on restoration
of the candidate. Root independently received the adopted helper in
18.911 seconds. An unsafe cross-call memo failed the original negative case.

The complete original menu-parity owner exceeded its private 600-second
bound after four success summaries. That observation remains incomplete;
neither the selected checks nor their roughly one-third reduction establishes
a complete-owner speedup.

## Corpus reader classification

Preparing noncomment lines once per immutable reader avoids splitting the
same strings for every corpus field. All four matching patterns, exclusions,
comment rules, census floors and refusal assertions remain unchanged.

Paired samples with identical hashes for all 4,744 inputs took 30.698 and
29.988 seconds before, then 20.519 and 20.242 seconds after. Median time fell
from 30.343 to 20.380 seconds. Splits fell from 453,773 to 4,545; RSS increased
approximately 38 MB, from 166 to 204 MB. Root received all 770 fields across
145 corpora and 4,545 readers in 19.270 seconds on the updated tree; this last
sample is not a paired comparison. Removing the comment filter fails, and
good/bad/good invocations do not reuse stale results.

## TOML comment scanning

The original unquoted-comment lexer scans each character in interpreted AHK.
The first proposed `InStr` replacement was rejected: embedded NUL stops its
search, losing a subsequent LF. The differential exposed 36 divergent frames.
The successor uses `RegExMatch` for LF and leaves the separator to its original
owner. The shared Lua lexer already uses native `find`.

The successor matches the original on 596 cases, 8,392 frames and 1,920 error
frames. Comparison includes exact UTF-16 token bytes, cursor, spans, separator
and errors, including NUL, astral and unpaired surrogate inputs. The registered
NUL regression passes on original and successor and fails on `InStr`.

A pure-token QPC measurement uses a 32 MiB ASCII comment in original,
successor, successor, original order. Original samples are 14,379.279 and
14,947.469 ms; successor samples are 25.260 and 25.271 ms. Token and cursor
results are asserted. This isolates scanning cost, not whole-suite latency.

The successor passes 566 TOML-selected cases in 59.166 seconds, 70 isolated
native Edit cases, the canonical whole-entry compilation and encoding gates.
The rejected `InStr` candidate's nine-case custody group had eight passes
and one failure in the final durable-write rollback. The current regex
successor passes the exact immediate predecessor plus that callback in
311.910 seconds, including the recovered-old rollback results. This does
not explain the discarded candidate's grouped failure. The full nine-case
group still needs execution on the regex successor in hosted CI; the latest
hosted nine passes belong to the original scanner.

## Native custody phase measurements

A single original acquired-read control retains its 32 MiB input, all
26 assertions, native operations and eight-attempt timer loop. Instrumentation
only observes call boundaries. The selected case passes in 114.078 seconds.

| Phase                                           | Elapsed ms |
| ----------------------------------------------- | ---------: |
| Build the 32 MiB source                         |     81.983 |
| Initial native hash                             |    103.886 |
| Write old source and genuine boot               |    251.775 |
| Acquire ownership and commit                    | 41,268.577 |
| Read WAL bytes before the observation           |      1.190 |
| Original acquired-read timer attempts           |    688.133 |
| Restore observer and assert its state           |     52.678 |
| Read and compare WAL bytes afterwards           |      1.238 |
| Match target bytes and bundle ownership         |    136.674 |
| Native repair and assertions                    |    812.509 |
| Native rollback and exact-byte assertions       | 70,458.360 |
| Release ownership and clean the owned directory |    201.688 |

Commit and rollback account for approximately 98% of this case's measured
time. This localizes further investigation; it does not yet attribute those
costs to a particular production function. Reducing the timer attempts or
reusing snapshots across distinct ownership observations is not justified.

All twelve phases completed. The exact actor exited, its wrapper was removed,
tracked source hashes remained unchanged, and ownership/read ledgers were
zero. The diagnostic retains 5,158 canonical warnings and a nonempty private
temporary directory, so its stricter aggregate remains `qualified: false`.
The selected passing test is not a full-suite or installation qualification.

The retained temporary files are six registration-time metadata listings
totaling 40,692 bytes; no selected custody directory or WAL remains. The
warnings are `LocalSameAsGlobal` diagnostics from the canonical include graph,
including two profiler locals. They remain visible and do not change the
aggregate qualification result.

A second private measurement wraps the actual `Row.check.Call` boundary,
preserving its arguments, result, exception propagation and final native
ownership fence. The same original control passes and retires its actor,
wrapper and ownership ledgers. All twelve phases complete with unchanged
tracked source. Its strict aggregate likewise remains false because of the
warnings and registration-time temporary listings.

| Phase           | Calls | Inclusive check ms | Whole phase ms |
| --------------- | ----: | -----------------: | -------------: |
| Commit          |   338 |         56,646.284 |     65,323.669 |
| Native rollback |   284 |         87,278.442 |    101,293.127 |

These are inclusive call-boundary observations, including argument extraction
and nested checker work. They are neither exclusive CPU cost nor a paired
speed comparison with the earlier sample. They identify the repeated guard
path as the next measurement target; string copying and comparison costs
have not yet been separated.

## Hosted Windows timings

Completed run `38154427900` executes all 11,222 planned callbacks: 11,221
pass and one fails. Callback durations total 4,395.102 seconds (73 minutes
15 seconds); the AHK step takes 74 minutes 21 seconds and the whole unit
job 76 minutes 4 seconds. The median callback takes 1.452 milliseconds.

| Workload                      |  Tests | Summed callback time | Share of time |
| ----------------------------- | -----: | -------------------: | ------------: |
| Callbacks below one second    | 10,889 |      490.303 seconds |        11.16% |
| Callbacks above ten seconds   |     80 |    2,757.750 seconds |        62.75% |
| Nine native custody scenarios |      9 |    1,075.202 seconds |        24.46% |
| Largest journal capacity case |      1 |      172.152 seconds |         3.92% |

These rows overlap and must not be added. The slow tail dominates; the
number of small assertions does not explain the runtime. The nine custody
scenarios retain real ownership, durability and rollback observations, so
these measurements alone do not justify removing them. Repeated display
names account for only 0.322 seconds and include distinct files or inputs.

The nine custody scenarios were introduced by `9878870ae5` on October 10
at 03:01 UTC. They independently rebuild a 32 MiB fixture and perform real
commit and rollback operations for distinct native callback boundaries.
The journal capacity case dates to `7d2d80c372` on September 28. These ten
cases account for 20.789 minutes, but there is no comparable historical
measurement proving that they alone explain a 10–20 to 75 minute increase.

Case 1981 itself passes in 0.162 milliseconds. The sole failure is case
7126: a source assertion expects two receipt bootstrap owners after the
native desktop entry legitimately added a third. This is separate from
the observed performance cost. Redirecting native stdout can prevent a
blocked reader, but no current end-to-end speedup is attributed to that
change: the completed callback durations already explain most elapsed time.

Cancelled run `38147217648` records 5,479 completed passing callbacks totaling
3,724.668 seconds. The next callback was interrupted and has no completed
duration. Seven completed custody cases total 810.592 seconds. The largest
completed case is the 32-file journal at 169.725 seconds. These are partial
timings; the remaining planned cases cannot be counted as passed.

## Rejected and unmeasured shortcuts

- The WAL is bounded to 64 KiB; a 32 MiB raw-hex benchmark would measure the
  wrong workload.
- Binary memory comparison changes embedded-NUL string semantics.
- A UTF-8 workload using fewer UTF-16 units remains an unmeasured proposal;
  genuine timer admission must still be proved.
- Whole-registry parallel execution is not justified while tests and
  generators share mutable files.
- Keystroke latency, critical spans, tooltip rendering, startup and idle
  costs are outside this test-focused measurement. No runtime budget verdict
  is asserted for them.

## Reproduction records

Compact source pins, scripts and receipts are retained under the local
`D:/ErgoptiAuditWorkspace/` audit root:

- `menu-parity-selected-within-call-menu-20261011/` and
  `optimization-root-gates-20261011/` retain menu receiving.
- `js-source-scan-perf-input-20261011/` and
  `corpus-source-opt-root-20261011/` retain corpus measurements.
- `toml-comment-regex-successor-group2-20261011/` retains lexer comparison;
  `toml-regex-root-20261011/` retains canonical TOML receiving.
- `windows-custody-phase-profile-regex-v5-group2-20261011/` contains the exact
  profiler; `custody-phase-regex-v5-root-20261011/receipt.json` retains its
  actual observations and qualification limits.
- `ci38147217648-cancelled-windows-input-20261011/` retains hosted timings.
- `ci38154427900-windows-terminal-input-20261011/` and
  `windows-test-duration-distribution-input-20261011/` retain the complete
  hosted callback manifest and duration distribution.
- `custody-two-case-regex-root-20261011/receipt.json` retains the current
  regex successor's ordered native receiving.
- `windows-slow-test-introduction-input-20261011/` retains introduction
  commits and the repeated native operations behind the measured costs.
- `windows-custody-row-check-attribution-input-20261011/` retains the private
  call-boundary instrument; `custody-row-check-attribution-root-20261011/`
  retains the actual result and unchanged-source proof.
- `custody-profile-resource-attribution-group2-20261011/` identifies the
  retained registration files and canonical warning categories.
