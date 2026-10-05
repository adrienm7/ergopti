<!-- docs/audits/performance/ahk/2026_10_05/ci_deadline_pass/report.md -->

# Windows CI deadline investigation

## Status and scope

This report completes the bounded Windows CI deadline qualification described
below. It does not complete a general driver performance audit. It investigates the
Windows AHK suite deadline and the actual Local join fixtures contributing to
it. Root executed every runtime measurement; the report author only inspected
source and retained artifacts. No driver send policy, watchdog, security policy,
or production source was changed by this reporting pass.

The final receipt-bound entry candidate has causal regression, balanced private
before/after evidence and complete canonical v7 verification. Root ran the gates
against 47 changed paths with 3,370 frozen source files; all source hashes remained
unchanged. The report author only verified retained artifacts and prepared this
private publication payload. The proposed tracked path was absent when prepared;
this pass does not overwrite an earlier audit. Historical measurements retain
their exact source snapshots.

## Baseline and budget verdict

The retained v6 verification log planned 9,596 main-suite registrations. Its
1,320,000 ms watchdog fired after 7,206 completed results, while test 7,207 was
running. The first occurrence of each test ID has duration data totalling
1,310,088.003 ms. That sum excludes bootstrap, gaps and the unfinished test; it
is not a separately measured launch wall time. One completed test failed:
the obsolete atomic-publication source policy at ID6,223. The remaining planned
suffix was unexecuted, not passed.

The runner computes its budget as the minimum of 1,320,000 ms and
120,000 ms plus 200 ms per planned registration. The maximum reserves three
minutes below CI's 25-minute process deadline. This investigation keeps that
budget and every registration. The independent atomic-policy correction does
not itself solve the suite duration.

The enclosing verification finished naturally with exit 1. Its JavaScript lane
passed all 361 checks and its AHK E2E lane passed 70/70. This is a failed main-suite
qualification, not an entirely green local gate.

An earlier, different-source full run completed 9,576 registrations with 9,545
passes and 31 failures. Its first-ID duration sum was 969,433.219 ms. Its launcher
receipt and TEMP/TMP were not retained, so the previous temporary volume is
unknown. V6 used the root-confirmed owned D-volume TEMP/TMP directory
`D:/ErgoptiAuditWorkspace/current-ci-v6-full-aa6fda8950654a8c9080423943df6885`.
Changed sources, registrations, process state and execution history prevent
treating the two totals as a controlled storage comparison.

Root and a peer identified 35 matched Local join/panel/scope cases with
694,201.431 ms in v6 versus 291,692.380 ms in the earlier run. Their 402,509.051 ms
increase accounts for 81.4% of the peer's 494,295.010 ms matched-case increase.
This is a preliminary cross-run localization, not causal attribution or a claim
that those cases account for every millisecond of the timeout. The complete
first-ID totals above were independently rederived for this report; the matched
subset calculation is explicitly the peer's retained observation.

## Paired actual filesystem control

The V3 probe included the current filesystem and crypto adapters, without driver
startup, hooks, clipboard, GUI, timers or network owners. It measured real writes,
durable writes, atomic publication and exact read plus SHA-256. FileOpen,
WriteFile, FlushFileBuffers and close timing delegates forwarded real objects,
handles and results. Expected raw UTF-8 bytes and SHA-256 came independently from
.NET. Exclusive nonce directories on C and D were removed nonrecursively after
their exact sample files were retired.

Root's run on October5 at18:23:10.0191079–18:23:11.5441463 UTC finished naturally
with exit 0, exact completion stdout, empty stderr, 352 verified rows,320 measured
rows and 32 warm rows. Each operation/size/volume cell has two warm and 20 measured
samples; each measured C/D pair shares its round and alternates execution order.
Both source hashes and the interpreter hash were unchanged. No cancellation or
forced termination occurred and neither sample container remained.

Times below are milliseconds. Each C/D cell is median / maximum. The last
column is the median of 20 within-round D-minus-C differences, not the difference
between the two marginal medians.

| Operation      | UTF-8 bytes |  C median / max |  D median / max | Paired D minus C median |
| -------------- | ----------: | --------------: | --------------: | ----------------------: |
| Write          |       1,024 | 0.65735 /0.9037 |   0.584 /0.9566 |                -0.06235 |
| Write          |      65,536 |  1.7852 /3.3502 | 1.54745 /1.8691 |                 -0.2716 |
| Durable        |       1,024 | 2.01265 /3.5035 | 1.80935 /2.1362 |                 -0.1167 |
| Durable        |      65,536 | 2.77835 /6.6800 | 2.59165 /6.5446 |                 -0.1582 |
| Publish        |       1,024 | 3.14955 /6.4382 |  3.1735 /6.9523 |                +0.04075 |
| Publish        |      65,536 |  3.9265 /6.9379 | 3.71285 /5.0893 |                -0.37935 |
| Read plus hash |       1,024 |  0.4543 /0.6738 |  0.6135 /1.0237 |                +0.13985 |
| Read plus hash |      65,536 |  1.2775 /2.9620 | 1.41115 /2.3967 |                 +0.1152 |

Exact-read median/max was 0.19485/0.3005 ms on C and 0.3314/0.5669 ms on D at 1,024
bytes, then 0.6042/1.2740 and 0.6970/1.1470 ms at 65,536 bytes. SHA-256 median/max
was 0.23065/0.3746 and 0.23125/0.4246 ms, then 0.60695/1.4558 and 0.63235/1.0277 ms.
Read/hash excludes seed creation and the final raw-byte verification. Publication
includes its stage verification. Its nested native components are not additional
exclusive wall time.

This was one short run with recently written files. C and D are NTFS partitions
of the same Samsung disk0. It neither proves a general volume-speed ordering nor
attributes the CI timeout to storage, Defender, indexing, DPAPI or disk policy.
There are no p99 estimates. The raw per-pair extrema remain in the CSV.

V1 and V2 observer failures remain retained. V1 emitted a Round shadow warning
and stopped after 264 verified rows at its first read/hash oracle. V2 removed the
warning and printed identical text, binary and independent digests. The expected
string still contained LF: AHK's default Trim removed spaces/tabs and the earlier
`$` regex admitted that newline. V3 requires a raw 65-byte canonical 64-hex-plus-LF
record and extracts exactly 64 characters. Production Crypto was never changed;
an exactly sized StrPut byte buffer alone was not a truncation finding.

## Actual Local join profile

The measurement snapshot used a real Windows include graph and the actual
`_LSJ_Nominal`, `_LSPN_Report` and `_LSPN_ResumeAfterFinish` callbacks. It used a
separately qualified cold-defaults fixture repair described below. The last
callback is a complete panel resume lifecycle without catalogue Prepare, not a
constructor-only or pure-RAM control.

Root executed one ordered trial per mode, original then wrapped-disabled then
wrapped-enabled, from 18:27:52.370 to 18:31:01.563 UTC. Every mode finished naturally
with exit 0,3/3 assertions, empty stderr and 4,059 inherited warnings. Warnings were
retained, not suppressed. The same wrapper sources were used in the last two
modes; child-local `ERGOPTI_CI_MEASURE_SEGMENTS` selected scalar QPC collection.

| Mode                       | Process elapsed ms | Join case ms | Panel report ms | Resume lifecycle ms |
| -------------------------- | -----------------: | -----------: | --------------: | ------------------: |
| Original                   |       105,405.3174 |   27,151.784 |      61,205.799 |           3,378.534 |
| Wrapped, counters disabled |        40,250.4179 |   15,072.293 |      12,644.812 |           2,753.941 |
| Wrapped, counters enabled  |        43,498.8405 |   17,789.208 |      13,323.402 |           2,514.316 |

Process time includes graph/bootstrap and work outside the three timed callback
bodies. Original ran first; warmed native/OS state and scheduler history are
confounds. These trials do not establish an instrumentation speedup or a clean
overhead percentage. No receipt-bound production optimization ran in these modes.

Selected enabled-mode measurements follow. Every aggregate is inclusive:
interruptions and nested calls can overlap. Never add these rows to reconstruct
case time or compute an exclusive percentage.

| Scope                     | Join calls / inclusive ms / max ms | Panel report calls / inclusive ms / max ms |
| ------------------------- | ---------------------------------: | -----------------------------------------: |
| DPAPI unprotect           |           792 /14,792.087 /433.583 |                   654 /12,570.214 /536.367 |
| Exact filesystem read     |          6,543 /2,184.635 /139.376 |                  5,488 /1,612.380 /285.827 |
| SHA-256                   |          6,555 /2,328.080 /591.860 |                  5,488 /2,147.175 /436.477 |
| Source snapshot/read/hash |          6,603 /5,210.806 /592.334 |                  5,488 /4,592.668 /436.687 |
| Source Capture            |           390 /31,756.220 /979.213 |                   324 /27,516.749 /745.604 |
| Source Current            |          1,031 /7,471.732 /428.616 |                    886 /5,866.087 /249.422 |
| Native Entry              |           386 /34,294.243 /986.450 |                   319 /29,775.410 /813.886 |
| Native CurrentJob         |         279 /35,220.573 /1,000.058 |                   266 /31,430.059 /821.700 |
| Join Prepare              |          1 /14,126.633 /14,126.633 |                  1 /12,450.392 /12,450.392 |

For example, CurrentJob's 35,220.573 ms exceeds the 17,789.208 ms join case. This
alone disproves interpreting the aggregate as an exclusive share. Observed call
counts and the source path still establish repeated verified-source acquisition:
CurrentJob invokes target resolution, native Entry captures the source again,
and capture parses/decrypts entries. The existing Current checks read/hash
snapshots and validate RAM/lifecycle without needing fresh credential decoding.
Provider timers can interrupt Critical Off work; the per-job busy guard does not
exclude every other provider callback. Complete scheduler attribution remains
unmeasured.

## Cold fixture causal prerequisite

The initial standalone join attempt failed before discovery requests, so it
provided no C/D joined-operation timing. The source fixture did not own
LLM_Defaults initialization: earlier defaults tests had left its canonical Map
published in the full suite. Actual source Capture correctly refused an unset
or unrelated defaults state.

The test-only repair saves set/unset state and exact prior object identity,
invokes canonical LLM_Defaults_Load within acquired fixture ownership, and restores
the prior state in finally. It preserves every production admission guard and
old registered assertion. Two actual Capture controls begin unset or with an
unrelated inherited Map. Root's original/fixed/no-loader-inverse/repeated-fixed
profiles produced0/2,2/0,0/2,2/0 respectively, natural exits1,0,1,0, empty stderr
and 4,056 retained warnings each. A later primary change only restored section
banner spacing. This is fixture isolation qualification, not a performance gain.

## Implemented candidate and required full-suite proof

The first candidate is receipt-bound native Entry resolution. The source owner
already retains verified private entries under an opaque type and owner-bound
receipt. Its EntryBound operation checks the exact held receipt, calls
full Current before lookup/deep clone and again afterwards, and returns a detached
entry. Local join resolution must carry that same originating source through
job, cache, view, sweep, publication and Apply. A supplied bound-port refusal must
not fall back to fresh Entry or convert failure to proved provider absence.

This is not a global credential cache or a TTL. The legacy one-argument Entry
still freshly captures. Existing Current, admission, ticket, SameTarget, pending
fields and final RAM claims remain. Snapshot acquisition counts may change and
must be measured honestly; repeated decryption is the bounded mechanism to remove.
Type/owner/lifecycle drift, changed file bytes, missing/read failures, reordered
entries, token/model/backend/defaults changes and mutation during lookup or clone
must still refuse. Credential values must not enter metrics or report output.

The final frozen candidate contains 27 new registrations: two actual orchestration
decode-count controls and 25 authority controls. Root observed original 0/2, fixed
2/0, no-bound-port inverse 0/2 and restored fixed 2/0 for the decode controls,
then 25/0 for authority. Original counts were 208 versus expected 2 and 424 versus
expected 6; the inverse was 208 and 598 respectively. The distinct 598 witness
is retained rather than equating two timer-interleaved runs. Existing composition
16/16, private-source 42/42, cold-defaults 2/2, join 9/9 and panel 20/20 add 89
passing assertions. All ten qualification profiles exited naturally with empty
stderr; their 4,058 inherited stdout warnings remain retained. The first
misspelled composition filter selected zero tests and exited 1 in a separate
receipt; it contributes no passing evidence.

Healthy bound lookup preserves full Current checks before and after deep cloning.
The source-level raw-read count changes from 18 to 16 for that healthy lookup;
it does not remove all reads, and measured workload totals depend on reentrant
provider work. No global TTL cache is introduced. The actual balanced
measurements below establish the finite after evidence. Before marking this
report complete, root must retain:

1. Exact source/runtime provenance, causal decode-count inverses, and existing
   private-source/join/panel authority and publication regressions.
2. Same workload with balanced before/after order and repeated trials, recording
   maxima, counts, wrapper overhead and every correctness failure.
3. A complete main suite within the unchanged deadline with a validated plan and
   complete execution manifest, plus all proportional selected gates.
4. An explicit after verdict: achieved reduction, remaining cost and uncertainty.
   The finite after result and complete canonical full-suite result below are available.

Rejected shortcuts are increasing the watchdog, skipping or sharding assertions
to hide this local regression, disabling provider timers, removing Current or
admission checks, treating one known-good file as permanent authority, adding a
global TTL cache, or changing Defender/storage policy on the basis of this data.
They either alter the required behavior or lack causal evidence.

## Balanced private before/after measurements

Root executed one ABBA block on October 5, 19:03:18.314–19:05:32.792 UTC:
baseline, current, current, baseline with counters enabled, followed by one
current-disabled instrumentation control. Both sources used the same 28 inherited
spans; current additionally times source.entry_bound. That new span is absent
from baseline because its owner does not exist there. The exact fixture, three
actual aliases, helper, interpreter and full include graph were held constant.
All five trials passed 3/3, exited naturally 0, had empty stderr and retained
4,061 inherited warnings. Source hashes were restored exactly after the campaign.
The aliases are actual Local join nominal, panel report and panel resume lifecycle
without catalogue Prepare; none is a synthetic operation-count-only success.

| Trial        | Process elapsed ms | Join case ms | Panel report ms | Resume lifecycle ms |
| ------------ | -----------------: | -----------: | --------------: | ------------------: |
| 1-baseline-1 |         38718.8795 |    14866.758 |       12724.823 |            2406.883 |
| 2-current-1  |         15945.6603 |     2968.576 |        1710.739 |            2395.143 |
| 3-current-1  |         15924.6566 |     2633.351 |        1644.415 |            2640.035 |
| 4-baseline-1 |         42279.5560 |    16551.256 |       13622.807 |            2513.289 |
| 5-current-0  |         15985.6075 |     2345.032 |        1602.294 |            2731.285 |

The two enabled baseline process samples were 38,718.8795 and 42,279.5560 ms;
the two current samples were 15,945.6603 and 15,924.6566 ms. Their two-sample
medians were 40,499.2178 and 15,935.1585 ms, a finite observed difference of
24,564.0593 ms. Maxima are the larger samples above. The separate disabled
current sample was 15,985.6075 ms. This single ordered block supports a reduction
for this exact workload while reducing the first-trial confound; it is not a
confidence interval, p99, general driver speedup or production deadline verdict.
One disabled sample cannot quantify instrumentation overhead reliably.

Actual DPAPI calls and inclusive timings show the bounded mechanism:

| Trial        | Actual case       | Unprotect calls | Inclusive ms |  Max ms |
| ------------ | ----------------- | --------------: | -----------: | ------: |
| 1-baseline-1 | join-nominal      |             734 |    10914.333 | 317.043 |
| 1-baseline-1 | panel-report      |             630 |    10077.623 | 291.477 |
| 1-baseline-1 | panel-constructor |               6 |       37.757 |   9.762 |
| 2-current-1  | join-nominal      |              20 |      127.181 |   8.054 |
| 2-current-1  | panel-report      |              16 |       92.078 |   6.493 |
| 2-current-1  | panel-constructor |               6 |       26.527 |   4.509 |
| 3-current-1  | join-nominal      |              20 |      103.906 |   6.955 |
| 3-current-1  | panel-report      |              16 |       86.626 |   7.756 |
| 3-current-1  | panel-constructor |               6 |       36.179 |   6.597 |
| 4-baseline-1 | join-nominal      |             792 |    15129.389 | 584.456 |
| 4-baseline-1 | panel-report      |             682 |    13825.994 | 512.337 |
| 4-baseline-1 | panel-constructor |               6 |       31.435 |   5.731 |

The first baseline decoded 734 times in join and 630 in panel report; the first
current decoded 20 and 16. The resume control retained six decodes in every
enabled trial. Full raw metrics also retain reads, SHA-256, Capture, Current,
EntryBound and job/panel scopes. Counts vary with timer interleaving. Inclusive
spans overlap and must not be summed or divided into an exclusive wall-time
percentage. The earlier original/disabled/enabled sequence remains historical
localization only and does not establish this candidate's speedup.

Canonical v7 completed successfully with the unchanged 22-minute main-suite
watchdog. The separate 25-minute CI deadline, registrations and authority fences
were not increased or removed. No storage, Defender or security-policy causality
is claimed.

## Canonical v7 after verdict

Root ran the six selected gates from 2026-10-05 19:06:58.142 to
19:33:29.766 UTC. The aggregate process wall was 1,591,624 ms (26 minutes
31.624 seconds), including formatting, encoding, AHK suite, full AHK parse,
AHK E2E and all JavaScript checks. That aggregate is not the main-suite duration
and must not be compared directly with the 22-minute main-suite watchdog.

All six gates passed and the parent exited naturally 0. The main execution
manifest is complete at 9,630/9,630 with zero failures; AHK E2E is 70/70; all
361 JavaScript checks pass. Formatting reported 219 files already formatted and
encoding verified 1,847 AHK files as UTF-8 BOM plus LF. The full ErgoptiPlus AHK
include graph compiled. The source receipt records no drift and this independent
review matched all 3,370 frozen file hashes again without rerunning a gate.

The raw main section contains exactly 9,630 unique duration rows. Their
per-test callback durations sum to 645,368.485 ms (10 minutes 45.368485 seconds);
the maximum individual callback is 61,947.148 ms. These are separately derived
from main-suite records, excluding bootstrap, inter-test gaps and gate work.
Independent main spawn start/end wall timestamps were not retained, so this
report does not invent a wall duration from that sum. The suite completed
naturally without its unchanged 1,320,000 ms watchdog firing.

There are 4,058 retained warning records in the main section and seven in E2E,
4,065 total. They were not suppressed or described as warning-free. Three
keep-awake visibility registrations require --interactive and remain inactive,
explicitly excluded before the 9,630-test plan. Their absence is not a physical
input pass. Native POSIX driver suites, package installation, Group7 completion,
Windows10 and physical typing were not qualified by this gate.

The v6 timeout and failed atomic source policy remain historical RED evidence.
V7 uses changed sources and 34 additional main registrations, so its callback
sum is not a controlled whole-suite speedup percentage. The bounded mechanism
has independent decode-count inverses and balanced workload timing; the final
delivery verdict is complete execution within the existing main watchdog,
with all selected gates passing. Remaining broader latency and scheduler
questions stay explicitly unmeasured.

## Unmeasured priorities

Keystroke and LL-hook latency, Critical-span starvation, tooltip/dashboard
presentation, resident startup and idle CPU/memory are outside this pass. Windows
Notepad receiving and completion tests supplied functional text/caret evidence
elsewhere; this report does not turn those finite samples into physical-input,
hotstring/LLM end-to-end, p99, reliability or general production-latency claims.
Windows10 and non-Windows driver performance were not measured. Shared source
checks are not native Linux/macOS driver execution.

## Evidence

All paths below identify retained local artifacts; SHA-256 values bind the exact
bytes inspected. The private packet's evidence-index.json additionally binds raw
TAPs, source manifests and source/runtime fingerprints without copying large logs.

| Artifact                                                                                                                                        | SHA-256                                                          |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| D:/ErgoptiAuditWorkspace/current-ci-v7-full-verification-receipt.json                                                                           | 49e572c8b475d52aae34d01bbafda4c1ff42150ecc4de247851bc12b57ef05a8 |
| D:/ErgoptiAuditWorkspace/current-ci-v7-full-verification.log                                                                                    | b38ef240dba7371245cb80b4b815cd5eb403a85e1a6232e2aae4d0e2adb362a5 |
| D:/ErgoptiAuditWorkspace/current-ci-v7-source-freeze.json                                                                                       | f724e301fdfe629f18b9e2ae9be299343b8ad68d6c519d2cad145a966fea6203 |
| D:/ErgoptiAuditWorkspace/run-current-ci-v7.cjs                                                                                                  | 751eb6d6068649661087c71e14e63c853b4c2647ba3c24b8e9b9eb50c906b025 |
| D:/Documents/GitHub/ergopti/reports/.codex-notepad-work/config-receipt-entry-01c78329-4caf-4c44-8d47-f6e41125fb2d/manifest.json                 | 14596963bb0556ee95603484b9331da409457089446e5e1ad14bb1b2a86e811f |
| D:/Documents/GitHub/ergopti/reports/.codex-notepad-work/ci-join-receipt-measurement-v2-delivery-20261005/manifest.json                          | 7184e5d312349256241b0ad84109a647b16ac3373b185adbaae78ce5361c4d36 |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/receipt-entry-qualification-C7Qagu/receipt.json                                           | 7d538a3b48b8cff7604d7e146a0a428848721e430b06030ba8d8f64de8ba2054 |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/receipt-entry-existing-VQxxOB/receipt.json                                                | aa7cb3e52e3576b5c8ef4f8602ab47cdff3c978b2c8971fdcc1b0fa5bf51b574 |
| D:/Documents/GitHub/ergopti/reports/.codex-notepad-work/receipt-entry-actual-independent-input-0f56f4f4-aece-4b9f-99a1-6405014967fe/review.json | c83c20355d3048e1554edf2470abaa1cb95782c9f08560bcd1839e58f469fda0 |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/receipt-entry-balanced-JFWShw/receipt.json                                                | f59b2a5087192efa26b2748a544013150a60c78e9a9be30cc420f8dd7d5f3e4b |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/receipt-entry-balanced-JFWShw/source-freeze.json                                          | 1098fad75a189b4b27e31669ac64147cc104a7dc1b603b46dd7b39d1e6c6f4c4 |
| D:/ErgoptiAuditWorkspace/current-ci-v6-full-verification.log                                                                                    | 9ad924e3042f4c0bd0d8cf11fbf1cf45587740c12bddd6ba854a5899572db8c0 |
| D:/ErgoptiAuditWorkspace/current-ci-v6-full-verification-exit.txt                                                                               | 6b86b273ff34fce19d6b804eff5a3f5747ada4eaa22f1d49c01e52ddb7875b4b |
| D:/ErgoptiAuditWorkspace/notepad-merged-full-results.txt                                                                                        | d4d57803d6a1c85969cc3f27191be2e3b93483eeb74e7b48c2a26078f4738cdd |
| Paired FS V3 run-ea848ed6178a454c8992fd3e12a267f0/receipt.json                                                                                  | a7fd3ca80cdf2a91d2b56d698b524e9c37617b10904a1348cf64b1f556acf4fc |
| Same FS V3 run/samples.csv                                                                                                                      | 66eb03f5dd1bb182d8d4622b197aa60ab5819cabc0e943d0ad06f15b6586e5f9 |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/measured-controls-qZoC6G/receipt.json                                                     | cb82cc80380370ff6daab0154d8193360b3c6ea3e32f958b120750f526cfa2bd |
| D:/ErgoptiAuditWorkspace/join-profile-snapshot-AFpje7/cold-causal-mFMCRa/receipt.json                                                           | 31695b6314f48310d42f7e58aec32f1967eb2c6834280f3c9db7b96b6b02facc |

The FS V3 run is under
`reports/.codex-notepad-work/ci-filesystem-paired-benchmark-v3-delivery-20261005`.
Its source manifest SHA-256 is
`bfac534c5b0e99bca505fc26d756c6f1601d15ebc87e96cf08e76444885395c7`.
The profile source manifest is
`ab998ba1275c699ee2c298580de1e11f87e8de1f26b35485dbef57bb621a5978`;
the cold fixture manifest is
`4ca3a57bfcaf9d3d503204a099958c1561337bfefcf91c67b44451fe031baab0`.
The candidate manifest and independently checked full artifact references are
recorded in the private evidence index. No raw credential or user document content
is copied into this report.
