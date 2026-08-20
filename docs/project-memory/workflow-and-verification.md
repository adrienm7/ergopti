<!-- docs/project-memory/workflow-and-verification.md -->

# Workflow and verification memory

## Repository safety

### feedback-commit-push

Never push `dev` or `main` without explicit approval in the current
conversation. Local commits do not imply release approval.

### feedback-test-before-merge

Live-driver fixes stay on their branch until the maintainer has exercised them
in the real application. Automated tests cannot model every keyboard host.

### feedback-stash-drop-by-index-trap

Stash indices move after every deletion. Re-resolve the exact stash object id
before dropping another entry; never iterate destructive operations over stale
numeric indices.

### project-git-stash-in-this-checkout-pops-a-stranger

This checkout may contain stashes created by other worktrees. Inspect stash
parents and paths before applying or dropping one.

## Verification

### feedback-regression-tests

Every requested bug fix needs a regression test for its root cause. A source
scan is appropriate only when behavior cannot be called directly.

### feedback-local-gate-mirrors-ci

Use the repository verification planner and run every selected gate. A green
subset is not a green change, and the supported Node engine floor matters.

### project-gate-scripts-must-be-wired

A script under `tools/test/` is not a gate until the normal suite invokes it.
When adding a guard, prove it is wired into the command developers actually run.

### project-source-scan-loops-need-a-floor

A scan that finds zero subjects is a false green. Assert a meaningful minimum
match count before asserting that every match is valid.

### project-source-scanning-guards-must-strip-comments

Source-policy tests must distinguish executable code from comments and strings,
otherwise documentation can trigger failures or make a forbidden token appear
covered.

### project-corpus-harness-must-model-the-matching-rule

Corpus tests must use the production matching semantics, including boundaries,
case flags, and precedence. A simplified oracle can bless the wrong behavior.

### project-corpus-harness-must-not-decide-the-answer

Expected values must be independent of the implementation under test. Do not
derive both the answer and the assertion through the same production helper.

### project-a-green-probe-can-mean-redundant-guards

If a mutation probe remains green, determine whether another guard catches the
same defect before calling the test vacuous.

### project-hs-partial-fixes-and-false-green-tests

For lifecycle bug classes, test every construction, activation, callback, and
teardown sibling. A test covering only the originally reported call site can
stay green while the same invariant remains broken elsewhere.

### project-a-test-must-own-every-module-its-subject-asks

Isolated tests must stub or reload every module their subject imports. Accidental
module-cache state makes suite order part of the result.

### project-a-boolean-return-that-means-two-things-hides-a-stale-test

Do not overload one boolean with operational success and state change. Tests can
otherwise pass while checking the wrong contract.

### project-drift-guard-precondition-not-a-flake

Drift guards may require generated prerequisites or a clean index. Establish and
report those preconditions explicitly instead of retrying a deterministic red.

### project-release-gates-scan-versioned-input

Parity and release scans enumerate the Git index. Untracked personal/runtime
files must not alter release evidence.

### feedback-ahk-suite-needs-temp-space

The AHK runner writes process-specific results under `%TEMP%`. Low free space can
produce misleading assertion failures; check the newest result file and disk
space before debugging the test body.

### project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism

The Windows AHK suite runs on this machine even when the launcher returns before
the child. Read the newest `%TEMP%/ergopti_test_results_*.txt`; do not declare the
suite unavailable.

## Audit and documentation evidence

### project-audit-findings-are-hypotheses

An audit finding is a hypothesis until reproduced against current source and
tests. Severity language is not evidence.

### project-audit-evidence-must-be-reproducible

Keep the exact command, subject count, and failing observation for audit claims.
Reject claims that depend only on a stale line number or narrative.

### project-audit-tracking-artifacts-are-unreliable

Audit Markdown becomes stale quickly. Once findings are closed, delete the
tracking artifact and retain only durable invariants here or in tests.

### project-plan-entries-go-stale-faster-than-code

Re-measure TODO and plan claims before acting. Code movement and prior fixes make
old counts unreliable.

### project-decided-do-not-re-raise

Do not repeatedly reopen measured and rejected proposals unless the relevant
implementation or evidence changed.

### project-generated-trees-are-not-reducible

The checked-in `_generated/` trees were measured and found to have consumers.
Treat them as generated contracts; revisit only with new dependency evidence.

### project-menu-manifest-json-is-generated

Edit the menu manifest's canonical source, not generated JSON. Run the owning
generator and its drift guard.

### project-md-gate-needs-eol-lf

Byte-compared generated Markdown needs `eol=lf`; otherwise a Windows checkout can
fail despite identical text.

### project-heredoc-normalises-trailing-newlines

Shell heredocs append a newline. Use exact-stdin helpers when payload bytes or a
missing terminal newline are part of the contract.

### project-python-slice-replace-can-shred-a-file

Do not perform broad scripted slice replacement without heading-based matching,
a dry run, corruption checks, and before/after structure comparison.

### project-crlf-in-worktree-is-not-a-repo-defect

Distinguish checkout line-ending conversion from bytes stored in Git before
reporting drift.
