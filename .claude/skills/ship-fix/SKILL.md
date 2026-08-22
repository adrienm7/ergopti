---
name: ship-fix
description: Fix a bug from root cause through regression proof and local commit. Use for error reports and requested corrections.
---

# Shipping a fix

No fix is complete until its regression test is written, runs, and is green.
This is `.github/copilot-instructions.md` §5.9 — a hard project rule, not a
preference.

## 1. Before touching code

Read `docs/PROJECT_MEMORY.md` for the area you are about to change. It is the
in-repo record of foot-guns and invariants that have already bitten this
codebase; several "new" bugs are documented recurrences. See the
`project-memory` skill.

## 2. Fix the root cause

Find *why* the failure is possible, not just where it surfaces. A fix that makes
the symptom disappear while leaving the mechanism intact will regress under a
slightly different trigger.

Ask explicitly: **why was this silent until now?** A bug that produced no log,
no error, no visible failure usually means a swallowed exception or a missing
guard — that silence is itself a second bug worth fixing (§5.3, fail fast).

Check whether the same mistake exists at sibling call sites. Per
`project-ahk-invariant-incomplete-application` in PROJECT_MEMORY, the recurring
pattern here is the ONE missed sibling site — audit the whole class.

## 3. Write the regression test

It must **fail before the fix and pass after it**. A test that passes against the
unfixed code proves nothing, so prove it rather than assume it:

```bash
git stash push -- <the SOURCE files only, never the test>
AutoHotkey64.exe tests/run_all.ahk --only "<slug from the test name>"   # expect exit 1
git stash pop
```

Stash the source, never the test — stashing both proves nothing, and it is the
easy mistake to make. Put a stable slug in the test name (`(perf-2026-07-21)`,
`(llm-cancel-under-critical)`) so `--only` can replay exactly that case in
seconds instead of the whole suite.

Read the failure message when it goes red. If it fails for a reason other than
the bug — a missing constant, a typo in a symbol name — the test is not yet
encoding the root cause.

Put it in the suite covering the affected layer:

| Layer | Location |
|---|---|
| Windows AHK driver | `static/ergopti_plus/windows/tests/` (`unit/`, `meta/`, `startup/`, `e2e/`) |
| macOS Hammerspoon | `static/ergopti_plus/macos/tests/` |
| Cross-platform / JS | `tools/test/` |

**Encode the root cause, and exploit the harness so a regression actually
fails.** Canonical example: the `DYN_HOTSTRINGS_DEFAULT_DELAY` startup crash came
from a menu-build global living in the late-loaded `modules/hotstrings.ahk`
instead of the early `hotstrings_config.ahk`. The guard test asserts the constant
is defined — and works precisely because the AHK suite loads
`hotstrings_config.ahk` but NOT `modules/hotstrings.ahk`, so moving it back makes
the constant undefined and fails the test.

Guard tests should enumerate the **whole class** of call sites, not the single
site the bug was found at.

For tests that scan driver source, see the `meta-test` skill — there are
non-obvious traps and a CI ratchet.

## 4. Run the full local gate

```bash
npm run test:js            # 66 checks — the umbrella CI gates on
npm run test:ahk-encoding  # every .ahk is UTF-8 BOM + LF
AutoHotkey64.exe static/ergopti_plus/windows/tests/run_all.ahk
AutoHotkey64.exe static/ergopti_plus/windows/tests/e2e/run_e2e.ahk
```

Add `npm run test:hs` (macOS) or `npm run test:linux` when those drivers are touched.

`npm run test:js` is the one that gets skipped and the one that matters: it wraps
the pinned-source-read ratchet, `lint:conventions:strict`, port compliance,
priority parity, the translations audit and the TOML format check — none of which
the AHK runner knows about. A 3212/3212 green AHK suite can still ship a red CI.

**If `test:js` reports fewer than 66 checks or any `MODULE_NOT_FOUND`, the gate
did not run.** Install deps first — see `feedback-local-gate-mirrors-ci` in
PROJECT_MEMORY for the `engine-strict` / Node-floor trap.

## 5. Never weaken a test to make a change pass

If an existing test now fails, the default assumption is that **your change is
wrong**. Only after proving the test encodes a premise the fix deliberately and
correctly changed may you rewrite it — and then you re-encode the invariant at
its new home rather than deleting it. Deleting or loosening a regression test is
never the answer. The suite must grow strictly stronger over time.

## 6. Commit — one fix, one commit, no push

See the `commit-and-push` skill. Never push `dev` or `main` without explicit
authorization in the current conversation.

## 7. Record what was non-obvious

If the bug taught you something that is not derivable from the code or git
history, add an entry to `docs/PROJECT_MEMORY.md` (see `project-memory`).
