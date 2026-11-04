# Delivery validation

Audited source: `3a680d9f530a9af686fccc16d3f7611ec7fb034c`. All six reviewers and root kept production, registered tests and user state unchanged during proof execution. The campaign adds documentation and compact proof/receipt artifacts only.

## Independent root replays

- Linux migration: 13 fresh commands, including actual rename/name/locator/self-alias cases, healthy/refusal/retry controls, real unprivileged permission failure and existing contract cases; see `linux-migration/logs/root-final.json`.
- macOS migration: all 12 isolated public modes with real private POSIX/LFS effects and fresh real TOML/path adoption; see `macos-migration/logs/root-final.txt`. No Hammerspoon runtime was executed.
- Windows migration: actual shared core/private files plus committed contract groups and exact source assertions; see `windows-migration/logs/root-replay.txt` and `root-source-evidence.json`. No AutoHotkey/Win32 run.
- Linux updater: actual LuaJIT default smoke, healthy and bounded slow controls; see `linux-updater/logs/root-smoke-blocks-loop-luajit.txt`. Initial stock Lua failure is retained separately and explained by directory no-replace runtime support.
- macOS updater: actual Lua owners and emitted swap, private PID and physical Linux test port; accepted/refused and lease-collision controls; see `macos-updater/logs/root-refused-exit-final.txt`. Original consent remains valid.
- Windows updater: root re-extracted exact current PowerShell AST into a separate private temporary fixture and replayed four genuine transaction branches; see `windows-updater/logs/root-swap-replay.txt` and `root-swap-cases.json`. Native event/process boundaries recorded.

Root also independently parsed exact registered-result logs and checked the per-module metadata: Linux updater 23 modules/354 assertions, macOS migration six modules/36 cases, macOS updater 23 modules/385 cases ([raw-log verification](root-registered-log-check.json)). This verifies retained receipts, not another execution. Registered-case receipts in each scope are not summed across repeated dry passes, Lua engines or overlapping module lists. Permission denial was performed only on disposable owned directories and restored for cleanup. No unlimited sleeper, real installer, external download or user service was launched.

## Repository and hosted checks

Selected gates and delivery results are recorded below before push. Earlier hosted CI on source `3a680d9` is not a passing verdict: native receiving gaps and reported failures must remain visible.

## Final physical-alias counterpart

MFM-006 was discovered after the initial macOS migration closure. Root opened and independently replayed `create-immutable-bundle.py` followed by `run-same-root-alias.py`: same-device/inode alias, genuinely distinct roots and absent-legacy controls all passed. Four production modules and four source joins came exclusively from immutable Git objects at the pinned revision, avoiding interference with the ongoing global JS gate. Small source bundles are rebuilt by the retained program rather than committed as duplicate source trees. See [root replay](macos-migration/logs/root-same-root-alias.txt), [source provenance](macos-migration/logs/immutable-bundle-provenance.json) and the scope’s new D3/D4 ledger. Those two post-MFM-006 sweeps cover the full bounded migration facade/ports/plan/bootstrap joins in immutable source, with three fresh private physical controls each; the earlier 36 registered cases were not rerun during this concurrent gate and are not added again.

## Full selected local gate result

[verify-change plan](validation/verify-plan.txt) selected format, AHK encoding and JS. The [complete execution receipt](validation/verify-change-3a680d9.txt) records formatting success (543 Python files already formatted), encoding success (2563 AHK files checked for BOM/LF), and **571 JS checks completed with two failures**. One AHK host case is explicitly unexecuted, never passed. This is not a green full suite.

The two exact failures are the existing `remap-runtime-build.yml` / `install-acceptance` permission mismatch (`actions: read`) and the macOS native `installer` program missing from the owned-runtime inventory. Both had already failed at the parent `3a680d9` and are tracked in the pre-existing audit-validation TODOs and immutable previous delivery receipts. Production, registered tests, workflow files and package manifests remained byte-identical to that parent; no assertion or policy was weakened. Site release resolution and Windows bundle checks now pass in this complete run; no transient bytecode exclusion change was needed.

The supplemental active-loop smoke ran only after the global gate finished, against restored unchanged source. It confirms the same Linux root from an active timer callback: before/after heartbeat controls and deadline rollback. Its first fixture-clock setup refusal is retained. The final macOS physical-alias checks ran concurrently only against explicitly hash-verified immutable Git blobs, never potentially mutating global-gate inputs. New standalone proof/receipt files and final prose receive fresh exact-file formatting and metadata/negative-control checks before commit; no runtime input changed after the complete JS run.

The campaign validator refuses five metadata corruptions: invalid source SHA, duplicate scope, missing additional-property classification, missing evidence, and malformed property container. These are artifact guards, not native feature tests.

## Additional checks and prior hosted result

The existing production [feature-inventory drift check](validation/feature-inventory-drift.txt) exited zero with empty stdout; current website/README generated declarations are unchanged and fresh. [Strict conventions](validation/conventions.txt) passed. The JSON-owned audit capability table is separately rendered and checked, not substituted for the production inventory.

The [previous exact-parent hosted preflight](validation/previous-preflight.json) completed with **failure** at `3a680d9`; its failed-job list includes macOS meta and Common source/release checks. Detailed macOS job logs could not be fetched from GitHub’s redirected log host ([sanitized fetch outcome](validation/previous-mac-meta-fetch.txt)); no specific native assertion cause is inferred. The local two exact JS failures have independently established baseline causes. Exact-delivery preflight uses `tmp/preflight-dev` with all OS lanes; inspect the delivered commit in [Actions](https://github.com/adrienm7/ergopti/actions/workflows/ci.yml?query=branch%3Atmp%2Fpreflight-dev), rather than treating an old verdict as current. Delivery follows the documented maintainer policy to place partial audit work on dev after feasible checks while retaining native/code gaps.

The final [whole-repository format check](validation/final-format-check.txt) passed (546 Python files already formatted). A receipt JSON indentation difference encountered while assembling delivery was corrected through Prettier before the successful check. The negative-control runner now requires the real baseline validator to succeed before applying its five isolated corruptions, so an unrelated pre-existing metadata failure cannot make every mutation falsely green. Final receipt prose/control files are formatted through their exact-file owners and the commit hook.
