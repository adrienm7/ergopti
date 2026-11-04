# Windows audit campaign, 4 November 2026

Audited commit: `9154723b34ee0599433cbf749a4aca839bd54b53`. Scope: ErgoptiPlus Windows; read-only parallel passes covered keystats, input, UI and LLM request handling. Evidence is derived from production source and existing tests. The findings below have not all been executed on native Windows. No performance numbers were measured.

## Goal and evidence standard

The requested goal is 100 distinct confirmed defects. This snapshot records **8 new distinct findings**, not 100. Earlier fixes on the branch precede this baseline and are not counted in this snapshot. Duplicate sites, policy disagreements and unconfirmed hypotheses do not increase the count. Implementation history and native qualification remain separate from source confirmation.

## Findings

### AHK-001: Zero-net scroll retains the previous burst clock

Severity: medium. Confidence: high. Evidence: source-derived.

KL_Mouse_FlushScroll in static/ergopti_plus/windows/modules/keystats/keystats_mouse.ahk: The empty-delta return precedes clearing scroll_start and scroll_last.

Reproduction: Scroll +1 at1000, -1 at1100, flush1500, then +1 at5000 and flush5400.

Existing gap: The next burst duration is4400 instead of400; the empty fixture starts with zero timestamps.

Regression: Assert timestamp retirement and the next burst duration through actual accumulate/flush ports.

### AHK-002: ROI word candidates miss special keys

Severity: medium. Confidence: high. Evidence: source-derived.

\_KL_Hook_CommitInput in static/ergopti_plus/windows/modules/keystats/keystats_hook.ahk: Only char intents reach ROI; Enter, Tab and Backspace are key intents.

Reproduction: Type hello, Enter, world and space; separately type hellox, Backspace and space.

Existing gap: ROI records helloworld or hellox while typing-buffer tests cover only actual text.

Regression: Drive actual key/char owners and assert separate and corrected ROI candidates; exclude synthetic and private input.

### AHK-003: Zero-saving hotstring fires are absent from usage history

Severity: medium. Confidence: high. Evidence: source-derived.

KL_Roi_OnHotstring in static/ergopti_plus/windows/modules/keystats/keystats_trigger_roi.ahk: A nonpositive-savings guard suppresses independent fired-count and last-use bookkeeping.

Reproduction: Fire an initialized public trigger with net_saved0 after an older positive-saving use.

Existing gap: The active trigger retains an old last-use timestamp and can be reported stale.

Regression: Assert zero and negative savings fires update usage but add no positive savings; keep private trigger exclusion.

### AHK-004: Selected composition removal publishes duplicate results

Severity: medium. Confidence: high. Evidence: source-derived.

\_LayoutComposer_Remove in static/ergopti_plus/windows/ui/layout_manager/composer.ahk: Unlike the save sibling, removal lacks a terminal Completed guard.

Reproduction: Remove the selected composition; after invokes its refusal callback and returns false.

Existing gap: Each callback and the fallback publish composerResult and updateState.

Regression: Inject duplicate refusal callbacks plus a false return and require exactly one result and one state push.

### AHK-005: Old layout operations publish into a replacement window

Severity: medium. Confidence: high. Evidence: source-derived.

\_LayMgrWeb_OnDone in static/ergopti_plus/windows/ui/layout_manager/init.ahk: Callbacks capture dependencies but no session epoch, and push targets the current global WebView.

Reproduction: Start installation in session A; close A and open B; deliver the failure callback from A.

Existing gap: The old result overwrites the replacement session result and displays there.

Regression: Retain callback A, replace the session, complete A and assert no stale UI/result publication while durable work completes.

### AHK-006: Replacing the click watcher can strand an existing held button

Severity: high. Confidence: high. Evidence: source-derived.

GestureStartKeyboardWatcher in static/ergopti_plus/windows/modules/gestures/click.ahk: The active shared watcher is stopped before the replacement is acquired; rollback preserves the first held button.

Reproduction: Hold left click, request right hold by touch, and refuse construction or start of the replacement keyboard watcher.

Existing gap: The next key has no observer to release the synthetic held button.

Regression: Retain an active watcher across overlapping holds; test both button orders and failed cleanup ownership.

### AHK-007: Output-only API usage has a zero total

Severity: medium. Confidence: high. Evidence: source-derived.

\_LLMRemoteExtractUsageRoot in static/ergopti_plus/windows/modules/llm/api_remote.ahk: Fallback summation requires positive input tokens.

Reproduction: Parse usage prompt_tokens0 completion_tokens10 without total_tokens; repeat Anthropic and Gemini equivalents.

Existing gap: Completion tokens are present but total_tokens is0 and downstream totals omit them.

Regression: Expect total10 for all three formats with zero input and positive output.

### AHK-008: UTF-16 BOM alone is accepted as a valid PAC script

Severity: medium. Confidence: high. Evidence: source-derived.

NetworkCheck_JudgePac in static/ergopti_plus/windows/ui/field_check/network_check.ahk: The UTF-16 BOM branch returns success without decoding or checking the PAC function.

Reproduction: Judge HTTP200 body FF FE, FE FF or FF FE0000.

Existing gap: Diagnostics claim a valid PAC and FindProxyForURL despite absent script; the Lua sibling shares this defect.

Regression: Accept real UTF-16LE/BE PAC scripts; reject BOM-only, odd byte counts, invalid Unicode and content without the function.

## Refutations and policy boundaries

Mixed horizontal and vertical scrolls intentionally follow the existing horizontal-priority policy; this was not counted. Ellipsis after accented letters lacks an established Unicode requirement and was not counted. Dead-key admission at an empty context needs a known-start versus unknown-context distinction and was not counted. The token-exchange minimum lifetime is an explicit existing shared policy; the expiry hazard needs cross-driver contract review and is not silently changed by this Windows pass.

## Coverage gaps and watch-list

This is not an exhaustive audit of every Windows file. Native fault injection, physical keyboard and touchpad receiving, WPM persistence and reconstruction, long-word LLM diff limits, and the shared PAC decoder remain open. Rejected SQLite grouping, mmap, caching and priority proposals were excluded. No zero-bug claim is made.

## Second sweep of the same audited revision

The second sweep adds 6 distinct findings, for 14 new findings in this ongoing audit. The goal of 100 remains unmet. The initial evidence above is retained.

## AHK-009: Update result survives a superseding request

Severity: medium. Confidence: high.

static/ergopti_plus/windows/ui/update_check/init.ahk:UpdateCheck_ShowResult: Request identity is checked before yielding calls but not before presenting the result.

Reproduction: Result A enters logging; close A and begin B before logging returns.

Observed source consequence: A replaces B or reopens the closed window.

Regression: Interrupt the actual logging boundary; reject A and retain B checking.

## AHK-010: A stale successful WebView build overwrites its replacement

Severity: high. Confidence: high.

static/ergopti_plus/windows/ui/update_check/init.ahk:\_UpdateCheck_Open: Only the failure path rechecks the opening epoch; the successful path publishes global resources unconditionally.

Reproduction: While WebView creation for A pumps messages, close A and open B; then return A controller.

Observed source consequence: B loses its controller ownership to the old opening stack.

Regression: Inject reentrant factory completion and require B resources unchanged and A resources retired once.

## AHK-011: Update window teardown can close one controller twice

Severity: high. Confidence: high.

static/ergopti_plus/windows/ui/update_check/init.ahk:\_UpdateCheck_CloseWindow: Owner invalidation and ResetDone happen after the COM call; no reentrant teardown guard exists.

Reproduction: Controller.Close reenters CloseWindow through a native window event.

Observed source consequence: The same controller closes twice and the host can be destroyed before COM closure unwinds.

Regression: A passive controller reenters on its first Close; require exact-once closure and destruction.

## AHK-012: An absent Startup directory prevents portable uninstall

Severity: medium. Confidence: high.

static/ergopti_plus/windows/vendor/ergopti_uninstall.ps1:Remove-ErgoptiStartupShortcuts: Get-ChildItem enumerates an optional directory unconditionally under ErrorActionPreference Stop.

Reproduction: Unregister startup shortcuts for an absent Startup folder during an authorized executable removal.

Observed source consequence: The application has exited but recycling never runs.

Regression: Execute the removal transaction with an absent private folder and a recorded recycle callback.

## AHK-013: Crash reports confuse process and OS architecture

Severity: low. Confidence: high.

static/ergopti_plus/windows/vendor/ergopti_crash_worker.ps1:architecture enrichment: The worker replaces reliable snapshot os_arch with PROCESSOR_ARCHITECTURE, which describes its own process.

Reproduction: Run the crash worker as PowerShell32 on Windows64.

Observed source consequence: The report says OS x86 although Windows is64-bit.

Regression: Execute a WOW64 worker with an OS64 snapshot and assert OS architecture remains64-bit.

## AHK-014: Final file admission can overwrite a concurrent edit

Severity: high. Confidence: high.

static/ergopti_plus/windows/adapters/file_system.ahk:\_FSPublishIfUnchanged: Source equality is checked only before staging and before the reentrant logical admission.

Reproduction: Read old as Expected; the final admission writes concurrent and returns1; request replacement.

Observed source consequence: The publication reports success and replaces concurrent.

Regression: Invoke the actual admitted publisher with a source-mutating admission; require refusal, preserved edit and no stage.

## Limits and rejected hypotheses

PowerShell and native UI fault injection remain unexecuted here. API and local-server dialogs checked source receipts after the inspected modals; no finding was counted there. Claims about unsupported display brightness levels were not counted without device evidence. SQLite first-wins and append receipts remain separate investigations until independently reproduced. This snapshot does not assert complete file coverage or zero remaining bugs.

## AHK-015: Segmented replay keeps the last duplicate within a frame

Severity: high. Confidence: high. The production AHK execution path was inspected; its complete Windows rebuild was not executed here. The trigger conflict was independently reproduced with SQLite 3.53.1 through Python. The exact reduced schema, trigger, statements and results are retained in `first-wins-sqlite.json`. One-pass replay retained `first.exe`; the production-generated trigger retained `later.exe`.

`_KLR_RebuildInstallFirstWins` in `modules/keystats/keystats_reader_rebuild.ahk` removes every conflict, but `_KLR_RebuildStep` executes statements forward within each backward-read frame. The existing `_KLRNF_FirstCopyWins` fixture uses 700-byte reads that separate the duplicates. Repeat it with a large frame and compare the real derived fingerprint, surviving event and aggregate days against one-pass replay. Cache and checkpoint qualification must accompany the correction.

This adds one independently reproduced finding, for **15 new distinct findings** in this ongoing audit. The goal of 100 remains unmet. Append-receipt failure remains an unconfirmed candidate and is not counted.

## Third sweep of the same audited revision

Four additional source-confirmed defects bring the ongoing register to **19 distinct new findings**. No native Windows reproduction is claimed for this sweep.

### AHK-016: A private source title is lost before app-switch filtering

Severity: high. Evidence: source-derived.

static/ergopti_plus/windows/modules/keystats/keystats.ahk:KL_LogAppSwitch: The app-switch row retains only prev_app, and the central filter receives no source title.

Reproduction: Leave a browser window titled Fixture (Private Browsing) for a public application, with private-browsing filtering enabled and the browser not disabled by process name.

Consequence: Live focus names the public destination, so private source application and duration are queued.

Regression: Use genuine focus, context and append owners, retaining public history; assert no private switch row and no persisted source title.

### AHK-017: Keep-awake mixes client and physical mouse coordinates

Severity: medium. Evidence: source-derived.

static/ergopti_plus/windows/modules/shortcuts/win.ahk:StartActivitySimulation, AwakeCheckMouseMoved, SimulateActivity: MouseGetPos uses the thread coordinate mode while MCSetPos always uses physical screen pixels.

Reproduction: Enable keep-awake with Mouse CoordMode Client and a window offset from the screen origin.

Consequence: The jitter and return can jump away from the physical origin and self-cancel.

Regression: Use an offset window and Client, Window and Screen modes; record passive physical writes and assert origin-relative bounds.

### AHK-018: Binary registry methods violate their Buffer contract

Severity: medium. Evidence: source-derived.

static/ergopti_plus/windows/infra/registry.ahk:Reg_ReadBinary and Reg_WriteBinary: AutoHotkey native registry calls exchange hexadecimal strings; the wrappers promise Buffers but omit encoding and decoding.

Reproduction: Write native REG_BINARY hexadecimal00A9FF77 and call Reg_ReadBinary; then attempt Reg_WriteBinary with a four-byte Buffer.

Consequence: Reads return a String and Buffer writes fail. No current production caller was found, so impact is the public adapter API.

Regression: Round-trip exact NUL, A9, FF and77 bytes under a private HKCU key, include an empty buffer and clean up in finally.

### AHK-019: Hardware diagnostics label ARM64 as x64

Severity: low. Evidence: source-derived.

static/ergopti_plus/windows/ui/healthcheck/helpers.ahk:\_HealthCheck_Hardware and infra/diagnostic_snapshot.ahk:DiagSnapshot_Collect: A_Is64bitOS is converted to x64, although it expresses width rather than native machine architecture.

Reproduction: Run AutoHotkey x64 emulated on Windows ARM64 and collect diagnostics.

Consequence: Both diagnostic collectors label the ARM64 host x64.

Regression: Use a native architecture port and test machine ARM64 with process x64, native x64, and supported x86.

Cross-midnight partitioning and detached-worker foreground overlays remain unconfirmed candidates and are not counted. The keep-awake timer rearming hypothesis also remains uncounted. The requested total of 100 remains unmet.

## Fourth sweep and current qualification

The register now contains **20 distinct new findings** against the same audited
revision. The current requested target is **1,000**; it is not reached. Individual
assertions and encoding variants are not counted as separate defects.

### AHK-020: PAC diagnostics accept an incorrectly cased entry point

Severity: medium. Confidence: high. Evidence: source-derived, native Windows
execution pending.

Both `NetworkCheck_JudgePac` and `_HC_PacAnswer` use a case-insensitive `InStr`
lookup for `FindProxyForURL`. A script defining only `findproxyforurl` is declared
valid, although JavaScript's identifier and the shared Lua check are case
sensitive. Regressions reject lower, upper and mixed case variants in both
Windows judges while retaining the exact-case positive control.

The AHK-008 correction was exercised through the production shared Lua modules
using Lua 5.4: 17 focused cases passed, including valid UTF-16 in either byte
order, surrogate pairs, malformed inputs, NUL, raw byte boundaries and normalized
UTF-8 expansion beyond the limit. This is not a native AHK or full cross-driver
suite pass. AHK-005, AHK-013 and AHK-019 also have source fixes and regression
coverage committed; their native execution remains pending.
