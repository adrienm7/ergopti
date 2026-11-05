# Native runtime, editor and diagnostics parity audit

Audited source: `3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a`. Date: 2026-11-05.

Nine bounded OS × module scopes continue the previous campaigns. Six reviewers worked in six separate detached worktrees of the same revision; three completed worktrees were reused for diagnostics. Root reopened the decisive programs and receipts, replayed safe proofs in independent scratch, and challenged visibility, reachability and intentional contracts. [Worktree ownership](worktrees.json) and [plan](audit-plan.md) retain the source and separation used.

**15 confirmed actionable findings** remain in [the canonical index](index.json). This is a count of follow-ups, not independent native bugs or an exhaustive certification. WVB-002 is one shared frontend cause affecting all three OSes, counted once. MRT-005 and LVB-002 are excluded. Windows runtime and macOS diagnostics added controls without a new confirmed defect. The nine OS audits changed no production runtime behavior. A separate delivery-tooling follow-up replaces four default-buffer Git inventory reads and adds a large-index regression, preserving every scanner assertion; see delivery validation.

## Results

| Scope               | Canonical IDs                               | Evidence                                |
| ------------------- | ------------------------------------------- | --------------------------------------- |
| windows-runtime     | No new confirmed root                       | [Report](windows-runtime/report.md)     |
| windows-webview     | WVB-001, WVB-002                            | [Report](windows-webview/report.md)     |
| windows-diagnostics | WDG-001                                     | [Report](windows-diagnostics/report.md) |
| macos-runtime       | MRT-001, MRT-002, MRT-003, MRT-004, MRT-006 | [Report](macos-runtime/report.md)       |
| macos-webview       | MVB-001, MVB-002                            | [Report](macos-webview/report.md)       |
| macos-diagnostics   | No new confirmed root                       | [Report](macos-diagnostics/report.md)   |
| linux-runtime       | LRT-001                                     | [Report](linux-runtime/report.md)       |
| linux-webview       | LVB-001                                     | [Report](linux-webview/report.md)       |
| linux-diagnostics   | LDG-001, LDG-002, LDG-003                   | [Report](linux-diagnostics/report.md)   |

[Capabilities and intentional differences](capabilities.md) compare user-visible behavior, equivalent paths, native constraints and unknown product intent. [TODO](../../../../TODO.md) owns implementation status. Submitted manifests are preserved beside narrowed canonical manifests; the decisions below take precedence over submitted labels.

## Integration decisions and counterchecks

- **MVB-002:** actual shared JavaScript fed by the real macOS shortcut initializer sends save and an independent close. Actual editor/parser/writer over private-file compare-and-swap and write refusals logs errors and notifies, then closes and loses the unsaved draft on reopen. Successful persistence, auto-close disabled and menu mode are controls. The defect is draft loss after refusal, not an entirely silent error. It is a named preservation property, not stretched into G2.
- **WVB-001:** exact AHK expression projection emits a doubly quoted JavaScript literal; the actual JavaScript VM rejects it. The suspended save branch has no separate save-failure notifier. AHK/WebView2 execution and actual suspension delivery remain unrun.
- **WVB-002:** actual shared delay controls convert valid zero/unlimited into750 through truthiness. Actual host serializers on all three OSes preserve zero. Source host joins plus actual shared JavaScript establish the defect; native window rendering/persistence was not executed.
- **Windows automatic-close hypothesis refuted:** the actual initializer hardcodes menu mode, so the shared shortcut-only close branch is not reachable by that path. A synthetic shortcut seed is only a positive control. Do not copy MVB-002 onto Windows.
- **LVB-001:** the reachable Linux close command logs closed without calling its owned native close capability. Native GTK receiving remains open. macOS reaches close; Windows mode differs as above.
- **LVB-002 demoted:** the real catalogue rejects a reload after bytes were saved. Root's countercheck includes the actual logger, default error-dialog policy and router: three ERROR events and one accepted 250ms error-window request. Saved truthfully describes durable bytes; no applied promise or wholly silent failure was established. Native display is unmeasured. The submitted claim is retained with its countercheck, outside confirmed IDs and implementation TODOs.
- **MRT-001:** the 900s deadline failure is a virtual-clock reproduction; the independent real Linux libuv experiment scales the budget to 1s and stops near 2.25s. Neither is a900s Darwin run or typing-latency measurement. Late approval beyond the nominal budget can still acquire reload authority.
- **MRT-002:** refusal of the local command watchdog is already logged by the scheduler. An independent actual ShellRunner control demonstrates that natural role and activation completion still settles both waiters. A pending native child can leave install waiters unresolved; the proof does not establish that every native child hangs. This is bounded-settlement debt, not wholly silent failure or a proven physical overlapping-publication race.
- **MRT-003:** Lua accepts trailing receipt bytes that the Swift source rejects. Native installation refusal is loud. This is corruption recovery/admission inconsistency, not a signature bypass.
- **MRT-004:** source and actual owner join route an existing but unloaded runtime to first-install authority that rejects an existing tree. Preserve the exclusive publication guard; repair the recovery affordance. Native service repair and partial-failure cleanup need Darwin qualification.
- **MRT-005 excluded:** a timeout may release a logical slot while retirement is pending, but native exclusive locking and original consent contain the stronger proposed publication race. Pending cleanup alone did not prove the requested corruption property. Its probe remains observational evidence.
- **MRT-006:** literal false from the native Settings opener is swallowed by a successful pcall; no local error is produced. True submission does not establish that a user saw the pane.
- **LRT-001:** actual Linux filesystem/resolver/state control reproduces stale missing-ancestor identity after a separate successful repair; fresh observer adopts the synthetic valid runtime. Refresh only from authenticated repair evidence; do not weaken identity fences. The command ran as uid1000, correcting the submitted report's root-user claim. No actual Ollama daemon/download/install ran. This absent-state projection requires an empty model cache; a nonempty cache takes the answering branch first.
- **WDG-001:** genuine PowerShell/.NET on Linux plus a private file-size limit leaves partial final-name JSON after a loud failed write. It is artifact completeness debt, not a false-success report or Windows full-disk reproduction.
- **LDG-001/002:** actual collector/export/shared page preserve an incorrect Ollama backend for API mode and collapse known disabled=false to unknown. Public API backend support and the actual probe target are traced; no live external API is called.
- **LDG-003:** faithful native timer allocation/start refusals plus actual scheduler leave diagnostics pending without a terminal path. Scheduler ERROR is retained; this is named completion debt. The separate partial HTTP response hypothesis was refuted: Backend answers measures reachability, not successful complete transfer.
- **macOS local crash privacy:** canary survives local report/save but not shared typed export/day-log output. Windows explicitly retains local raw detail; Linux redacts before persistence. No transmission or settled cross-OS identical local retention contract was found. Keep the policy/comment inconsistency separate from confirmed defects.

## Proof, stopping boundary and remaining work

Each scope records two whole bounded dry sweeps after its last newly confirmed root. MVB-002 resets the macOS editor sweeps; final A/B each run 19 commands. These sweeps cover the declared scope and do not establish global completeness. Repeated commands are not additional independent cases. Linux diagnostics ends with 32 commands per pass; all passed. Scope reports contain actual registered-case counts and qualifications.

Root independent receipts are in [root replay receipts](root/replays/macos-runtime/logs/root-replay-ledger.json). Decisive programs execute actual business owners; synthetic immediate native ports are named. The macOS editor draft-loss join uses real JavaScript, real Lua parser/writer and actual private-file CAS refusal. Linux state/resolver and diagnostic timers use real libuv where stated. Windows expression/JavaScript proof is source projected; Windows writer controls use genuine Linux PowerShell/.NET. The false-green scanner remaining within its existing baseline is not native certification.

One root helper-validation invocation was accidentally passed the source-root path instead of the manifest directory and failed ENOENT before inspecting a subject; this setup failure is retained. Decisive WebView probes passed independently with correct arguments. The optional LuaJIT macOS picker run is blocked by table.pack before the subject; the shipped Lua5.4 run passes. Initial Lua-path setup errors and later corrected runs remain in submitted logs.

These local audit probes did not exercise an actual Windows or macOS desktop, Hammerspoon, WebView2, WebKit, launchd/System Extensions service, device input, native signing/provisioning, physical process retirement, power-loss durability or long-term memory behavior in these proofs. Linux live GTK/session delivery remains open. No user configuration or system service was changed. Scope reports distinguish faithful ports, genuine Linux native filesystem/timer controls and source-only joins. No missing native receipt is presented as a pass.

## Automatic inventories and replay

The existing feature inventory remains generated from shared declarations for the site and README. It certifies declared coverage and explicit menu reasons, not every native capability. This campaign adds a separately generated [source-area register](source-areas.json), owned by `tools/audit/source-areas.py`, so later audits can enumerate tracked code/declaration areas and detect drift. Vendor/generated lexical markers are labels, not claims that code was reviewed. New code areas require a new review; no automatic static scan can prove full semantic feature parity.

Run `python3 -B docs/audits/platform-parity/2026-11-05-native-ui/validate.py` for canonical metadata/evidence/TODO checks, and `check_validator.py` for negative controls. Run `render-capabilities.py --check` to verify the comparison. Source-area and capability snapshots are immutable at the audited SHA, not a second mutable feature manifest. The source-area register contains 2,333 selected members; check it with `python3 -B tools/audit/source-areas.py --ref 3aaaae7dd028cdf21e99b7ff5a3e49acce15b46a --output docs/audits/platform-parity/2026-11-05-native-ui/source-areas.json --check`. Generate a separate current register with `--ref HEAD`.

Proof runners retain original checkout/toolchain paths. Rebind copies into owned scratch with the pinned source and genuine Lua5.4/LuaJIT/PowerShell/Node toolchain. Some programs create private fixtures and overwrite their own logs: never replay into published immutable evidence. Native suites remain a separate receiving qualification task.

See [delivery validation](delivery-validation.md) and the [independent root receipt index](root/replay-summary.json).
