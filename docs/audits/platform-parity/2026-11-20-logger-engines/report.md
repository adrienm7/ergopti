# Logger engines

Audited source: `ee7102be27` (`dev`). Date: November 20, 2026. Second campaign
in the order of the [2026-11-19 census](../2026-11-19-census/report.md), after
secure-field detection.

## Scope

The three logger engines against the shared contract
(`_shared/core/logger/data/SPEC.md`, the `logger` skill) and against each
other:

- Windows: `windows/core/logger/engine/logger.ahk`;
- macOS: `macos/core/logger/engine/logger.lua`, the native worker
  `macos/launcher/Sources/ErgoptiPlus/LoggerDatagramWorker.swift` (production
  persistence, rotation and retention) and the level restore of
  `macos/init.lua`;
- Linux: `linux/core/logger/engine/sink.lua` and
  `linux/settings/engine/scope/script_settings.lua`;
- shared: `_shared/core/logger/engine/init.lua` (the core macOS and Linux
  run) and `shim.lua`.

Read for each: levels and filters, the three sinks (dated file, errors file,
ring), retention, rotation, dedup and flush, lifecycle pairing, refused writes,
redaction, timing constants and the startup and shutdown flush. The boot
profilers, perf counters, keystroke integrity and the macOS transport's ACK
protocol were read only where they touch a sink. Source reading plus replays
through the real modules (AutoHotkey, Lua 5.4 and LuaJIT under WSL); the Swift
worker was not built here.

Checked and kept:

- **Line format, ring, both suppression layers, evidence records, volume
  counters:** one implementation on macOS and Linux (the shared core),
  mirrored on Windows, already pinned on the three suites by
  `behaviour_vectors.json` and `test_vectors.json`.
- **Redaction:** every durable line is redacted at its sink, body only, prefix
  intact: Windows `_LoggerPrivacyBlob`, macOS `private_line` before the native
  handoff (`prepare_line`), Linux `sink()`. The rings hold raw lines on the
  three, and the crash reports that read them redact the whole record
  (`_shared/diagnostics/engine/reports/crash_report.lua`, `M.redact`). Case
  folding follows the file system: insensitive on Windows and macOS,
  sensitive on Linux.
- **Errors-only file:** WARNING and ERROR, the dedup and repeat summaries of
  those levels included, on the three.
- **Lifecycle pairs in the engines:** `trace`, `done`, `start` and `success`
  are never collapsed on the three (`REPEAT_KEY_BY`, `LOGGER_REPEAT_KEY_BY`).
- **Terminal flush:** Windows `_LoggerOnExitFlush` and `LoggerPrepareShutdown`;
  macOS `begin_async_sink_shutdown` (`Core.flush_repeats(true)`, then the
  native drain); Linux `flush_repeats(true)` on the exit and crash paths of
  `ergopti_hotstrings.lua`. Linux writes every line synchronously, so nothing
  else is buffered there.
- **Timing scalars:** `test-logger-scalars-single-source.cjs` already pinned
  every copy to `[logger]`; the new Linux retry reads `flush_interval_ms`.
  macOS `LOG_PURGE_DELAY_SEC` only defers the early-boot Lua purge, which the
  native worker takes over before input starts.

## Fixed

Each fix has a regression red on the old code. The shared rules are replayed
from one corpus,
[`parity_vectors.json`](../../../../static/ergopti_plus/_shared/tests/corpus/logger/parity_vectors.json),
by `tests/meta/corpus/test_corpus_logger_parity.ahk` (Windows),
`tests/meta/corpus/test_corpus_logger_parity.lua` (macOS and Linux, through
`_shared/tests/corpus/logger/parity_replay.lua`) and
`testRetentionReplaysTheSharedParityCorpus` (the macOS native worker).

| Id     | OS            | Sequence                                                                           | Reference                                                                                                                   | Before                                                                                                                                                                                                                                                     | Regression                                                                                                         |
| ------ | ------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| LOG-01 | macOS         | Boot with no stored level, or with `log_level = "SUCCESS"` (or TRACE, DONE, START) | Windows `LoggerInit`, Linux `script_settings`: the threshold of any of the manifest's eight names, else INFO with a warning | `init.lua` accepted four names and booted at DEBUG otherwise, silently; `overrides.lua` reported the four other declared names as outdated; `Logger.set_level("BOGUS")` selected WARNING; the shared core's `set_level` turned an unknown alias into DEBUG | `level_setting` (14 cases, three drivers); macOS `set_level refuses an unknown name and keeps the level`           |
| LOG-02 | macOS, Linux  | `Logger.info(tag, "value=%d", {})`, or any format error                            | Windows `_LoggerFormatBody`: the template plus `[!! log format failed: … — N arg(s) not substituted]`                       | The shared core wrote the bare template, indistinguishable from a normal line                                                                                                                                                                              | `format_failure` (three drivers)                                                                                   |
| LOG-03 | macOS         | Look for the log of 14 days ago in the evening                                     | Windows and Linux purge a dated file older than today minus 14 calendar days, at any hour                                   | The native worker and the Lua boot purge compared the file's noon with now − 14 × 86,400 s: the 14-days-old pair vanished after noon only                                                                                                                  | `dated_retention` (9 cases, three drivers and the native worker)                                                   |
| LOG-04 | Linux         | Open `ErgoptiPlus_gestures.log` on a day no gesture was logged                     | Windows (`_LoggerInitSubFiles`) and macOS (native purge) remove a topical view last written on another day                  | Kept until 15 days old (mtime older than now − (N + 1) days): the file showed an older day as today's                                                                                                                                                      | `topical_retention` (three drivers and the native worker); `linux-topical-view-stale`                              |
| LOG-05 | Linux, shared | The disk refuses a write, then recovers                                            | Windows keeps the refused lines queued, retries them on its 500 ms tick and reports what its cap dropped                    | Linux retired the main and errors files until midnight and the file never said lines were missing; the shared core discarded a raising sink's error with nothing written anywhere                                                                          | `sink_failure` (macOS, Linux); `a refused main channel reopens after the retry interval and counts what it missed` |
| LOG-07 | shared        | A Lua module whose shim falls back to print                                        | SPEC § 3: `[WARNING]`, a timestamp, a format error kept on the line                                                         | The fallback printed `[WARN]` without a timestamp and let a format error escape into its caller                                                                                                                                                            | `logger shim print fallback`                                                                                       |
| LOG-08 | SPEC          | Read § 4, § 6.3 and the references                                                 | The code                                                                                                                    | § 6.3 promised a forced flush on WARNING (Windows waits for its tick, on purpose); the header and references named `windows/lib/logger.ahk` and `macos/lib/logger.lua`, which no longer exist; LOG-01 to LOG-05 were undescribed                           | Documentation                                                                                                      |

Notes:

- **LOG-01.** `_shared/core/logger/engine/level_setting.lua` resolves a stored
  value from the manifest declaration alone. Linux `script_settings` delegates
  its name and threshold helpers to it, macOS calls it through
  `Logger.apply_level_setting` at both boot points, and Windows keeps the same
  rule in `LoggerResolveLevel`, extracted from `LoggerInit`. The macOS default
  therefore moves from DEBUG to the manifest's INFO, as on the two others; a
  stored DEBUG is unchanged. `LOGGER_DEFAULT_LEVEL` and the corpus default are
  pinned to the manifest by `test-logger-scalars-single-source.cjs`. The
  shared core and macOS `set_level` now accept every variant name and raise on
  an unknown one.
- **LOG-03.** `LoggerRecordSink.datedLogExpired` (Swift) and
  `_dated_log_expired` (macOS Lua) compare calendar days, like
  `_LoggerDatedLogExpired` (Windows) and `dated_log_expired` (Linux). The
  existing Swift retention tests passed only because their clock was fixed at
  noon.
- **LOG-05.** A refused Linux channel is reopened by its first line once
  `[logger] flush_interval_ms` has passed (two lines in a row still do not
  retry, as `retired channel cannot be retried on every line` pins), and the
  reopened file starts with `N lines were not written to the log file while it
refused writes.` The shared core counts the lines a raising sink lost and
  delivers `[WARNING] [logger] N lines were refused by the log sink before this
one (last refusal: …).` after the next accepted line (`sink_refusals()`).

## Open

- **LOG-06 (low, macOS and Linux call sites):** only Windows gates lifecycle
  pairing (`tests/meta/core/logger/test_pairing.ahk`, per file). The same
  per-file count over the Lua sources finds 15 files where an opener
  outnumbers its terminal, among them `modules/keystats/text_cipher.lua` on
  both drivers (« Deriving the at-rest key… » is never followed by a success)
  and macOS `infra/phase_stats.lua` (a `start` closed by `done`, across the two
  axes). Each needs its own reading, so this campaign records it; the
  follow-up is a Lua twin of the AHK gate, once these call sites are paired.

Native receiving: a full disk on Linux (fill a small tmpfs logs folder, log,
free it, log again) and a macOS evening run 14 days after a logged day. The
Swift test runs in the macOS CI job; it was not run here.

## Proof

Commits `a1eea497db` (LOG-01), `1e34f798ff` (the Windows rules exposed for
the corpus, no behaviour change), `5597d1576b` (LOG-02), `692e48d5ce` (LOG-05,
shared), `78659668e0` (LOG-07), `43d9a74f89` (LOG-03), `91ff01bbe7`
(LOG-04), `7c65b7e27e` (LOG-05, Linux) and `33e45dbfac` (the corpus and its
four consumers).

- **Red on the old code.** The new consumers, run against the `ee7102be27`
  core, shim, Linux sink and macOS logger: macOS 29 of 31 cases fail (every
  `level_setting`, `format_failure`, `dated_retention`, `topical_retention`
  and `sink_failure` case); Linux 18 fail (`format_failure`, both retention
  sections, `sink_failure`, `a refused main channel reopens after the retry
interval…`, `linux-topical-view-stale`, `prints the shared labels…`). The
  Linux `level_setting` cases pass on the old code, as they should: Linux was
  the reference. The old macOS retention rule, replayed by hand on the first
  corpus case: the noon of 2026-11-06 is earlier than 2026-11-20 23:30 minus
  14 × 86,400 s (2026-11-06 23:30), so the archive was purged.
- **Green on the new code.** Windows: `test_corpus_logger_parity.ahk` 31/31,
  and the AutoHotkey cases matching `logger` (326), `purge` (16), `rotation`
  (2), `retention` (41) and `sub-file` (3), through
  `node tools/test/ahk-parallel.cjs --fresh --only=<filter> --wait=300`.
  macOS (Lua 5.4 under WSL): `test_corpus_logger_parity.lua` 31/31, every
  module of `tests/unit/core/logger`, `test_corpus_logger_behaviour.lua`, the
  three `test_overrides*` modules, `test_init_boot_logger_format.lua` and
  `test_picker_logger_reentry.lua`. Linux (LuaJIT under WSL): the `meta` group
  1306 passed, the parity corpus, `test_sink`, `test_sink_retention` and
  `test_contract` 147/147; the one `meta` failure
  (`runner-output-utf8`) and the `ui` group failures of the mirror read files
  outside `static/ergopti_plus` or run as root, and none is a logger case.
- **Gates.** `test-logger-scalars-single-source.cjs` (a mutated corpus
  default is named), `test-shared-literal-inventory.cjs` (baseline lowered:
  the removed level table and day constants), `test-linux-feature-parity.cjs`
  (the parity table regenerated: the macOS `log_level` owner is now
  `init.lua`), `test-log-file-names-single-source.cjs`,
  `test-log-vocabulary-scan.cjs`, `test-port-vector-traceability.cjs`,
  `lint-conventions.js --fail-on-violations` and Prettier.
- **Not run here.** `testRetentionReplaysTheSharedParityCorpus` (Swift; the
  macOS CI job), `npm run test:js` and `verify-change` (they refuse this
  checkout's Node pin).
