# logger (shared spec)

## Purpose

Cross-driver specification and test vectors for the 8-variant logger contract.

Three implementations must conform: `windows/lib/logger.ahk` (1 077 l),
`macos/lib/logger.lua` (1 145 l) and `_shared/lua/logger/init.lua` (281 l, the
platform-neutral core). Conformance to the **line format** is verified by replaying
`test_vectors.json` from each driver suite — `windows/tests/unit/infra/logger/test_logger.ahk`,
`macos/tests/unit/infra/logger/test_logger.lua` and
`linux/tests/unit/infra/logger/test_logger_contract.lua`. There is no `_shared/core/domain/Logger.spec.js`;
that file has never existed, and no behavioural corpus covers the rest of the spec
(severity filtering, ring order, forced flush, dedup, date rollover) — adding one is
still to be written.

> The shared core is consumed by **Linux** through `logger/shim.lua` and by the macOS
> driver through `infra/logger.lua`. Linux installs its file sink with
> `infra/logger_sink.lua`, so every `Logger.*` call reaches the log files; the sink and the
> vector replay are pinned by `linux/tests/unit/infra/logger/test_logger_sink.lua` and
> `test_logger_contract.lua`.

The 8 variants are organised on two axes — importance (`DEBUG`/`INFO`/`WARNING`/`ERROR`) and lifecycle role (`Misc`/`Start`/`End`) — giving `debug`, `trace`, `done`, `info`, `start`, `success`, `warn`, `error`.

Beside them, one evidence entry point (`LoggerEvidence` / `Logger.evidence`, SPEC § 4.3) writes an INFO line that the dedup and repeat-collapsing layers never withhold. Use it only for result records a person is asked to send back (field checks, probes).

## Key files

| File                | Description                                                                                     |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| `SPEC.md`           | Normative specification for all 8 variants, lifecycle pairing rule, and punctuation conventions |
| `test_vectors.json` | Golden input/output pairs for the formatting contract, consumed by the JS suite                 |

## Lifecycle pairing rule

`start`/`trace` must terminate with `success`/`done` or an explicit failure or cancellation outcome. An unpaired start can signal a silent failure. Hammerspoon expander and prediction-engine integration tests assert the emitted lifecycle events, including cross-module completion and failure paths; the Windows `test_logger_pairing.ahk` meta-test checks file-level pairing.

## References

[`SPEC.md`](SPEC.md) is the normative logging contract. Repository-wide
language and delivery rules live in
[`AGENTS.md`](../../../../../AGENTS.md).
