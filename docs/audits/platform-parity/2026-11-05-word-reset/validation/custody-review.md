# Audit artifact custody countercheck

Read-only snapshot: 2026-11-05T15:06:42.319001+00:00.

Reviewed campaign source pin: `b17e47ed3bb92c106703d3e3482b3c2973f5bc1e`. Reviewer JSON artifact hashes, report references and retained-output counts were reopened independently. Production-source claims are deliberately excluded: `check_sources.py` owns those. Draft owner/projection hashes were also excluded as requested. No repository file was modified.

## Result

109 reviewer artifact hash claims resolve to retained files: 103 match archived bytes; 6 match original retained scratch bytes rather than the formatted archive. There is no missing hashed proof/program/output. The six differences need an explicit historical-byte qualification/current archive digest ledger; they do not establish false worker observations and should not be silently rewritten as if the worker executed the formatted bytes.

| Claim                                                                                  | Reference             | Expected original SHA256                                           | Current archived SHA256                                            |
| -------------------------------------------------------------------------------------- | --------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------ |
| `docs/audits/platform-parity/2026-11-05-undo-repeat/windows/dry-sweeps.json` /sweeps/0 | `dry-A.json`          | `59e361daefa6f29ce89c4bc0533e0fd14b590dac2eafde8269225088c881de03` | `ad00f1f0592425397a6ec4ed9a5082849154591f372428318a6fb75c57664dac` |
| `docs/audits/platform-parity/2026-11-05-undo-repeat/windows/dry-sweeps.json` /sweeps/1 | `dry-B.json`          | `59e361daefa6f29ce89c4bc0533e0fd14b590dac2eafde8269225088c881de03` | `ad00f1f0592425397a6ec4ed9a5082849154591f372428318a6fb75c57664dac` |
| `docs/audits/platform-parity/2026-11-05-word-reset/shared/handoff.json` /files/3       | `coverage.json`       | `c76a1053dddec1a4c2cc4132facc0b790e1b3711e59dabcb5296b36001438cb1` | `4c44dc599f880446633dc771cbefd60088fa22a4d8941242f550a72d6cfa10b1` |
| `docs/audits/platform-parity/2026-11-05-word-reset/shared/handoff.json` /files/12      | `dry-receipts.json`   | `8d9e170e468159df226e6232029569c85b7a2626e5baed5b8249e77748a015ff` | `bbbd53900c2094153dcc1516a9b1ea67748634172caa16c00555e8c215812666` |
| `docs/audits/platform-parity/2026-11-05-word-reset/shared/handoff.json` /files/14      | `findings.json`       | `d56566c614f3fc53c0950bc92a3add2161232525db8b4c123df0b239f39309cc` | `e556bcb2cb0ddf362826e0bc2a923735f95b457f84dabcb9ca9d44c8ea933a55` |
| `docs/audits/platform-parity/2026-11-05-word-reset/shared/handoff.json` /files/21      | `source-receipt.json` | `21615248f8f6d249e2713f375fa3ef1f791c87d96c4bb23f2f44bf64ca0fa918` | `060aba4e23fc97a3f7a5b8a09988d48ce1728bccffe615314c6ca12c85ef6f75` |

For every row above, the original retained scratch file exists and independently matches the expected digest. Exact original paths and hashes are in `scan.json`. The existing general historical-scratch provenance paragraphs are correct but do not yet explicitly explain these six original-versus-archive hash differences.

## References and counts

- All 68 role-report inline filename references resolved either to retained campaign artifacts or repository source files. This is filename/path custody, not a correctness assertion about the cited production mechanism.
- All 67 campaign Markdown links were checked. Four draft word-reset report links are pending generation: `findings.json`, `capabilities.md`, `owner.json`, `index.json`. These were expected draft gaps; rerun the link check after projection generation. The other 63 links resolve.
- Manifest/coverage totals independently match root expectations: undo-repeat 7 findings / 85 coverage rows (Windows 2/24, macOS 1/25, Linux 2/24, shared 2/12); word-reset 5 / 98 (Windows 2/27, macOS 2/32, Linux 1/24, shared 0/15).
- All 84 inspected per-module and owner-case count claims agree with actual retained stdout: Mac summary counts are rederived from each named module log, Linux registered counts from the emitted `AUDIT_RESULTS` JSON, and Linux owner-case counts from actual output arrays. Repeated passes are not counted as new distinct coverage.
- Each undo-repeat Mac sweep has 8 positive registered modules / 53 cases / 0 failures; each Linux sweep has 9 / 412 / 0, plus 20 owner scenarios under each interpreter.
- Each word-reset Mac sweep has 10 positive modules / 145 cases / 0 failures; each Linux sweep has 11 / 500 / 0, plus 43 owner scenarios under each interpreter.
- Shared word-reset stdout independently records 1,388 assertions, 208 policy scenarios, 7 idle vectors, 13 context vectors and 9 private vectors; the Mac peer stdout has 12 cases / 5 mismatches, correctly attributed to the same peer-owned root.

## Provenance limits

The inspected human reports consistently qualify Windows as lexical/source-only and Lua production-owner execution as running over controlled native ports. They do not claim physical editor receiving, genuine AHK execution, actual network delivery, durable output completion, G4 latency or memory-growth measurements. I found no additional unsupported native receiving claim or numerical discrepancy in this bounded artifact review. This is an evidence-custody countercheck, not a fresh runtime audit or certification of exhaustive source coverage.

The portable decisive `replay.py` plans reference retained programs. Historical worker runners retain scratch/worktree paths and toolchain paths as provenance; they are not the portable decisive replay entrypoints. Root replay receipts retain current program hashes separately.

Supporting machine records: `scan.json`, `all-local-links.json`, `backtick-references.json`, `count-review.json`, `actual-log-counts.json`.
