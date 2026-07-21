---
name: verify-change
description: Prove a change is safe before committing it — run the gates that actually cover what you touched, not the ones that happen to be quick. Includes the file-to-gate map (a port map is checked by the JS gate, never by the AHK runner) and the two silent-failure pre-checks. Use after ANY edit, and always before a commit.
---

# Verifying a change

A green suite is not evidence unless it is the suite that covers what you
changed. The AHK runner and the JS gate cover **disjoint ground**.

## 1. Let the tool pick the gates

```bash
node ./tools/test/verify-change.cjs           # run every gate this change needs
node ./tools/test/verify-change.cjs --plan    # just show which gates, and why
node ./tools/test/verify-change.cjs --all     # the full local gate, no reasoning
node ./tools/test/verify-change.cjs --range=origin/dev..HEAD
```

It reads the working tree (or a range), maps each file to the gates that can
catch a regression in it, prints that reasoning, then runs them and exits
non-zero on failure. Prefer it over remembering the table below.

## 2. Two silent failures it checks first

Both are instant, and both describe bugs that a **passing** suite hides.

- **A test file that `run_all.ahk` does not `#Include` never runs.** The suite
  reports a pass that proves nothing about the fix it was written for.
- **`_DriverFuncBody("Name")` returns `""` for a name it cannot find**, so every
  ABSENCE assertion built on it passes vacuously. AHK v2 makes this sharper than
  it looks: a call to a function that does not exist is *not* a load-time error —
  the name resolves as a variable — and production call sites are usually wrapped
  in `try`, so a typo or a half-finished rename yields a green test, no error and
  no log line anywhere.

Guard every source-scanning test with `Assert(Body != "", …)` for this reason.

## 3. The file-to-gate map, and why each pairing exists

| You touched | Gate that catches it | Why it is not obvious |
| --- | --- | --- |
| any `.ahk` | `test:ahk-encoding` | a lost BOM or a stray CRLF breaks the parser in ways the error message does not explain |
| `windows/**.ahk` | AHK `run_all.ahk` | the unit + meta suite |
| `windows/**.ahk` outside `tests/` | AHK `e2e/run_e2e.ahk` | behaviour, not just structure |
| an `ADAPTER_*` map, `_shared/core/ports/**` | **`test:js`** | port compliance runs ONLY in the JS gate |
| `_shared/**`, any shared constant | **`test:js`** (+ `test:hs`, `test:linux`) | single-source and cross-driver parity checks |
| `locales/**`, any user-facing string | **`test:js`** | the translations audit |
| `macos/**` | `test:hs` | — |
| `linux/**` | `test:linux` | — |
| section banners, anything | `lint:conventions:strict` | already enforced by the pre-commit hook |

**The row that has actually bitten us:** adding one name to an `ADAPTER_*`
contract map left the AHK suite at a full 3380/3380 green while the
cross-driver port contract was broken. `test:js` was the only thing that saw it.
That map declares the port every driver must satisfy — a Windows-only helper
belongs in the adapter file but **not** in the map.

## 4. What "the full local gate" means

`npm run test:js` is the one that gets skipped and the one that matters: it wraps
the pinned-source-read ratchet, `lint:conventions:strict`, port compliance,
priority parity, the translations audit and the TOML format check. **A green AHK
suite can still ship a red CI.**

If `test:js` reports fewer than 66 checks or any `MODULE_NOT_FOUND`, the gate did
not run — install dependencies first.

## 5. Before committing

Run the gates, then follow `ship-fix` (regression test encoding the root cause)
and `commit-and-push` (one fix per commit, never push `dev` or `main`). The
pre-commit hook enforces conventions but knows nothing about the suites — it is
not a substitute for this step.
