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
