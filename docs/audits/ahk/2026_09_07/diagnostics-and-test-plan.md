<!-- docs/audits/ahk/2026_09_07/diagnostics-and-test-plan.md -->

# AHK diagnostics and test campaign

The user expanded the bug-fix campaign to include extensive useful debug logs,
fail-fast validation, review of redundant or ineffective tests, and cohesive
test submodules. This work remains alongside the remaining correctness and
performance audit, with atomic commits and periodic integration into `dev`.

## Baseline and scope

- Windows driver and its 1,031 AHK test/harness files.
- Last complete AHK execution: 5,391 passing tests, entry compilation, 5 e2e
  cases, and isolated full startup smoke.
- Mechanical false-green detector: zero findings. Behavioral review is still
  required; this is not proof that all tests are useful or independent.
- Largest suites: navigation owner (4,691 lines), updater (4,411), hotkey owner
  collisions (2,071), personal TOML I/O (1,746), trigger transactions (1,574).
- Other OS worktrees remain owned by the concurrent agent. Shared test tooling
  changes require their cross-driver gates and preservation of current work.

## Work sequence

1. Inventory every AHK suite by responsibility, size, registration, and test
   style. Review duplicates and suspicious tests with production code in view.
2. Audit silent failure paths and state transitions. Add correlated diagnostics
   with operation, phase, request identity, generation, and outcome where useful.
3. Validate invalid internal state at its entry boundary; preserve expected
   cancellation and stale-completion behavior as explicit, observable outcomes.
4. Split cohesive oversized suites into responsibility-based subdirectories.
   First establish that discovery, includes, coverage checks, and verification
   select nested tests correctly. Preserve the registered test-name manifest
   and demonstrate that unchanged regression cases still execute.
5. Replace ineffective assertions only with stronger root-cause coverage. Keep
   valid structural tests where runtime tests cannot observe the invariant.
6. Continue reproducing remaining bugs. Run appropriate gates, commit each fix
   separately, and keep code movement separate from behavior changes.

## Acceptance criteria

- Each diagnostic addition explains a real decision, transition, or failure.
  High-frequency detail stays at DEBUG; repeated faults are bounded. Logging
  must not introduce synchronous keyboard-path I/O or sensitive payload dumps.
- Invalid state fails before side effects, with tests for failure reporting and
  resource ownership. Cancellation is not mislabeled as a successful action.
- No test is removed based on its title or resemblance alone. Record the
  invariant and replacement proof for every consolidation.
- A split preserves test registration, order dependencies where unavoidable,
  root-cause assertions, LF, UTF-8 BOM, and executable coverage.
- Coverage gaps remain explicit; neither test counts nor a clean scanner imply
  zero remaining bugs.

## Current bounded reviews

- Navigation and updater suite boundaries plus nested-test discovery support.
- Auxiliary LLM request diagnostics and failure ownership.
- Personal TOML, persistence transactions, and hotstring configuration test
  quality, including redundant or symptom-only assertions.

All three reviews are read-only; implementation and commits remain sequential
in the AHK worktree.

## Confirmed follow-up work

- Auxiliary request diagnostics landed in `6b403f2`: ping, tags, and delete
  preparation failures carry operation, stage, owner, generation, error type,
  and native code. Regression assertions require one correlated error and
  reject private payload sentinels. Full AHK execution: 5,391 passing cases.
- Empty personal-information alias sections: writer output with an empty
  `[letters]` section retains stale aliases on read. The behavioral round-trip
  fails with one alias instead of zero before the header-presence correction;
  the omitted-section control must keep defaults.
- `_PTIO_LoadsLettersAtomically` resets the cache before its claimed cache
  assertion. Preserve the cache, delete only the owned fixture, and assert
  restored information and aliases plus clone isolation on subsequent reads.
- `verify-change` registration precheck sees only flat unit/meta/startup paths
  and checks text inclusion rather than transitive include reachability. Fix
  this with nested orphan and transitive-registration regressions before
  splitting the navigation-owner suite.
- `LLM_AuxBindResources` accepts noncallable cleanup resources that retirement
  subsequently skips while claiming successful cleanup. Validate the entire
  incoming resource map before publishing any callback; preserve callable and
  zero contracts. Reproduce before implementation.

## Test-review candidates requiring proof

- Hotstring global-delimiter escaping: replace spelling-only assertions with
  serialization/parsing of quote, backslash, and newline values.
- Gesture first/second persistence-failure tests use the same refusing batch
  writer. Check actual invariant coverage before consolidating; partial staging
  belongs in the real TOML transaction tests, not an inert fake.
- Updater timeout/background meta-tests contain hand-written string scanners;
  replace brittle parsing and conditional assertions with shared source
  helpers or behavioral transport observations.
- No redundant navigation-owner lifecycle tests were established. Preserve
  false-return, throw, reentrancy, suspend, and quarantine cases when splitting.

## Navigation-owner module boundaries

Preserve the existing facade and exact declaration/registration order. Nested
cohorts: native port, presentation fixtures, surface ownership, start admission,
quarantine lifecycle, suspend fences, receipt repaint, health recovery, route
binding, no-hook native ABI, and profile receipts. The final shutdown cases
remain with profile receipts. No external test consumes `_LNEO_*` symbols or
depends on the old file body; `run_all.ahk` retains the facade include.

Compare exact ordered test names before and after, not only total counts.

## Implementation checkpoint

- `dd979aff3`: explicit empty aliases now clear the previous map. Red: expected
  zero aliases, observed one; green: empty round-trip and omitted-section
  control. Full suite: 5,392 passing cases, compile and 5 e2e cases.
- `c3b28cb`: cleanup callback candidates fail before any ownership mutation.
  Red: invalid timer callback accepted; green: all four callback fields reject
  malformed candidates while original cleanup still executes once. Full suite:
  5,393 passing cases, compile and 5 e2e cases.
- `3637fbf`: personal-info cache test now removes its own fixture before cache
  reads and asserts both returned maps are independent copies.
- `8f00878`: nested registration precheck shares the full-tree include closure;
  fixture tests cover nested orphans, comments, spaces, transitive includes,
  direct facades, and deletion. Independent review found no new blocker. The
  shared include parser still has preexisting advanced-syntax limitations; this
  change does not claim to implement a complete AutoHotkey parser.
- Full JS checkpoint ran 208 checks. Six failed: the newly introduced missing
  npm alias plus the five previously reproduced shell/build-environment
  failures. The alias was added and its gate rerun successfully. RTK passes
  separately with the original shell-search PATH; Git Bash on PATH triggers
  the existing relative-shell fixture failure. The Linux pipeline still hits
  its existing build timeout and blocks dependent generator/drift gates.
- Navigation split: 11 cohorts, 128–858 original body lines each, plus the
  original facade. Concatenated body SHA256 remains
  `33c28445a374674fff4d8bbd9c30d74ad2b214f21719154f3899b471c8b0b9f1`.
  Registration, encoding and strict conventions pass. Commit `cc5bb52` passes
  all 5,393 cases; their names and execution order exactly match the pre-split
  full stdout manifest. Reassembly preserves every original nonblank source
  line in order; only module headers and blank-line spacing were added.

## Broad duplicate inventory

A read-only lexical inventory examined 4,511 direct literal registrations and
4,863 assertion-containing function bodies. This is not an exhaustive semantic
equivalence proof. Concrete follow-ups:

- `TestTapHold_PauseInvariant` duplicates `_TH_IsConfiguredTrueWhenTapAction`:
  it only checks configured state and never suspends or dispatches. Replace
  its pause claim with actual paused-dispatch assertions, or retire it only
  after identifying equivalent class-wide behavioral coverage.
- `TestCS_ConformSpecIsCaseInsensitive` and
  `TestCS_RegistersLowercaseConformSpec` have identical input and assertions;
  `TestCS_TwoCharAllLetters` covers that specification plus registration count.
- `_LCTC_PingRequiresTransportStatusAndSchema` duplicates the four vectors of
  `_OHTC_PingRequiresTransportStatusAndSchema`. Preserve the dedicated Ollama
  case and the LLM file's other, unique transport cases.
- Two digit-first abbreviation cases have identical names but different
  inputs (`1b` and `1A`); rename the uppercase case instead of deleting it.
- Rejected duplicate hypotheses: helper-body reuse and application-name
  uppercase/lowercase cases are not evidence of redundant coverage.

For the tap-hold replacement, reuse `_THAC_AllKeyCases`,
`_THAC_WithSingleKeyConfig`, and `_THAC_RecordMatrixTap` in the activity-cancel
suite. Establish a fresh gesture and successful active dispatch, then another
fresh gesture whose suspended dispatch returns false without a new callback.
Restore suspension and fixture state in `finally`. Existing source guards and
immediate-modifier wait tests remain useful but do not replace this matrix.
Synthetic key releases during suspension are legitimate cleanup, not a failure
of pause silence.

## Runtime-boundary follow-up

The next integrated wave was rebased onto the concurrent Hammerspoon work:

- `eaaef54c5`: full-length hotstrings retain delimiter/typographic framing,
  typed-case preview context, and the observed left boundary. Seven behavioral
  cases cover the boundary, including an impossible oversized star continuation
  masking a valid completion. Six cases failed before their corresponding
  corrections. All five buffer truncation sites share the same bounded owner.
- `a7c44a01a`: the curl command wrapper added one redundant opening quote;
  all five callers already quote the executable. Real exact-handle process
  tests failed even for a plain path with exit 1 before correction. They now
  prove successful file-only transfers and missing-file failures, with exact
  body bytes and matching process/receipt exit codes 0 and 37.
- `001f61f50`: the misleading pause accessor test is replaced by an actual
  active/suspended dispatch matrix for all fourteen registered key identities.

The change-scoped gate passed 5,401 AHK cases, whole-driver compilation,
encoding, and five e2e cases; strict conventions passed. The first intermediate
buffer run had one brittle source assertion rejecting an additional safe
`Min` bound. That assertion now permits the additional logical-capacity bound
without relaxing the original maximum-trigger-length requirement.

The concurrent branch supplied fixes for the relative-shell RTK fixture and
the per-file-shell Linux copy bottleneck. A fresh full JS run passed all 209
checks against the rebased common state; the earlier five environment failures
are resolved, not permanent exclusions.

### Remaining literal-path defect and verified design

After correcting the redundant quote, paths containing literal `!CD!` or
`%CD%` are still interpreted by cmd rather than preserved as data. A file-only
diagnostic reproduced missing body/status/exit artifacts; escaping delayed
expansion alone fixes `!` but does not fix `%`.

A separate native-shell probe succeeded for plain, exclamation, caret,
percent, combined metacharacters, and Unicode paths, with both exit 0 and 37:
keep a fixed shell program and pass the curl command and terminal paths in a
private child environment. Commit `b1d8deb` implements this boundary without
mutating the parent environment with `EnvSet`.

Implementation boundary: `_LLM_CurlOwnedCommand` returns a structured launch
record; `_LLM_CurlArtifactRun` accepts that record and constructs a Unicode,
double-NUL-terminated inherited environment with case-insensitive overrides,
preserving drive-current-directory entries. Existing direct command strings
remain valid for nonwrapped launches. Exact HANDLE acquisition, cleanup, and
exit-receipt ordering must remain unchanged. This follows the native
[CreateProcessW environment contract](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).

Real launcher regressions cover combined path cases, conflicting reserved
environment entries, and parent-environment isolation. The fixture waits on
the exact HANDLE and releases it through production cleanup. Mock run ports
accept the command value opaquely. Malformed launch records must fail before
publishing a PID or owner. The full suite passed 5,407 cases, whole-driver
compilation, five e2e cases, encoding, and strict conventions. Four of the five
native path/isolation cases failed before the fix; all five now pass.

An additional probe with an inherited `ERRORLEVEL=999` forces both successful
and failed transfers to publish exit 999. The child launch must remove that
ambient shadow of cmd's dynamic error code before capturing curl status, while
leaving the parent environment unchanged. This is covered by the isolation
regression; reserved path variables are not the only inherited collision.

### Proven duplicate removal

Removed two conform-registration cases whose identical input and exact-spec
assertion are covered by the retained count-plus-spec case. Preserved both
digit-first inputs and renamed the uppercase case to make failures unambiguous.
Removed duplicate ping and deletion terminal vectors from the LLM suite;
the dedicated Ollama suite retains all eight vectors and completion-callback
checks. The unique LLM usage-owner case remains.

The complete AHK suite passed 5,403 cases. An exact ordered manifest comparison
against the preceding 5,407-case run proves precisely four removals and one
duplicate-title rename, with no other missing, added, or reordered test names.
Encoding, registration prechecks, and strict conventions passed.

## Behavioral test repairs and native stop ownership

Three further atomic commits are integrated locally:

- `0d193a4`: delimiter escaping now writes and reparses a real detached TOML
  candidate. Removing either field's escape call fails that field's roundtrip.
  Payloads contain quotes, backslashes, and attempted section injection.
- `e7a71c3`: the full-save LLM fixture initializes its own `user_profiles`
  instead of relying on preceding tests. The filtered `detached` run changes
  from 30/31 to 31/31; the original menu reference is restored afterward.
- `6b61367`: native Stop now resets the global profile retry registry rather
  than a shadowing local. A real refused profile effect leaves one stale entry
  before the fix. The regression distinguishes refused Stop, which must retain
  the budget, from acknowledged Stop, which must clear it. This is stale-state
  retention across lifecycles, not ordinary cross-receipt budget contamination:
  profile tokens remain monotonic.

The full gate passed 5,404 AHK cases, compilation, five e2e cases, encoding,
strict conventions, and 209 JS checks. One first JS invocation selected the
WindowsApps WSL `bash.exe` and failed five Linux-generation checks with an
invalid Windows worktree Git path. Repeating the full JS gate with Git Bash
explicitly ahead of WSL in PATH passed all 209 checks. These are not exclusions.

### Stop diagnostics and timeout test validation

Native Stop diagnostics distinguish refusal, exception, pending drain,
and acknowledged completion. Native status and Win32 error metadata are retained
without recording arbitrary exception text. The real logger-sink test failed
before implementation and passes afterward; a separating DEBUG line prevents
logger dedup from masking a broken owner-level throttle. Pending progress is
not reported as an error. Independent review found no blocking issue.

Updater timeout coverage now exercises both asynchronous preparation factories
and observes the actual four timeout arguments before Send. A variable holding
zero evades the former literal-zero scan but fails the new behavioral test.
Both synchronous fetches retain strengthened structural coverage because they
do not expose a transport factory; missing Send now fails unconditionally.
Review caught the synchronous releases-list sibling before commit, and it was
added to the same guard. The full validation passed 5,405 AHK cases, whole-driver
compilation, five e2e cases, encoding, strict conventions, and 209 JS checks.

### Notification click identity remains unresolved

The updater handler accepts ordinary tray notification clicks. A last-published
callback lease is not an exact fix: native callbacks identify the icon, not the
individual notification. The smallest verified separation uses a dedicated
updater icon/callback identity; an old updater click may still open the currently
available update, preserving existing category semantics. This follows the
[native callback contract](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-notifyicondataw).

An extra notification-area icon is a visual tradeoff, so user input has been
requested before implementation. Do not assume `NIS_HIDDEN` preserves balloon
delivery: the consulted contract does not establish that guarantee. Native
publication acknowledgement, shell restart, cleanup, pause policy, and ordinary
notification isolation all need regression coverage. No wrapper-only fix or
live desktop notification has been shipped as proof.

### Runtime evidence priorities

The resolved runtime main log for September 6 spans 18:12:54.498 through
19:19:02.303. It predates this wave and is not a current-worktree performance
baseline. Its threshold-censored hot-path population includes six TOML writes
(maximum 1,196.85 ms), three HSE feed samples (maximum 13.83 ms), and eleven HSE
dispatch samples (maximum 40.06 ms). These cannot establish whole-population
percentiles, and parent/child segments must not be added together.

That main log has 787 manifest-type rejections plus 25 unknown-leaf rejections.
Read-only inspection confirms a current writer/reader mismatch: ordinary AHK
booleans are emitted as integers, while manifest validation requires lexical
TOML booleans. Batch rewriting also reparses unrelated existing booleans into
AHK integers before emitting them. Reproduce and fix both boundaries without
relaxing the validator or treating every numeric zero/one as a boolean. Numeric
strings, arrays, and precise numbers need preservation controls in this audit.
No personal configuration has been modified.

The first bounded TOML fix preserves unchanged scalar Boolean literals in
fresh writer-owned parsing, using the existing Boolean sentinel. Cached and
fresh public readers retain native values; writer mode rejects either cache
flag before access. The new regression fails on the original writer's `off = 0`
and passes with the fix. It covers detached candidate and actual publication,
numeric zero/one controls, cache isolation, explicit numeric replacement, and
deletion. Existing behavioral fresh-read tests replace a spelling-sensitive
meta assertion. Independent review found no blocking issue.
Validation passes all 5,406 AHK cases, whole-driver compilation, five e2e cases,
the encoding gate, strict conventions, and all 210 shared JS checks.

This does not yet fix newly supplied Boolean values, arrays, numeric-looking
strings, or float precision, and does not repair already corrupted personal
configuration. New-value typing needs a common schema owner at targeted,
full-save, detached LLM, and onboarding persistence boundaries; normalizing only
one UI producer would leave other write paths exposed.

The new-value follow-up now shares the manifest type resolver with the strict
loader. It prepares detached update records at targeted/borrowed/rollback,
full-save, detached LLM, and onboarding boundaries, before injected or production
persistence callbacks. Canonical path identity prevents the targeted gateway
from imposing the configuration schema on unrelated TOML files. Invalid Boolean
values fail before writer invocation and preserve both disk and live state.

Class-wide producer review found WPM Boolean fields still supplying digit
strings, plus foreign-owned category gates and the gesture onboarding marker.
WPM now supplies native Boolean values; foreign owners explicitly retain their
Boolean sentinel. Numeric coordinates and personal-editor digit preferences
retain their distinct contracts. Thirteen focused regressions are split by
typing, transactions, producers, and UI-only structural guards. The three
initial strict-reload cases fail before implementation with only one or two of
four values accepted; all focused cases pass afterward. The onboarding route
has structural, not live-wizard execution, coverage. Independent review found
no blocker and prompted restricting mixed-enum wrapping to integer zero/one.

The first full run exposed an injected encryption writer that used object
truthiness to interpret persistence values. Its rollback oracle must inspect
the actual rendered Boolean literal rather than treating a false sentinel as
true. That oracle is corrected without weakening the compensation-before-
durable-rollback assertion; its six targeted cases pass.

A subsequent 5,419-case AHK run, compilation, and five e2e cases passed, but
review then found a remaining digit-string producer: the real full-save
collector's final `llm.onboarding_seen` override. Two new real-collector tests
fail before correcting that producer and pass afterward. Unlike the injected
collector cases, these exercise loaded LLM state and the final duplicate-key
override. The pending shared JS run was intentionally stopped before this
additional edit; it is not recorded as green. The complete final validation
must cover the resulting 5,421-case state. That final run passes all 5,421 AHK
cases, compilation, five e2e cases, encoding, strict conventions, and all 210
shared JS checks.

The metrics follow-up has a concrete ownership reproduction to implement:
`KLWV_OnFullBuildTerminal` checks the epoch before a yielding first-paint push,
then resolves the window again without a post-push fence. A replacement can
receive stale completion flags; deletion can throw. Capture and retain identity
through prefetch delivery and recheck it before terminal state changes. This
does not yet establish the cause of the historical retry-exhaustion errors.

The metrics delivery reproduction now fails in four original first/full
terminal cases: replacement is incorrectly acknowledged, and removal throws in
the full terminal. The fix retains exact entry identity across sidecar reads,
native posts and diagnostics, propagates expected epochs from ready/retry
callers, and atomically publishes completion flags in a memory-only Critical
section. Independent review caught and closed the post-push/pre-commit timer
window. Thirteen focused cases cover first/full/live/fallback ownership loss,
actual delivery, read-boundary replacement, contained and logged read failure,
and Critical restoration. A spelling-sensitive read-error guard is replaced by
the behavioral error/log test. All targeted cases pass. Final validation passes
all 5,441 AHK cases, compilation, five e2e cases, encoding, strict conventions,
and all 211 shared JS checks.

Numeric-looking TOML strings are the next confirmed loss of type. Five direct
rendering cases and both real write/detached-build round trips fail because
`IsNumber` accepts strings. Dispatching native String before coercion preserves
quoted text, including personal-editor digit preferences and numeric section
names. The six WPM coordinate producers now retain native numeric values instead
of relying on accidental renderer coercion. Twelve targeted cases pass; these
include native number/Boolean controls and all three coordinate producer paths.
An initial detached-build fixture incorrectly expected a String instead of the
documented result Map; after correcting that fixture, its pre-fix failure is the
actual type loss. Full validation passes all 5,472 AHK cases, compilation, five
e2e cases, encoding, strict conventions and all 211 shared JS checks. Arrays and
float precision remain separate outstanding renderer issues.

The same log contains 77 full metrics build retry-exhaustion errors and one
first-paint retry-exhaustion error. Their causes remain untriaged; do not infer
that the user's uncommitted cache optimization fixes them. That file stays
outside this worktree's changes.

The next configuration reproduction confirms that a rejected known preference
can be overwritten by a later full save: a real load of `screen = 0` keeps the
default, then the real writer incorrectly succeeds. An empty `screen =` has the
same result because it previously bypassed validation entirely. Both cases fail
before their corrections. Boot now owns a sticky incomplete-load count; ordinary
candidate reads return local diagnostics without changing that authority. The
common full-state gate covers boot scheduling, full saves and both detached LLM
transactions before admission or quiescence. Targeted edits, onboarding choices
and explicit reset do not serialize the incomplete tree and remain independent.
Partial loads retain valid neighbors but terminate their logger lifecycle with
an error, not success. Eight focused regressions pass, including valid-load and
local-diagnostic controls and both unreadable/rejected LLM admission paths. Tests
are split between load/persistence and LLM boundaries. Full validation passes
all 5,449 AHK cases, compilation, five e2e cases, encoding, strict conventions
and all 211 shared JS checks.
