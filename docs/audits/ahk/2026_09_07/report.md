<!-- docs/audits/ahk/2026_09_07/report.md -->

# AHK audit campaign

Base: `f6d387ff85cdbac5cf8ded0c88994bf1948fbd67`.
Scope: `static/ergopti_plus/windows/`.
Worktree: `ergopti-fix-ahk-2026-09-07`, explicitly authorized by the user.

## Plan and coverage

- Audit input, layout, hotstrings, suspension, and preview behavior.
- Audit asynchronous LLM and updater ownership and configuration boundaries.
- Audit metrics projection correctness and measure performance candidates.
- Reproduce each confirmed failure, add a failing regression, fix the entire
  affected class, run selected gates, and create one commit per fix.
- Rebase onto the main checkout before periodic fast-forward integration,
  preserving unrelated changes and every individual fix commit.
- Repeat module and end-to-end sweeps until two consecutive passes find no
  new actionable issue. Document remaining runtime verification gaps.

## Initial evidence

The false-green detector reports zero findings in all six supported categories.
The existing durable reader cache suite passes all nine selected tests against
the base commit. These results do not establish whole-driver correctness.

## Coverage gaps

Interactive keyboard hosts and runtime latency remain unverified. The isolated
full startup smoke passes; input and asynchronous audits remain incomplete.

## Confirmed findings

### AHK-001: early Ollama setup failures crash their error handlers

Medium severity, high confidence; violates G1, G2, and G3. Ping, model-list, and
model-delete handlers initialize `ProcessOwner` after fallible setup inside
their `try` blocks. An earlier exception reaches a `catch` that reads this unset
local, skipping failure delivery and auxiliary-owner retirement.

The `ollama-early-setup-failure` regression selection reproduces both an early
private-directory validation failure and a partial payload write followed by an
exception. Before the fix: 0/2 passing, both fail with an unset local in
`ollama_http.ahk`. After initialization moves before setup: 2/2 passing, covering
all three request kinds, owner retirement, failure values, and artifact cleanup.

Run with `AutoHotkey64.exe /ErrorStdOut tests/run_all.ahk
--only=ollama-early-setup-failure` from the Windows driver directory. The
directory test uses an invalid fixture nonce, so no child process or network
request can start.

## Candidates requiring reproduction

- Buffer truncation before matching may reject maximum-length hotstrings.
- Curl's delayed shell expansion may alter literal exclamation marks in paths.
- The updater's tray-message handler appears to treat unrelated balloon clicks
  as update actions; screenshot and other notification owners need examination.

These are source-derived hypotheses, not yet confirmed findings or latency
measurements. No performance verdict is claimed from the current evidence.

## AHK-002: identity hotstrings suppress actual edits

Medium severity, high confidence; violates G2. The no-op guard compares the
replacement to the registered trigger after winner selection. A literal
case-insensitive `abc` to `abc` must normalize typed `ABC`, and a consumed
ending space still changes the output. Both were discarded before dispatch.

The three `hse-actual-noop` behavioral regressions fail before the change and
pass afterward. The priority case proves that a genuine identity winner still
masks lower-priority entries. A fourth case checks conformity, interpreted Send
syntax, raw callbacks, dynamic replacements, and stripped typography framing.
The shared corpus already defines identity in terms of what was typed.

The independent review found no blocking defect. The final regression rerun
also checks the exact emitted `{BackSpace 3}{Text}abc` and
`{BackSpace 4}{Text}abc` edits, so a correct buffer cannot hide incorrect output.

## Verification and integration notes

`a3f57ca21` fixes AHK-001 and is integrated into `dev` by fast-forward after a
rebase check. All 5,387 unit/meta tests, entry compilation, 5 e2e cases, encoding,
and strict conventions passed. The unrelated uncommitted cache file retained
the same SHA-256 across integration.

The audit workflow's `verify-commit` rejects the explicitly authorized alternate
worktree because it only accepts the canonical sibling path. Manual Git
inspection verifies the audited ancestor, one-parent commit, single finding
trailer, and the production-plus-regression diff; neither old worktree
registration was modified to satisfy the tool.

The first JS run had 202/207 passing checks. Its five failures were the old Node
runtime and the default WindowsApps Bash failing to enumerate Git-tracked Linux
sources, plus dependent generators. A checksum-verified temporary Node 22.22.2
and Git Bash resolve the runtime check and standalone Linux assembly. The full
gate is being repeated with that process-local environment.

`97b864459` fixes AHK-002 and is also integrated into `dev` after rebase and
fast-forward checks. The full AHK suite passes 5,391/5,391 tests; compilation,
5/5 e2e cases, encoding, strict conventions, and the strengthened four-test
selection pass. The unrelated file again retained its SHA-256.

With Git Bash on PATH the RTK fixture discovers the relative command `sh`,
then removes its directory from the child PATH and cannot spawn it. This
`null !== 23` assertion reproduces in the main checkout before AHK-002. The
same RTK test passes with pinned Node and the original PATH, where its existing
Git installation fallback resolves an absolute shell path. This is a test
environment issue, not a driver regression; no assertion was relaxed.

The repeated JS run finishes at 202/207. Besides the RTK fixture, four checks
depend on the Linux assembly step that stops while copying `_shared` under the
pipeline's 60-second limit. Standalone assembly succeeds with all 47 required
files and 71 UI assets present (613 files total). The Linux builder and pipeline
are unchanged by either fix. The full gate remains red; this report does not
claim a green JS suite or completed generator-drift verification.

The full isolated AHK startup smoke also passes within both JS runs. This covers
the fresh/existing-config auto-execute harness, not interactive keyboard hosts
or the historical runtime's measured latency.
