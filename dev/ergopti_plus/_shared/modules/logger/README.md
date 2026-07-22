# logger (shared spec)

## Purpose

Cross-driver specification and test vectors for the 8-variant logger contract. Both `windows/lib/logger.ahk` and `macos/lib/logger.lua` must conform to this spec; conformance is verified by the `_shared/core/domain/Logger.spec.js` suite.

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
