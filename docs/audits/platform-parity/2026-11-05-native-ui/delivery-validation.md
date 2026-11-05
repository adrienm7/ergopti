# Delivery validation

Audited runtime source: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. Date: 2026-11-05.

The nine OS audits and root independent replays are complete within their declared bounds. All fifteen canonical findings have TODO entries. The thirty corruption controls reject invalid metadata and the positive zero-findings control passes; the source-area helper's real private-Git controls cover missing members, newly tracked source and historical/dirty reproducibility. Capability rendering, source-area regeneration, both official guarantee envelopes and owned Prettier/Ruff formatting passed. Later evidence-only amendments are checked again before commit.

## Broad local gate and delivery-tooling follow-up

The completed `npm run test:js` run executed all 571 planned Linux checks: 566 passed and five failed. One native AHK case was explicitly not executed on this Linux host. The [original unmodified run log](root/full-js.log) remains evidence; this was not a clean 571/571 run.

All five failures originate in four Git inventory reads exceeding Node's default 1 MiB stdout capture: AHK-runner references, generated-output drift coverage, source-tree scan coverage, and plan-reference scanning. The untracked-artifact control propagates the source-tree scanner failure. Actual Git output with the audit proof files exceeds 1 MiB. No product-runtime failure or new parity finding is inferred from these delivery-tool failures.

A separate `ship-fix` follow-up, committed as `4e8eefb`, replaces the four reads with a complete NUL-record Git reader using private stdout storage. It preserves their assertions and file selection, retains errors as failures, and adds a real large-index regression with an expected trailing sentinel beyond 1 MiB. All twelve targeted commands passed, including the four direct scanners, the propagated untracked-artifact check and the adjacent streaming/isolated-drift controls. The [machine receipt](root/tooling-git-paths/receipt.json) lists commands, exits and logs. Root independently reran the final real large-index regression and registration checks. The new registered inventory contains 575 checks across hosts, 572 planned on Linux; no fresh clean full-run result is claimed. The six other reviewed sibling commands currently use narrower source scopes; no filtering or evidence deletion was used to make the four broad inventories fit.

## Source and receiving limits

The successful [historical baseline CI](root/audited-baseline-ci-summary.json) names the audited source and its GitHub run. It is not a successful run of these new probes or certification of each native feature. A hosted preflight on the final commit is separate; its live GitHub result is authoritative and is not claimed green in this immutable local receipt.

Root [replay receipts](root/replay-summary.json) cover all nine scope groups, including the natural ShellRunner completion countercheck after watchdog refusal. The original wrong-argument manifest-helper setup failure remains explicitly identified. Runtime probes use the pinned source; no real Windows or macOS fault receiving, signing, System Extensions approval, physical input, native process-retirement stress or Linux live GTK session was qualified here.

All six task-owned source worktrees were clean before retirement; their temporary dependency symlinks were removed and source commits archived under local recoverable Git refs. [Ownership and recovery](worktrees.json) and the [retirement receipt](root/worktree-retirement.json) record this. No unrelated worktree was removed. Source also remains reachable through dev ancestry. Proofs and original source identities are retained in this campaign rather than keeping full duplicate checkouts.
