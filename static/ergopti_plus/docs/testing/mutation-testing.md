# Mutation Testing — JS Domain Layer

## What Is Mutation Testing?

Mutation testing automatically introduces small, deliberate bugs ("mutants") into
the source code and checks whether the test suite catches them. If the tests still
pass after a mutant is introduced, that mutant "survived" — meaning the test suite
has a blind spot at that code path.

The mutation score is the percentage of mutants that were killed by the tests:

```
mutation score = (killed mutants) / (total mutants) × 100
```

A score of 80% means the tests caught 80% of the artificial bugs Stryker generated.
Coverage-based metrics (line, branch) do not measure this — a line can be executed
without any assertion checking its output.

## Why We Use It

The JS domain layer (`static/drivers/_shared/domain/`) contains the authoritative
reference algorithms for Registry tail-char bucketing, HotstringMatcher, and
Expander logic. These specs are shared across the AHK and Hammerspoon drivers; a
silent regression in the reference algorithm propagates to all drivers.

Mutation testing ensures that the test suite does not just execute the code — it
actually validates the outcomes at every branch. It is the strongest signal we have
that the domain contracts are correctly pinned.

## How to Run

```bash
npm run test:mutation
```

Stryker will:

1. Take a baseline run of `scripts/test-mutation-targets.cjs` to confirm all tests
   pass with the original code.
2. Generate mutants from the files listed in `stryker.config.mjs` under `mutate`.
3. For each mutant, run the test script against the mutated code.
4. Produce an HTML report at `reports/mutation/mutation.html`.
5. Print a summary to the console.

The run exits with a non-zero code if the mutation score drops below the `break`
threshold (currently **50%**).

## Configuration

The configuration lives in `stryker.config.mjs` at the project root.

| Setting          | Value                                        |
|------------------|----------------------------------------------|
| Test runner      | `command` (runs `node scripts/test-mutation-targets.cjs`) |
| Mutated files    | `static/drivers/_shared/domain/**/*.js`<br>`static/drivers/_shared/ports/**/*.spec.js` |
| Excluded         | `_generated/`, `node_modules/`               |
| Report output    | `reports/mutation/mutation.html`             |
| Threshold: break | 50% — run fails below this score             |
| Threshold: low   | 65% — score shown in orange in the report   |
| Threshold: high  | 80% — score shown in green in the report    |

## Current Baseline

The mutation test infrastructure was introduced in item 5.3.3. Run
`npm run test:mutation` once after setup to establish the baseline score and
record it here.

## Reading the Report

Open `reports/mutation/mutation.html` in a browser after a run. The report shows:

- **Killed** (green): the mutant was detected — the test suite is effective here.
- **Survived** (red): the mutant was not detected — a test covering this outcome
  is missing or too weak.
- **No coverage** (gray): no test executed this code at all.
- **Timeout** (yellow): the mutant caused an infinite loop or extreme slowdown.

Focus investigation on **Survived** mutants. For each one, ask:

1. Is the surviving mutation in a path that genuinely needs a new assertion?
2. Or is the surviving line unreachable dead code that should be removed?

## Threshold Policy

| Score     | Meaning                                       | CI action  |
|-----------|-----------------------------------------------|------------|
| < 50%     | Test suite provides inadequate mutation cover | Build fails |
| 50 – 64%  | Low coverage — investigate survivors          | Warning    |
| 65 – 79%  | Acceptable — continue improving               | Pass       |
| ≥ 80%     | Strong coverage                               | Pass (green) |

When adding new domain logic, add corresponding tests to
`scripts/test-mutation-targets.cjs` that assert the boundary conditions of the
new code. The goal is to keep the score in the green band (≥ 80%).
