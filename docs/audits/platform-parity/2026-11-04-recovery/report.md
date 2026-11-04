# Migration, update and restart parity audit

Audited source: `3a680d9f530a9af686fccc16d3f7611ec7fb034c`. Date: 2026-11-04.

The [delivery overlay](delivery-delta.md) reviews subsequent dev through `8eb5378`, including the superseded Windows Ollama sibling rationale, upstream CI fixes and newly added native scope. All 17 mechanisms remain applicable by source comparison; the proofs below remain pinned to their audited revision.

Six OS × module scopes extend the previous review: legacy-folder migration and updater/reload handoff, separately on Windows, macOS and Linux. Six reviewers and root followed real entry points through native effect, acknowledgment, cleanup and next-start adoption. This campaign explicitly covers the newly added migration excluded from the previous flow audit. Earlier evidence remains unchanged.

**17 OS-scoped follow-ups** are retained. They are manifestations and work items, not 17 distinct causes or native desktop reproductions. Root independently opened and replayed the safe private proofs, challenged intent and narrowed classifications. The Windows updater review established no new confirmed root in its declared five-flow coverage; it is not certified globally clean.

## Scope results

| OS × module       | IDs                                                  | Evidence                              |
| ----------------- | ---------------------------------------------------- | ------------------------------------- |
| windows-migration | WFM-001, WFM-002, WFM-003, WFM-004                   | [Report](windows-migration/report.md) |
| windows-updater   | No new confirmed entry                               | [Report](windows-updater/report.md)   |
| macos-migration   | MFM-001, MFM-002, MFM-003, MFM-004, MFM-005, MFM-006 | [Report](macos-migration/report.md)   |
| macos-updater     | MUR-001                                              | [Report](macos-updater/report.md)     |
| linux-migration   | LFM-001, LFM-002, LFM-003, LFM-004, LFM-005          | [Report](linux-migration/report.md)   |
| linux-updater     | LUR-001                                              | [Report](linux-updater/report.md)     |

## Findings and practical effects

| ID      | Retained issue                                                                                        | Severity |
| ------- | ----------------------------------------------------------------------------------------------------- | -------- |
| WFM-001 | Independent migration moves and locator publication can select an empty configuration after a refusal | medium   |
| WFM-002 | Moving a legacy ancestor leaves a selected custom descendant pointing to its removed path             | medium   |
| WFM-003 | Valid quoted TOML locator keys are missed by the migration rewriter after data moves                  | medium   |
| WFM-004 | Migrating only the locator hides the old configuration-transition recovery journal                    | medium   |
| MFM-001 | Refused bootstrap rewrite leaves a backup that blocks automatic restart recovery                      | medium   |
| MFM-002 | Refused configuration move still publishes a locator to the absent new folder                         | medium   |
| MFM-003 | Valid explicit configuration locators become dangling after their containing folder migrates          | medium   |
| MFM-004 | Destination check followed by POSIX rename can overwrite a newer concurrently published file          | high     |
| MFM-005 | Native directory listing refusal escapes migration and aborts driver initialization                   | medium   |
| MFM-006 | Legacy log alias archives active files from the current destination root                              | medium   |
| MUR-001 | Refused restart reports a retained armed installation as failed and idle                              | medium   |
| LFM-001 | Concurrent migration destination arrival is overwritten by native replacing rename                    | high     |
| LFM-002 | Newline-bearing legacy filenames are split and silently skipped                                       | medium   |
| LFM-003 | Relocated configuration directory retains its obsolete native bootstrap locator                       | medium   |
| LFM-004 | Native directory enumeration failure is accepted as an empty successful scan                          | medium   |
| LFM-005 | Legacy root aliasing current root archives active configuration as its own conflict                   | medium   |
| LUR-001 | Owned async installation blocks the daemon event loop during an unbounded launcher smoke              | medium   |

## Root review and provenance

- Migration probes join actual public owners to actual filesystem effects and a fresh production path resolver. Refused moves or writes, successful displacement, nested/alternate-TOML locators, occupied backups, retry, real permission denial and physical aliases are distinguished. Known refusal warnings are not relabeled as entirely silent failures.
- The POSIX no-overwrite race executes the original replacing rename after a controlled real destination arrival. Linux direct entry performs migration before its later singleton acquisition; ordinary launcher locking is distinguished. macOS instance admission does not promise protection against external writers. Windows ordinary instance overlap is fenced; no Windows native race is asserted.
- Windows migration manifestations are source-derived. Actual shared Lua core over private files corroborates the algorithm, while supplied AHK probes remain unexecuted. This is not a Win32/ACL/DirMove runtime pass.
- Linux updater uses real LuaJIT, real default filesystem operations and a bounded private launcher. Root first measured 716.3ms; a stronger actual running-loop callback control measured 727.7ms with a 250ms budget, three heartbeat ticks before, none during and a resumed tick after (maximum gap738.0ms). Event-loop starvation is demonstrated; typical native desktop typing latency is not measured. A stock Lua initial replay failed native directory activation and is retained, not silently counted as a pass.
- macOS chosen-release replay joins real Lua owners to the emitted swap shell, real Linux lease and exclusive-rename test port, and a private launcher PID. ARMED-on-quit is intentional and original install consent remains valid. The finding is the failed/idle receipt while the native installation remains pending; duplicate-worker lease refusal refutes a double-swap claim.
- Windows updater controls execute AST-extracted genuine PowerShell transaction/digest bodies with real private file I/O and recorded process/event ports. Root independently replayed all four transaction branches. Linux PowerShell7.4.6 is not Windows PowerShell5.1 or AHK.
- Canonical manifests narrow MFM-001 to medium severity and durable location/recovery consistency, and LFM-005 to physical identity preservation. Submitted classifications are preserved separately. No new G-code is invented for properties outside G1–G5.

## Feature availability and intentional differences

The [16-row capability comparison](capabilities.md) and [JSON owner](capabilities.json) describe actual reachable updater/migration behavior, conditions and equivalents. They distinguish explicit policy, mechanism, constraints, observed defects and unknown intent. Notable differences include Sparkle feed-only newest-install handoff, disabled detached-signature policy on Windows/Linux, chosen-release-only backup scope, stronger Windows boot-ready/probation, native restart receipt strength and the intentionally retained compiled Karabiner path.

This is a revision-pinned behavioral snapshot. The existing `tools/codegen/codegen-feature-inventory.cjs` still generates the live website/README declaration inventory and owns its drift gate. Declared catalogue presence does not certify these internal effects or exhaustively discover native capability. The snapshot table renders from its JSON owner; it is not inferred from passing tests.

Two separate capability-parity TODOs evaluate macOS/Linux equivalents of the Windows chosen-release successor-ready/probation contract; their intent is unknown, so they are not silently called intentional platform impossibilities or counted as additional defect roots.

Shared mechanisms are grouped in [index.json](index.json); one OS item may belong to more than one group. Do not add this campaign’s counts to older reports as a count of distinct bugs.

## Closure and exclusions

Every scope records two final dry passes after its last confirmed root. Linux migration reset again after the physical self-alias finding; macOS updater reset after the ARMED/refused-restart observation. A final immutable-source counterpart check then found MFM-006; macOS migration reset again and completed fresh full bounded source sweeps D3/D4 with inode/alias/healthy controls. The source bundle avoids reading inputs while the unrelated global JS suite mutates temporary test subjects. This is a stopping condition for named coverage, not proof that every feature, state or OS has been exhausted.

No real user home/config/clipboard/secret, live systemd service, installed app, network updater transfer, actual trash/device or Windows/macOS desktop was modified. Native AHK/Win32, AppKit/Hammerspoon/Darwin/APFS, real input latency, signing infrastructure, power-loss durability and long-term process/memory retention remain open. Scope reports identify further native receiving cases and hypotheses; generic external-directory symlink policy and a long UTF-8 terminal-receipt hypothesis are not promoted without the missing contract/reachable path.

The original canonical audit CLI only accepts the existing OS/date envelopes and cannot admit this Linux/cross-module campaign. It is unchanged. Run `python -B docs/audits/platform-parity/2026-11-04-recovery/validate.py` after installing repository Node dependencies for metadata, TODO, source identity, table, encoding and evidence-link checks. This does not execute or certify native parity.

Retained proof programs use original absolute checkout/toolchain roots. Rebind copies in owned scratch at the audited revision before replay; some programs create fixtures or overwrite their own receipts. Do not execute raw swap/installation bodies outside their private recording harness or replay into immutable published evidence.

See [delivery validation](delivery-validation.md), [previous flow audit](../2026-11-04-flows/report.md) and [main parity guide](../../../platform-parity-audit.md).
