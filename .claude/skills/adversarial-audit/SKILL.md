---
name: adversarial-audit
description: Protocol for an adversarial robustness audit of a driver — the four guarantees, the module-then-flow method, loop-until-dry, and the proof discipline every finding must satisfy. Includes the evidence rule, learned the hard way: re-derive every artifact you cite before citing it. Use when asked to audit, harden, stress or hunt for latent bugs.
---

# Adversarial audit

Adopt an adversarial stance: the goal is not to confirm the code works, it is to
find the input, state or timing that breaks it.

## The four guarantees

Audit against these, and state which one each finding violates:

- **G1 — Robustness.** No unhandled exception, crash or keyboard lock-up in *any*
  state: normal, suspended, paused, mid-layout-switch, mid-config-reload,
  updater-poll, cold start, first boot.
- **G2 — No missing output.** No silent no-op: every user action produces its
  effect or a loud failure.
- **G3 — No races.** Every async boundary (timer, hook, InputHook, HTTP, watcher)
  is safe against reentrancy and out-of-order completion.
- **G4 — No lag.** No perceptible latency on any hot path.

## Method

1. **Map the entry points** — every hotkey, hook, timer, watcher, menu action,
   external trigger.
2. **Audit module by module**, then **flow by flow** end-to-end. Module-local
   review misses the interaction bugs, which are the expensive ones.
3. **Question every async boundary.** What happens if it fires twice? Out of
   order? While suspended? Before init? After teardown?
4. **Loop until dry.** Keep sweeping until two consecutive passes surface nothing
   new. A fixed finding count means you stopped early, not that the code is clean.

Bug classes worth a dedicated sweep: unguarded map/table access, state read
before init, load-time vs runtime registration, missing suspend guards, swallowed
exceptions, non-reentrant handlers, sync I/O on a hot path.

## Proof discipline — every finding must carry

1. **A concrete repro sequence** — the exact steps and state.
2. **The root cause**, not the symptom.
3. **Why it is silent today** — what swallows the error or hides the no-op.
4. **Severity + confidence**, stated separately.
5. **A regression test encoding the root cause** (see `ship-fix`, `meta-test`).

A finding without a repro path is a hypothesis. Label it as one.

## The evidence rule — read this twice

**Re-derive every artifact you cite, from the artifact itself, before citing it.**

The first 2026-07-20 audit shipped a full performance section — worst-case
timings, a count of "3 081 `[HotPath] Slow` lines", quoted timestamps — that was
entirely unreproducible. Zero lines containing `Slow` or `HotPath` exist in any
log; the log quoted for a "double boot" window starts hours after that window.
The numbers came from a sub-agent's report and were passed through as measured.

Consequences to internalise:

- **Never present a sub-agent's or tool's output as measured evidence** without
  opening the artifact yourself. Aggregating an unverified claim launders it.
- **Cheapest possible check first.** `awk 'index($0,"Slow")>0{c++} END{print c+0}' <log>`
  — if it prints 0, there was no measurement.
- **Label the provenance of every claim.** "Derived from reading the code" is a
  perfectly respectable basis for a finding. Dressing it up as a measurement is
  not. G4 in particular is unmeasured on this driver unless you have a log line
  to quote.
- Where logs live: the driver writes to `<ConfigDir>/ahk/logs/`, with a dedicated
  errors-only sink and 14-day retention. Files found elsewhere may be **test
  harness output** rather than driver output — check before attributing them.

## Deliverable

Unless asked otherwise: `AUDIT_<SCOPE>_<YYYY-MM-DD>.md` at the repo root, with
executive summary, findings by severity, performance (with provenance labelled),
PROJECT_MEMORY watch-list status, and a coverage register of what was and was not
examined. Be explicit about coverage gaps — silence reads as "covered".

## Constraint

Never propose weakening or deleting a test to make a change pass.
