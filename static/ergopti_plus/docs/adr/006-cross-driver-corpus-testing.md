# 006 — Shared test-vector corpus consumed by all drivers

| Field | Value |
|---|---|
| **Date** | 2025-09-01 |
| **Status** | Accepted |
| **Deciders** | Core team |

---

## Context

Even with a canonical domain spec (ADR-005), each driver test suite ran its
own hand-crafted test cases. This created two risks:

1. **Coverage asymmetry.** A subtle edge case covered by AHK tests might never
   be written for the Hammerspoon tests (or vice versa), so a regression in one
   driver goes undetected.
2. **Vector drift.** When a test case was updated in one driver's suite (e.g.
   a Unicode character was added to the terminator list), the parallel test in
   the other driver was often forgotten, leaving the suites out of sync.

The hotstring and tap-hold subsystems were the two areas with the most
cross-driver divergence history, making them the natural starting point.

## Decision

Maintain **shared test-vector files** under
`static/ergopti_plus/shared/tests/corpus/` in JSON format. Each subsystem has its
own subdirectory containing a `vectors.json` file with a list of
`{ input, expected }` pairs (or the richer format required by the subsystem).

All driver test suites **must** consume these vectors as part of their test run.
A driver that does not pass every vector in the corpus is considered broken.

Current corpus directories:
- `static/ergopti_plus/shared/tests/corpus/hotstrings/vectors.json` — hotstring
  expansion input/output pairs.
- `static/ergopti_plus/shared/tests/corpus/tap_hold/vectors.json` — tap-hold
  timing scenarios and expected key event sequences.

Hammerspoon consumption is implemented in:
- `tests/unit/meta/test_corpus_hotstrings.lua`
- `tests/unit/meta/test_corpus_tap_hold.lua`

## Consequences

### Positive

- Adding a new test case to `vectors.json` automatically exercises both (all)
  driver implementations — zero duplication.
- Regressions introduced in one driver are caught in CI before they ship.
- New drivers (Linux, Espanso) get a full regression suite for free on day one.
- The corpus files are human-readable JSON and can be reviewed without
  understanding any driver-specific test framework.

### Negative / Trade-offs

- Corpus vectors must be driver-agnostic (pure input/output); they cannot
  express driver-specific setup or teardown.
- Each driver must implement a thin corpus-runner adapter that maps vector
  fields to its own test harness.
- Vectors that require OS-level timing (real tap-hold) cannot be represented
  faithfully; the corpus uses synthetic timestamps.

### Neutral

- The corpus format is not versioned yet. If the schema changes, all consumers
  must be updated simultaneously.

## Alternatives considered

| Alternative | Why rejected |
|---|---|
| Duplicated test cases per driver | Proven to drift; the problem this ADR solves |
| Single test suite run under both runtimes | AHK and Lua test runners are incompatible |
| Property-based / generative tests | Too complex for the current team size; deterministic vectors are easier to audit |

## Evidence in the codebase

- Hotstring vectors: `static/ergopti_plus/shared/tests/corpus/hotstrings/vectors.json`
- Tap-hold vectors: `static/ergopti_plus/shared/tests/corpus/tap_hold/vectors.json`
- HS corpus runners: `static/ergopti_plus/macos/tests/unit/meta/test_corpus_hotstrings.lua`, `test_corpus_tap_hold.lua`
