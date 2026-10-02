<!-- docs/audits/performance/ahk/2026_10_02/menu_second_pass/report.md -->

# Native menu preparation, second pass

## Scope and ownership

Continue on dev without pushing after the user reported remaining delay. This
pass removes preparation from the first native-menu publication and repeated
scans from the configuration registry parser. Preserve the previous pass's
startup-click ownership, complete input readiness and native tray surface.

The Windows implementation uses WM_INITMENUPOPUP, which Windows sends before a
popup becomes active and permits modifying its rows before display
([Microsoft documentation](https://learn.microsoft.com/en-us/windows/win32/menurc/wm-initmenupopup)).
This optimization belongs to AutoHotkey's native Menu handles. macOS and Linux
retain the same shared declarations, choices, state and scalar contracts; they
do not use this Win32 message or the AutoHotkey parser. No feature becomes
unavailable on either platform and no new unsupported-feature reason is needed.

The implementation is bounded to prepared leaf lists. Nested parents and
providers still render normally. A leaf publishes a real first choice, then
appends the remainder before its first native paint or in one-shot background
callbacks, one leaf per callback. It introduces no loading label or temporary
window. The existing first early click can still open the native startup
Pause/Reload/Quit menu while the input registry is incomplete; this pass does
not claim every process-start prerequisite has disappeared.

Pending Menu objects belong to one population owner. Publication retains only
HMENUs reachable from the accepted root, including children reused by a narrow
projection. Refused publication discards its unpublished owner's work. Seed
command IDs and dispatcher tokens survive append. Pause stops background
preparation; resume rearms retained work. Configuration menu navigation remains
available while paused and can complete its requested leaf. Terminal shutdown
releases the timer and pending Menu references.

Prepared leaf appends have a short Critical span and an explicit busy fence.
Sent native messages may interrupt otherwise uninterruptible AHK threads
([upstream OnMessage documentation](https://github.com/AutoHotkey/AutoHotkeyDocs/blob/v2/docs/lib/OnMessage.htm)).
Unexpected synchronous reentry is refused before partial paint. A failed native
registration or append retains failure ownership, stops background retries,
reports an error and prevents painting that partial popup. It cannot report a
successful drain or replay rows over a partially appended menu.

## Current baseline and measurements

Baseline commit: c4f41212f. Runtime configuration is copied read-only from
D:/Documents/GitHub/config/ergopti_plus into private startup fixtures. Runtime
logs resolve to %LOCALAPPDATA%/ergopti_plus/logs. Use the main log, not its severity
mirror. AutoHotkey 2.0.26; QPC timing. Windows is the active measurement host.

The 14:12 live session attributed approximately 570 ms wall to the full tray,
394 ms to hotstrings and 335 ms to layout/remaps. Its prefix phase includes a
1375 ms native navigation interval; its 1617 ms wall duration is not CPU work.
These are user-session observations, not controlled timing samples.

Three current-baseline isolated launches at 14:15 took 3122, 3181 and 3201 ms:
median 3181 ms, maximum 3201 ms. Each includes the smoke fixture's intentional
650 ms pump. Replay with:

```powershell
node tools/dev/bench-ahk-startup.cjs --config-dir=D:/Documents/GitHub/config/ergopti_plus --samples=3
```

A later baseline/candidate/candidate/baseline startup series overlapped a source
test probe and showed large scheduling variability. Baseline elapsed values:
4500, 4589, 4696, 4844, 5286, 6392 ms. Candidate values: 4657, 4711, 4751, 5304,
5525, 5613 ms. This series does **not** establish a complete-startup improvement.
Do not compare its candidate values against the earlier quiet window or subtract
the synthetic pump to promise a live-start latency. The most delayed leaf in
this contended series took 263 ms wall; Critical does not protect against OS
descheduling. The runtime profiler now identifies slow Menu.populate_leaf spans.

A paired warm-menu probe at 14:50 used the real startup inspection seam in one
private driver process. After completing the initial tree, alternate eager and
deferred rendering ten times each, through InitSubMenus and initMenu. Complete
pending leaves outside the root-publication measurement. Compare the entire
native tree in memory after each iteration: exact labels, GetMenuState flags,
separators, order and child structure. All twenty complete trees matched.

| Measured component                            | Eager median / p95 / max       | Deferred median / p95 / max    |
| :-------------------------------------------- | :----------------------------- | :----------------------------- |
| Warm native root preparation, 10 samples each | 279.311 / 300.240 / 300.240 ms | 204.869 / 241.870 / 241.870 ms |

The root median falls 26.7%. Each deferred iteration leaves 54 leaf menus and
968 row records out of initial native registration. The largest leaf remainder
contains 51 rows. Largest per-iteration completion times: 3.375, 3.091, 2.641,
2.554, 2.790, 2.579, 3.712, 2.718, 3.629, 3.122 ms. These measurements support a
short normal preparation span, not an unconditional scheduling guarantee.

The inline-table experiment uses the exact 35482-byte shipped registry, with
file reading outside the interval, two warm-ups and twenty samples per process.
Strict comma/nesting validation remains unchanged. ASCII bare keys with basic
quoted strings or bare scalar values skip the subsequent equals and dotted-key
scans; all other shapes use the existing parser and caller-specific decoder.
Registry schema validation remains unconditional.

| Registry parse and validation | Median / p95 / maximum wall    | Median process CPU |
| :---------------------------- | :----------------------------- | :----------------- |
| Baseline first                | 227.908 / 251.207 / 280.579 ms | 234.375 ms         |
| Candidate first               | 188.965 / 216.221 / 266.431 ms | 187.500 ms         |
| Candidate second              | 183.722 / 188.600 / 193.175 ms | 187.500 ms         |
| Baseline second               | 227.103 / 259.704 / 383.750 ms | 234.375 ms         |

The component median falls approximately 39–43 ms, 17–19%. GetProcessTimes CPU
measurements have approximately 15.625 ms granularity. Typed parsed sections and
validated migration models have equal fingerprints across all four processes;
31 additional strict/legacy edge outcomes match. A final conservative refinement
restricts the optimized separator to spaces/tabs and anchors the token at its
exact end: 64 additional raw-decoder whitespace outcomes match the frozen
generic parser. Other whitespace retains the caller's original token boundaries.
Duplicate keys, closed dotted parents and scalar types retain their contracts.
There is no persistent cache or new invalidation lifetime.

Local evidence remains under %TEMP%: ergopti-menu-warm-paired.ahk/.json,
ergopti-second-pass-abba.cjs/.json, ergopti-menu-baseline-red.out and
ergopti-toml-slice-probe-bf8b161066c84c3cb6415eff9ef4bc6b. Private configuration
contents and native label images were not printed or committed.

## Budget verdict and rejected alternatives

1. Native menu publication: improved by measured removal of 968 eager row
   registrations. Before-paint completion and background work are both covered.
   Process-start-to-full-root latency remains non-instant and needs fresh live
   evidence after the user's reload; do not equate root preparation with startup.
2. Critical and keyboard paths: prepared leaves are bounded structurally; the
   measured largest normal span is 3.712 ms. Background preparation uses
   one-shot timers and leaves no idle poller. Scheduling tails remain observable.
3. Registry startup parsing: improved with equivalent typed output and unchanged
   validation. Its roughly 4 ms schema validation is not a worthwhile bypass.
4. Tooltip rendering, prediction fetch and hotstring sends: instrumentation and
   span reuse from the preceding pass remain in place. No new all-event median
   or tail estimate was collected here; censored slow-path logs cannot supply it.
5. Prefix priority resolution: repeated case-variant resolution is confirmed
   work, but no measured saving was established in this pass. Do not introduce a
   whole-rebuild cache without a generation fence.

Reject serializing native Menu handles across reloads, changing input readiness
before hotstring registration completes, recreating a loading window and the
unmeasured substring-slicing parser proposal. The latter preserved output but
had inconsistent performance, unlike the measured simple-member branch.

## Verification and delivery

The exact original renderer from c4f41212f fails the new publication assertion:
expected one real leaf row at root publication, observed four after normalization.
The changed renderer passes. Behavioral coverage checks native prepaint delivery
before timer arming, callback tokens, row states, separators, nested ownership,
depth limits, root retirement/reuse, failure, reentry, pause/resume, one-shot timer
drain, shutdown and refused publication. The TOML tests preserve all three scalar
decoder contracts.

The complete AHK unit/meta suite passes 7731/7731; its execution manifest confirms
every terminal result. After the final whitespace refinement and its additional
behavioral regression, the focused TOML suite passes 122/122. The five pure-engine
E2E expansion scenarios pass, as does the isolated real-entry startup smoke. All
40 declared outputs of 23 generators match their owners' live output. All 1770
AHK files pass BOM/LF; the complete production include graph compiles; final
strict conventions and changed Prettier-owned files pass.

The JavaScript suite executes 349 checks and initially reports seven failures.
The new leaf profiler's missing inventory entry is corrected; its focused gate
passes with all 29 HotPath segments and 19 early stamps declared and emitted.
The other six failures match the independently reproduced initial-baseline host
issues documented in the preceding report: Linux installed-layout discovery,
macOS signing Bash replay, Ollama bootstrap timeout, Ollama network-policy path
resolution, release-install Windows paths and the missing HS-274 Python
interpreter. The full formatting gate also retains 15 unchanged baseline files
and the installed Ruff-version mismatch. The overall selected verification is
therefore not all green; these unrelated files are preserved.

No push is authorized or performed.
