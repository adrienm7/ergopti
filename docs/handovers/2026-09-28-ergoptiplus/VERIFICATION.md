<!-- docs/handovers/2026-09-28-ergoptiplus/VERIFICATION.md -->

# Verification checkpoint

This document separates whole-suite runs, corrected replays and environment
limitations. CI for the published commit remains the final release verdict.

| Check | Latest verified result |
| --- | --- |
| Windows unit/meta | 7,239/7,239 |
| Windows E2E | 5/5 |
| Windows production compile | Complete include graph compiled with Ahk2Exe; live driver preserved |
| Linux unit/meta on the native Windows compatibility launcher | 3,576/3,576 in a fresh full run |
| Linux E2E | 115/115 |
| macOS stubbed E2E | 67/67; one driver-specific vector skipped |
| macOS full Lua 5.4 suite under WSL | 11412 passed, one old boot-oracle failure; corrected module 15/15, giving 11426 distinct passing cases in the composite |
| macOS mandatory boot-boundary guard | 15/15 after repairing a stale count-based oracle; Lua 5.4 and LuaJIT proofs |
| macOS hotstring delay regression cohort | 99/99 after strengthening the boot-result assertion |
| JavaScript registry | 298/303 in the initial complete run; all five failures subsequently resolved below |
| Strict conventions | Zero violations |
| Pending artifact integrity | 47 preserved artifacts inventoried with SHA-256 |

## First published CI

Published checkpoint: `2c73147e12ecdd07dea368461954bb8a5f884687`.
[Root workflow](https://github.com/adrienm7/ergopti/actions/runs/36485979779)
failed: Windows 7238/7239, Linux 3575/3576, and four assertions in the macOS
Swift launcher suite. macOS Lua unit and E2E jobs passed. Site deployment
passed. The layout installer matrix passed its other jobs but rejected a BOM
in the historical `.ahk.txt` documentation snapshot. These CI failures override
any inference of release readiness from the earlier local results. Corrections
and their final workflow verdicts remain to be recorded.

The corrected Linux fixture passed in a complete LuaJIT run (3567 passing;
nine environment failures in unchanged event-loop/watcher modules). This WSL
host has `luv`; CI does not. Replaying those modules and the changed Hotstrings
module with CI dependency availability passed 65/65. This is composite evidence,
not a claim that the first whole-run exit status was zero. The exact BOM shell
check from `linux-layout.yml` also passes after correcting the documentation
snapshot. Swift launcher execution is explicitly deferred to native macOS CI.

Windows correction: 7239/7239 unit checks, 5/5 E2E and full production compile
pass; AHK encoding passes. The strengthened path-identity test fails on the
original implementation and passes after correction. The full JavaScript
registry reports 302/303 with one local build timeout. Its exact domain
pipeline replay then passes all 14 steps without changing any assertion or
timeout. All 303 checks therefore have passing evidence; the initial complete
invocation remains recorded as exit 1. Root and export source hashes stayed
unchanged throughout the registry run.

## JavaScript composite verification

The initial run executed all 303 checks registered by the repository suite.
Three generator checks ran against an existing byte-identical export; the
remaining checks ran in the real checkout. All tracked inputs were hashed
before and after; neither source tree changed during that run.

Four failures were repaired and replayed in the real checkout:

1. Pinned macOS source read: replaced the hardcoded root-file open with the
   existing semantic source-owner helper; 75/75 source-read baseline.
2. Weak delay boot assertion: inspect the actual refusal error and the injected
   delay owner, then check success/failure; false-green baseline remains zero.
3. Linux Ctrl+G evidence: link the new canonical feature to its real readers,
   dispatchers and behavioral tests; no unsupported hardware claim added.
4. Configuration-surface scan: recognize the exact secondary-file writer and
   prove its destination. A different owner, key or destination still fails.
   The undeclared main-configuration baseline remains five.

The fifth failure was a Windows file-lock refusal while rewriting generated
files. The same guard passed on the byte-identical export: all 36 declared
outputs of all 20 generators matched. This is a composite verification, not a
claim that the original root invocation returned success.

## Reproduction after cloning

Use the pinned Node version from `.node-version`, install the lockfile's
dependencies, and follow `docs/TESTING.md` plus the toolchain skills for the
target OS. Run `node tools/test/verify-change.cjs --plan` on the actual changes;
use `--all` for a complete audit of a clean checkpoint. Do not use a range that
is empty after cloning and interpret the resulting no-op as a full audit.

Run generators/JS guards separately from driver readers. Use private HOME,
XDG directories and temporary directories for Linux/WSL replays. The first WSL
Linux and macOS runs used private temporary directories but retained the host
HOME; preserve the isolation caveat from the lane notes. The fresh successful
Linux native rerun used private HOME and all XDG directories.

Real keyboard, Karabiner, desktop-manager, native WebView and installer checks
still require the corresponding real OS. Passing stubbed suites does not replace
those checks. The release workflow also compiles, packages and launches builds
on its target hosts; inspect its actual verdict and assets after publication.
