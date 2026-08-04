# logger (shared spec)

## Purpose

Cross-driver specification and test vectors for the 8-variant logger contract.

Three implementations must conform: `windows/lib/logger.ahk` (1 077 l),
`macos/lib/logger.lua` (1 145 l) and `_shared/lua/logger/init.lua` (281 l, the
platform-neutral core). Conformance to the **line format** is verified by replaying
`test_vectors.json` from each driver suite — `windows/tests/unit/test_logger.ahk` and
`macos/tests/unit/lib/test_logger.lua`. There is no `_shared/core/domain/Logger.spec.js`;
that file has never existed, and no behavioural corpus covers the rest of the spec
(severity filtering, ring order, forced flush, dedup, date rollover) — adding one is
still to be written.

> ⚠ The shared core is currently consumed by **Linux only**, through
> `logger/shim.lua`, and the Linux driver installs no sink — so every `Logger.*` call
> on Linux reaches a 200-entry ring buffer and is discarded. That is a blocker, not a
> design: see B1 in the plan.

The 8 variants are organised on two axes — importance (`DEBUG`/`INFO`/`WARNING`/`ERROR`) and lifecycle role (`Misc`/`Start`/`End`) — giving `debug`, `trace`, `done`, `info`, `start`, `success`, `warn`, `error`.

## Key files

| File               | Description                                                                  |
| ------------------ | ---------------------------------------------------------------------------- |
| `SPEC.md`          | Normative specification for all 8 variants, lifecycle pairing rule, and punctuation conventions |
| `test_vectors.json`| Golden input/output pairs for the formatting contract, consumed by the JS suite |

## Lifecycle pairing rule

`start`/`trace` must always be matched by a corresponding `success`/`done`. An unpaired `start` in the logs signals a silent failure. The `test_logger_pairing.ahk` and `test_logger_pairing.lua` meta-tests warn on imbalanced files at CI time.

## References

`.github/copilot-instructions.md §4` — full logging conventions (when to use each variant, punctuation rules, language requirements).
