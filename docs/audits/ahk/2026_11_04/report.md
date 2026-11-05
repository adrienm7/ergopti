# Windows audit campaign, 4 November 2026

Audited commit: `9154723b34ee0599433cbf749a4aca839bd54b53`. Scope: ErgoptiPlus Windows; read-only parallel passes covered keystats, input, UI and LLM request handling. Evidence is derived from production source and existing tests. The findings below have not all been executed on native Windows. No performance numbers were measured.

## Goal and evidence standard

The requested goal is 1,000 distinct new confirmed defects. The ongoing register currently records **138 distinct findings**. The initial snapshot contained eight findings. Earlier fixes on the branch precede this baseline and are not counted in this snapshot. Duplicate sites, policy disagreements and unconfirmed hypotheses do not increase the count. Implementation history and native qualification remain separate from source confirmation.

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

## AHK-021: Revoked input still updates ROI after ergonomic publication

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/modules/keystats/keystats_hook.ahk:\_KL_Hook_CommitInput does not revalidate its arrival after ErgoFn.Call before dispatching the ROI sink.

Reproduction: Type hello, then deliver a space through the genuine hook with its ergonomic callback pausing capture, invalidating the capture generation or changing the focus generation.

Consequence: An arrival revoked during the ergonomic callout still clears the current ROI word and increments its candidate count.

Regression: Use the genuine hook and ROI owners in the isolated keys fixture; revoke through the official ergonomic callback port and require the ROI seed and WPM count to remain unchanged. This qualifies the explicit callout boundary, not atomicity of the whole ROI pipeline.

The ongoing register now contains **21 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-022: Multi-character InputHook payloads bypass ROI boundaries and bounds

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/modules/keystats/keystats_trigger_roi.ahk:KL_Roi_OnChar treats its complete callback payload as one character. InputHook.OnChar can deliver multiple characters after an unsuccessful dead-key composition, and a Unicode codepoint can occupy two UTF-16 units.

Reproduction: Through the genuine hook, append native documented dead-key payload ^z after 63 a characters, then a space. Separately deliver ^.world followed by a space in one callback after hello.

Consequence: A candidate exceeds the 64-unit storage bound, or delimiters inside the callback are embedded in a combined word rather than separating words.

Regression: Use genuine hook and ROI owners to reject a 63-unit prefix plus a two-unit payload or surrogate pair, then assert separate candidates for a callback with an internal delimiter. Native payload shape is documented by AutoHotkey InputHook.OnChar; Windows execution remains pending.

The ongoing register now contains **22 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-023: Session lifecycle requires a key clock retired by synthetic input

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/modules/keystats/keystats_watchers.ahk:KL_Watchers_IdleTick returns on the retired key clock despite computing the valid accepted boundary. modules/keystats/keystats_collection.ahk:KL_ResetSession forwards the same zero sentinel to the genuine closer instead of considering last_authorized_tick.

Reproduction: Use the existing genuine callback sequence from \_KLF_Synthetic, which retains accepted activity1000 but retires KLHook.last_tick to0. Before another manual key, expire the idle timer or request session reset.

Consequence: An abandoned session never expires until another manual key; explicit reset can throw ValueError when elapsed time is computed from a positive session start to zero.

Regression: Run genuine capture, synthesis, idle, pointer and session-close owners against the recording append boundary. Cover idle expiry, reset, pointer activity extending reset, and a session legitimately starting at tick zero. Preserve the key clock sentinel for the next manual key's delay.

The ongoing register now contains **23 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-010 implementation qualification

The update window now retains one exact pending host while the synchronous
WebView factory pumps messages. Closing it revokes admission and hides its HWND;
a late controller is retired before that HWND is destroyed. Completion cannot
publish into a replacement request. Failed cleanup retains the same owner for
retry instead of destroying the controller's parent early.

Seven isolated native GUI regressions cover current success, closure, reopening,
late rejection, current rejection with native fallback, and refused controller
cleanup after both late and partial acquisition. They use the shipped Promise,
real GUI close events and the public update API, with a passive browser factory.
The fake controller checks that its HWND exists and its subscription count is
zero at Close. These regressions are added but remain unexecuted on this Linux
host; they do not constitute a real Edge runtime test.

## AHK-024: A retired keep-awake keyboard callback stops its successor

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/modules/shortcuts/win.ahk:AwakeCancelOnKeypress checks the callback type and active flag but never compares the supplied InputHook to the current AwakeInputHook owner.

Reproduction: Start keep-awake A and retain its genuine InputHook, stop A, start B, then deliver the queued callback AwakeCancelOnKeypress(HookA,0x41,0x1E).

Consequence: A delayed callback from the stopped observer cancels the newly activated session B.

Regression: Extend the isolated keep-awake native owner fixture with actual Start/Stop and two genuine InputHooks. Controlled old-callback delivery must preserve B; current B delivery must stop B. Position and timers remain passive, without physical mouse displacement.

The ongoing register now contains **24 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-025: Native model browser hides after a refused model selection

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/ui/model_browser/init.ahk:\_LLM_ModelBrowser_PickRow ignores the transactional Boolean returned by LLM_Menu_SetModel and always hides the browser. The Web sibling closes only after an acknowledged success.

Reproduction: Open the native model browser, hold a genuine configuration write lease, select model B and click Pick.

Consequence: The unchanged model A remains selected but its native browser disappears, presenting the refused operation as finished.

Regression: Use the genuine native browser construction, actual Pick button, full boot/configuration/menu owners and a real write lease. Require visible UI and unchanged file/RAM after refusal; release the lease and require a durable B selection and hidden UI after retry.

The ongoing register now contains **25 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-026: Native model selection persists while the driver is paused

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/ui/model_browser/init.ahk:\_LLM_ModelBrowser_PickRow has no pause admission guard. Native GUI callbacks bypass Suspend, and the downstream menu transaction validates schema and leases rather than input pause. The Web sibling explicitly rejects suspended model actions.

Reproduction: Open the native model browser before Suspend(true), select B and deliver a genuine Pick button click while still suspended.

Consequence: A model selection can reach the durable writer and publish new live configuration despite the user's driver pause.

Regression: Use the genuine native browser, observe its actual WM_COMMAND button event while suspended, and require no transaction/writer entry, unchanged durable/RAM state and visible UI. Resume must not replay the click; a fresh unpaused click must still durably select B.

The ongoing register now contains **26 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-027: A single model word bypasses parser work and allocation limits

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/modules/llm/parser.ahk and \_shared/lua/llm/parser.lua bound word counts but not character counts or dynamic-programming grid sizes. Character distance and token substitution consume quadratic work; substitution allocates a full matrix. Tokenization and raw cleanup also expand entire oversized words.

Reproduction: Parse a 500-character a buffer and TAIL_CORRECTED containing8000 a characters with NEXT_WORDS suite. This8034-byte answer is below the transport ceiling and still contains only one corrected word. Repeat with an oversized next-word field or raw response.

Consequence: A small admitted server response can stall the message/input thread or allocate excessive memory. The actual Lua baseline takes about2.08 CPU seconds and sampled87MiB for an8KiB answer; no AHK runtime measurement is claimed.

Regression: Both ports read one canonical policy:4096 UTF-8 bytes per operand and262144 cells per conservative diff grid. Refuse oversized corrections, next words and raw output before expensive helpers, then recheck actual normalized diff operands. Assert inclusive byte/cell boundaries and multibyte accounting on Windows; retain all32 shared physical golden vectors. Six real Lua cases pass after the audited baseline fails the oversized-word refusal.

The ongoing register now contains **27 distinct new findings**. The requested target of 1,000 remains unmet.

## Error-dialog sibling retirement invariant

The pending-host and retryable-retirement invariant was also corrected in the
error dialog, without incrementing the distinct-finding count. Its former
startup fixture required the native HWND to be destroyed during the unresolved
factory; it now requires that HWND to remain alive and hidden until the returned
controller is closed. The same record owns startup and cleanup, including a Close
during navigation after publication.

The extended seven-mode native component checks subscription destruction before
Close, live HWNDs during every Close attempt, current refusal/retry and old-host
retry while B remains current. Rejected factories never transfer their fake
controller and must incur zero Close attempts. Native execution of this extension
is pending. The JavaScript teardown guard passes all 28 checks, and an in-memory
mutation removing the actual subscription release makes that guard fail.

## AHK-028: Native environment overrides accept an embedded NUL value

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/adapters/shell_runner.ahk:ShellRunner_BuildEnvironment validates String types but does not refuse NUL before serializing overrides into a launchable NUL-delimited Unicode block.

Reproduction: Build an environment from Map(ERGOPTI_PROBE, keep plus Chr(0) plus drop). The actual Map value preserves its complete length but the native environment uses NUL as its entry delimiter.

Consequence: The child cannot receive the requested complete value and instead sees a shortened value or malformed block. Arbitrary variable injection or execution has not been measured. Ordinary Map keys truncate NUL before enumeration, so that earlier candidate is explicitly not claimed.

Regression: After actual Map construction, authenticate its retained NUL value and require ValueError for leading, middle and trailing positions. A real native child control verifies exact Unicode, spaces and equals, empty-entry encoding, case-insensitive replacement and an unchanged parent environment.

The ongoing register now contains **28 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-029: Crash reports count logical processors from only the first socket

Severity: low. Confidence: high. Evidence: source-derived; native Windows execution pending.

static/ergopti_plus/windows/vendor/ergopti_crash_worker.ps1 selects the first CIM processor; modules/diagnostics/crash_reporter.ahk:\_CrashReport_SysInfo likewise reads only the first WMI instance. NumberOfLogicalProcessors describes its current processor instance, not every socket.

Reproduction: Collect CPU diagnostics from two Win32_Processor instances reporting8 and12 logical processors. The worker and legacy fallback report8 instead of the machine total20.

Consequence: Multi-socket crash reports understate machine CPU capacity. The first model name remains a label; the logical processor count must aggregate all instances.

Regression: The real isolated worker's existing CIM boundary now returns two heterogeneous8+12 sockets and requires20. The legacy aggregation helper tests the same total, first-name preservation, single socket and explicit rejection of empty or incomplete processor observations. Native Windows execution remains pending.

The ongoing register now contains **29 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-030: Cold locale loads accept stale same-second translation caches

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_I18nTsvIsFresh in static/ergopti_plus/windows/infra/locale.ahk accepts timestamp equality despite FileGetTime exposing only whole seconds. On a cold load no prior source hash invalidates the stale complete cache.

Reproduction: Publish a complete TSV containing before, replace its authoritative JSON with after, set both modification times to the same second, clear the active cache identity and load the locale.

Consequence: The old translation is served and associated with the new JSON hash, so subsequent identity reuse can retain stale text.

Regression: The reachable test_i18n.ahk cold-load regression uses real durable JSON writes, the real TSV publisher and identical native file timestamps; it asserts refreshed memory and disk values, plus a strictly-newer positive fast-path control. Native Windows execution is pending; the pre-fix failure is source-derived.

The ongoing register now contains **30 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-031: Automatic native ListView sorting shifts the active model selection

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_LLM_ModelBrowser_Build in static/ergopti_plus/windows/ui/model_browser/init.ahk enables native Sort while \_LLM_ModelBrowser_RefreshRows records the active insertion index before all later rows are inserted. Native lexical sorting invalidates both the intended parameter ordering and that index.

Reproduction: Open the native catalogue with Qwen3.5-9B active. Its numeric parameter ordering inserts Qwen3.5-27B later, but lexical automatic insertion places 27B before 9B and moves the remembered active row.

Consequence: The highlighted row can designate a different model, so accepting the initial selection may unexpectedly change the configured model.

Regression: Extend the reachable model-browser-close-pause-owner native child with native-sort: genuine boot and catalogue, real Gui/ListView construction, active row identity and 9B-before-27B assertions after construction, refresh, filtering and filter removal; no-match and durable-no-write controls. Native Windows execution is pending; pre-fix failure is source-derived.

The ongoing register now contains **31 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-032: Token exchange throttling and timeouts are reported as invalid API keys

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_LLM_TokenExchange_OnAnswer in static/ergopti_plus/windows/modules/llm/api_token_exchange.ahk labels every 4xx response key_refused. \_LLMRemote_ReadyOnAccess consequently rewrites a throttling or timeout response to HTTP 401 and the menu selects the invalid-key diagnosis.

Reproduction: Return HTTP 429 or 408 with temporarily_unavailable from the managed access-token exchange used by an API-entry validation.

Consequence: A valid stored credential is blamed for transient service or endpoint failures; the actual diagnostic status disappears from validation.

Regression: Eleven reachable owner-level tests retain 400/401/403 authentication refusals and replay 404/405/408/413/429/503 through genuine exchange settlement, retained retry backoff and waiter reuse; 408/429 additionally exercise actual remote readiness and menu failure classification. Existing OAuth 400 and 401 authentication controls remain. Transport is a declared passive PostFn port; native AHK execution is pending.

The ongoing register now contains **32 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-033: Log openers report no errors before buffered warnings reach disk

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

LogOpeners_OpenTodayErrors in static/ergopti_plus/windows/ui/log_openers.ahk checks FileExist without first settling the real logger queues. Warnings are intentionally buffered until the periodic flush. The main-log sibling likewise opens a stale disk snapshot. A flush return alone is insufficient because refused appends are requeued.

Reproduction: Emit a real warning with the periodic logger flush not yet delivered, then immediately invoke the errors-log action; alternatively open the main log while that warning is still buffered.

Consequence: The UI says no errors today despite an accepted warning, or opens a file missing the latest diagnostic. A locked sink can produce the same false answer unless retained delivery debt is checked.

Regression: Six isolated owned native logger children cover main/errors, genuine native sharing denial with retained exactly-once retry, and an explicitly controlled busy-owner observation. Launch reads the genuine file at the action boundary and requires the warning; notification must remain unused. Existing resolver action tests isolate their own logger queues. Native Windows execution is pending; the original failure is source-derived.

The ongoing register now contains **33 distinct new findings**. The requested target of 1,000 remains unmet.

## Native qualification checkpoint: 41881570724

The Windows replay at commit `29a2f9066820f996a7780213d9584f9bbcb37fc8`
completed production-entry compilation and native hotstring E2E successfully.
Its 39 selected cases passed 36 individually; the reversed run reproduced exactly
the same three failures. All six WPM recovery cases, the cold locale cache case,
the native model sort case, the two environment override cases, the processor
socket cases, PAC encoding, parser limits and error-dialog retirement passed.

The failures were regression-oracle errors, not accepted production passes:
native model refusal/paused cases indexed the raw text returned by ReadTomlFile
instead of an uncached parsed TOML map; the keyboard-only keep-awake case demanded
a movement timer that it intentionally never arms. Commits `010fb95` and
`c4b855e` correct these oracles while retaining the business assertions.

The next replay selects those three failed cases, the eleven token-status
regressions, six buffered-log owner cases and three existing log-opener controls.
That later selection has not yet produced a native verdict at this checkpoint.
The registry remains at **33 distinct new findings**, not 1,000.

## AHK-034: Deferred tap-copy retries survive suspend and can overwrite successor ownership

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

TapCopyCheckStop in static/ergopti_plus/windows/platform/remap/constants.ahk was never reached by production cleanup. The timer checked only the instantaneous suspended flag. Producer and timer continuations also mutated the global pending record after counter, sender or logger callouts without revalidating their exact generation.

Reproduction: Start a tap-copy check, enter native Suspend and the production remap teardown, resume before the retained 300 ms callback, then deliver that old callback with an unchanged clipboard counter. Also start a newer copy inside the counter or retry sender of an older check.

Consequence: An old Ctrl+C may be injected into the resumed context, or an obsolete check may clear a newer copy and issue its stale failure notification.

Regression: Seven reachable tap-copy-owner cases invoke the genuine suspend-owned remap drain with private empty modifier ledgers, native Suspend/resume and retained timer delivery; producer/counter/retry/logger callouts revoke or replace ownership and assert zero stale sends/notices plus successor timer preservation. Counter/timer/send/notice are explicit passive ports. Existing five copy verification controls remain. Native Windows execution is pending; pre-fix failure is source-derived.

The ongoing register now contains **34 distinct new findings**. The requested target of 1,000 remains unmet.

## Native qualification checkpoint: 41883594273

The Windows replay at `0cd7b7f951601cedda701d3a0c84841f3726efe8` passed
production-entry compilation and native hotstring E2E. Its selected cases passed
**21 of 23**, individually and in reverse order: eleven token-status cases, six
buffered-log children, three existing log-opener controls and the repaired
keyboard-only keep-awake case.

The two native model-selection tests still rejected their durable-data oracle:
the uncached TOML reader exposes literal dotted section names, rather than the
nested feature projection. Commit `049eaa8` corrects the oracle to
`Parsed["llm.models"]["ollama"]`; this later repair is not yet a native pass.

The next selection contains 31 cases: the two repaired model checks, twelve
copy checks, the native paths pause case and two retirement controls, plus twelve
explicit boot locator cases and two existing boot-selection controls. No native
verdict for those later changes is claimed here. The two additional validation
site fixes do not increase the register beyond **34 distinct new findings**.

## AHK-035: Managed GET redirects can forward a caller body to another origin

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

ergopti_managed_http_worker.ps1 in static/ergopti_plus/windows/vendor checks only whether a cross-origin method differs from GET. It does not inspect the current SendBody state and actual body length, while the genuine WinHTTP transport sends bodies independently of the method.

Reproduction: Send a nonempty body through the exposed managed GET adapter to an owned origin returning HTTP 301, 302, 307 or 308 to a different origin. The redirect loop strips headers but forwards the staged body.

Consequence: The adapter violates its explicit cross-origin payload policy by contacting the second origin with the original GET body. No current production caller sending a nonempty GET body was found; this is an exposed adapter-contract defect, not an observed end-user disclosure.

Regression: A reachable managed-redirect-body-owner AHK case launches the genuine worker with its real admission handshake and WinHTTP engine against two owned loopback peers. Twelve native controls require denial before target contact, empty-GET and 303 controls, same-origin body preservation, and existing POST denial. Native peers record only body lengths and SHA256 digests. The original raw transport controls remain. Native Windows execution is pending.

The ongoing register now contains **35 distinct new findings**. The requested target of 1,000 remains unmet.

## Native parse refusal checkpoint: 41886475613

The replay at `abcebe48f6a361237413e2ea74bcbfe984701093` was blocked before
behavioral qualification: the measured compiler rejected an unbraced
`if / try / else` in the new copy completion logger branch. Commit `07fb9c0`
adds the required blocks. This failed checkpoint certifies no behavioral pass
for the 31-case selection.

The next run retains those cases and adds the actual managed redirect worker
and existing raw WinHTTP controls (33 selected AHK cases). It also selects only
the eleven `http_client:` proxy-override E2E cases required by the changed worker;
the workflow checks their exact non-skipped completion count. All later native
qualification remains pending here. The register contains **35 distinct new
findings**; the target of 1,000 remains unmet.

## Native qualification checkpoint: 41888187588

The replay at `67eaa2b1f6463e8bbfeff22889265479fb8a15bf` completed successfully:
33 selected AHK cases passed individually and in reverse order, all eleven
selected HTTP-client proxy-override E2E cases executed without skips, and both
production-entry compilation and native hotstring E2E passed. This qualifies the
previously pending copy, native folder admission, boot-root and redirect changes
at that exact source revision.

The next pass isolates one new, unregistered modifier-ownership regression.
It drives the actual owner across Suspend, genuine remap teardown, resume and a
new acquisition, then requires the retired owner's unwind to preserve that new
reference. It is deliberately tested against the still-unfixed production
protocol before implementation. This expected-red probe adds no finding count;
HTTP E2E is explicitly outside this unrelated selection. The register remains
**35 distinct new findings**.

## AHK-036: Retired tap-hold frames can release or overwrite a resumed gesture

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

The remap owner protocol in platform/remap/constants.ahk identifies release authority only by key name. Native Suspend leaves waiting frames alive. A late finally therefore consumes a new reference, while paired Tab-up/finally paths can consume twice in the same epoch. Companion AltGr handback, roll decisions and layer teardown carry similarly unqualified identity across callouts.

Reproduction: Acquire a real immediate modifier, enter native Suspend and genuine remap teardown, resume and acquire the same modifier again before the old KeyWait frame returns. The retired frame consumes the new reference. The native fail-before replay41889866195 at7ee17bcef5076c4238a2e090cf41cb6d70ccf90b reports the exact missing-successor-ledger assertion.

Consequence: A held Ctrl/Alt/Shift can be released under another gesture or a newly physical-held key; an old frame may remove successor metadata or dispatch an obsolete tap after resume.

Regression: Fourteen reachable synthetic-owner cases drive the genuine modifier, Tab, AltGr, rollover and navigation-layer owners with native Suspend/resume and the real lifecycle drain. Passive input, clock and wait ports expose release receipts, debt, physical observations and exact successor preservation without typing into the desktop. Two additional dispatch cases use the genuine logger test sink to revoke during the actual cancellation log and preserve resumed tracking. Native qualification is recorded separately with exact revisions.

The ongoing register now contains **36 distinct new findings**. The requested target of 1,000 remains unmet.

The primary owner regression failed natively before the fix in run
`41889866195` at `7ee17bcef5076c4238a2e090cf41cb6d70ccf90b`.
The independent actual-logger sibling failed in run `41895428966` at
`d17134a05d7dcea57f92ff0dbf2b6bc3e7f80540`, both alone and in reverse:
an admitted control passed, while the revoked dispatcher emitted one tap
instead of zero. These are one gesture-authority family, counted once.
Source fixes are `7b0d49c` and `8ecf909`. The 99-case owner qualification
and post-fix dispatch replay remain pending at this documentation checkpoint.

## AHK-037: A raced physical modifier restoration loses its failed balancing release

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

TapHoldRestoreLiftedKey in platform/remap/constants.ahk directly sends a compensating Up after detecting a physical release racing its successful scalar re-press. Unlike failed Array-acquisition rollback, this independent producer never transfers the proven Down to the release-pending ledger when that Up fails.

Reproduction: On a Kana layout, run the genuine hotstring output lift around a delivered user-held AltGr. Release the physical key immediately after its synthetic restoration Down succeeds, then refuse the compensating Up. Native run41895428966 atd17134a05d7dcea57f92ff0dbf2b6bc3e7f80540 reproduces the missing pending-release assertion in both controls, individually and reversed.

Consequence: The restored modifier can remain logically down after the user lets go. Suspend or shutdown reports no outstanding key and never retries the missing balancing Up.

Regression: Two reachable raced-repress-release-debt cases run the actual hotstring lift/restore path on the production Kana key mapping with an explicit passive transport and physical-state observations. They distinguish successful delivery from refused attempts, require retained debt through refused real lifecycle cleanup, and verify subsequent cleanup or a fresh owner repairs it before further acquisition. Native fail-before proof is retained; post-fix native execution remains pending.

The ongoing register now contains **37 distinct new findings**. The requested target of 1,000 remains unmet.

## Native qualification checkpoint: 41895036223

At `7b0d49c1d628`, the primary AHK-036 owner protocol passed **99 cases
individually and 99 in reverse order**, with exact non-skipped native receipts.
The complete production-entry include graph compiled and the native hotstring
E2E corpus passed **90/90**. HTTP E2E was explicitly outside this input-only
selection. Evidence: [replay artifact](https://github.com/adrienm7/ergopti/actions/runs/41895036223/artifacts/13354254940)
and [production parse / E2E artifact](https://github.com/adrienm7/ergopti/actions/runs/41895036223/artifacts/13355716365).
This is targeted qualification, not a claim that the entire OS suite ran.

The subsequent dispatch-log sibling and AHK-037 debt repair were committed
as `8ecf909` and `a0048e1`. Their fail-before run `41895428966` passed the
admitted tap control, failed the revoked tap with one output instead of zero,
and failed both debt controls with a missing pending owner, alone and reversed.
The next replay at `1cd88b3` selects 34 cases including those four probes,
existing Kana lift / restore, synthetic transactions and dispatch controls.
Post-fix qualification of those two later changes remains pending here.
The register contains **37 distinct new findings**; the goal of 1,000 remains unmet.

## Native qualification checkpoint: 41896237104

At `1cd88b3`, all **34 selected cases passed individually and 34/34 in
reverse order**. Complete production-entry compilation and the native hotstring
E2E corpus passed **90/90**. The SQL preparation step also passed 15 native SQLite
and public CLI regressions. Evidence: [replay artifact](https://github.com/adrienm7/ergopti/actions/runs/41896237104/artifacts/13356801602)
and [production parse / E2E artifact](https://github.com/adrienm7/ergopti/actions/runs/41896237104/artifacts/13357295795).

This qualifies the actual-logger sibling of AHK-036 and both AHK-037 repair
paths after their documented native failures. The registered 37 findings now
have targeted native qualification for their source fixes. It does not qualify
the entire OS suite or promise the absence of other bugs. The next unregistered
probe tests literal control characters through genuine keystats producers and
SQLite; it adds no finding count before confirmation.

## AHK-038: Personal file publication can outlive its final editor or pause authorization

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_PersonalTomlWriteAtomic and \_PersonalInfoReplaceUnchanged in infra/hotstrings/personal_toml_io.ahk restore interruption after their pure authority checks, then invoke unguarded FSAtomicMoveReplace. The final native producer never resamples the revocable facts. Metadata patches also omit their already-issued owner from that final boundary.

Reproduction: At the genuine native replacement cutpoint after existing admission checks, close the real personal-hotstring editor, suspend the driver, release the exact path lease, relocate the configured path, or retire the captured information editor/resident map. Native run41897311070 at70481abbcdfc32060a2424b2a17b48fd19ac87ca passed the three live controls and reproduced all ten stale replacements, individually and reversed.

Consequence: A cancelled or paused save can still replace the personal file and publish a stale intention after the editor or path authority has retired. This differs from AHK-014 external source-byte mutation: the violated facts here are in-process owner, pause, configured identity and session authority.

Regression: Thirteen reachable personal native final admission cases use real private files, durable stages, actual GUI/source and lease owners, a declared interruptible internal cutpoint, and the genuine native rename producer. Three controls prove actual successful replacement; ten withdrawal variants require original target bytes, no publication and cleaned stage. Existing arbitrary two-argument ReplaceFn ports stay outside Critical. The fixed native branch uses FSConfigAtomicMoveReplace with a pure final guard; external-process filesystem compare-and-swap is outside this guarantee. Post-fix native qualification is pending.

The ongoing register now contains **38 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-039: Walker composite keys merge distinct literal application and token values

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

Windows walker constructors concatenate unescaped fields using Chr1 and then store that text in AutoHotkey Maps, whose string keys end at NUL. N-gram SQL reconstructs original field values by splitting the already ambiguous key. Other projection and per-application context constructors share that identity assumption.

Reproduction: Push literal tokens a and a+NUL+b through the genuine Windows n-gram producer, or push tuples (day,A+Chr1+B,C) and (day,A,B+Chr1+C), then flush through the actual SQL builder to native SQLite. Native run41896696315 atbe1e23b2047ebd958ed2d147c2a616c493c22a61 reproduces all three producer/replay probes alone and reversed: expected3 rows become2; genuine typing replay expected2 becomes1.

Consequence: Accepted replay data silently combines independent counts and delays and can persist truncated or reassigned application/token values. This concerns supported literal replay/JSON values; no physical-keyboard NUL sequence is claimed.

Regression: Three native fail-before probes retain literal SQL hex(app)/hex(token), repeated additive controls and a genuine typing replay. The fix escapes only internal tuple fields and preserves raw row values for SQL. Five further cases cover shared array byte vectors, real JSON context roundtrip and legacy retirement, cache17 refusal, checkpoint3 restart and obsolete stage cleanup. Existing aggregation, distribution merge, rollover and current checkpoint controls remain. Cache18/checkpoint4 force reconstruction without changing raw ledgers or persisted token encoding2. Scope is Windows: the separately measured shared Lua Chr1 collision and Linux aggregate-history migration remain open outside this OS correction; no Lua source is changed. Post-fix native qualification is pending.

The ongoing register now contains **39 distinct new findings**. The requested target of 1,000 remains unmet.

## Native qualification checkpoint: 41898084279

At `83bb702`, **53 selected personal publication and native-guard cases passed
individually and 53/53 in reverse order**. Production-entry compilation passed,
with a successful full-graph receipt and no parse skip. The native SQLite / CLI
preparation controls passed 15 cases. Evidence: [replay artifact](https://github.com/adrienm7/ergopti/actions/runs/41898084279/artifacts/13356668542)
and [entry artifact](https://github.com/adrienm7/ergopti/actions/runs/41898084279/artifacts/13356763051).

AHK-038 therefore has measured fail-before (three positive controls and ten
withdrawal failures) and pass-after native evidence. The entry artifact explicitly
records hotstring E2E as `not-selected`, with `full_suite_qualified: false`;
HTTP E2E is also outside this file-publication selection. Neither exclusion is
reported as a behavioral pass. AHK-039 awaits its 111-case aggregation, migration
and rebuild replay; the register remains **39 distinct new findings**.

## Native qualification checkpoint: 41898714754

At `1a7b4bd`, **111 selected aggregation, tuple, context, rollover, distribution,
cache and checkpoint cases passed individually and 111/111 in reverse order**.
The measured replay summary records 111 selected cases, zero failures and
113 children including discovery and reverse, with `full_suite_qualified: false`.
Production-entry compilation passed without skips; the 15 native SQLite / CLI
preparation controls also passed. Evidence: [replay artifact](https://github.com/adrienm7/ergopti/actions/runs/41898714754/artifacts/13357308073)
and [entry artifact](https://github.com/adrienm7/ergopti/actions/runs/41898714754/artifacts/13357163460).

This qualifies AHK-039 after its three measured native row-collision failures.
Hotstring E2E is explicitly `not-selected`; HTTP E2E is also outside this
statistics-only selection. All **39 registered Windows findings** now have
source corrections and targeted native qualification. The requested 1,000 is
still unmet and further candidates remain under investigation.

The unregistered thinking-retry probe at `78a0050`, run `41898825207`, failed
before reaching its intended business assertion. Its positive control did not reach the refusal log. The proposed explanation
that the response must name `thinking.type` was subsequently refuted: an added
whole object can be named `thinking`. Both spellings are valid for that case.
A separate fixture cleanup read a destroyed GUI object's handle and was repaired
by retaining its native HWND. The later probe recorded a real HTTP400 response
and an intercepted Integer.\_\_Item callback error before the intended cutpoint;
its exact source is still under investigation. Neither failed probe proves the
proposed production cancellation finding or increases the register count.

## AHK-040: Refused native entry edits leave a ghost editor model and block retry

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_AddEntry, \_SaveEntry and \_DeleteEntry in ui/personal_toml_editor.ahk mutate \_PersonalEditorData before \_SaveData obtains the durable/live transaction receipt. Failure never restores model/ListView agreement. A simple rollback would lose overlapping DEFERRED snapshots, so complete detached candidates and exact completion ownership are required.

Reproduction: Use the actual native personal editor and a real read-shared file handle denying write/delete. Click Add, Delete or Save through BM_CLICK. The native rename refuses, but the mutable editor model already contains the edit while the file and ListView retain their old values. Native run41900510051 at7306179ef66936fd43660b7382c65d702d0f1cc0 reproduces the exact unchanged-model failures for all three operations, alone and reversed, plus section/legacy variants.

Consequence: An invisible non-durable added entry blocks its own retry as a duplicate. A refused deletion leaves old native row indices pointing into a different model, so a later retry can address another entry. Deferred and section publications must preserve their visible unsaved drafts without stale completion effects.

Regression: Ten reachable personal-entry-receipts cases use real GUI controls, native button messages, a real sharing-denial handle and unlocked same-form retry. They also drive actual coalesced publication, terminal deferred failure and complete-snapshot recovery, dropdown/section changes and the legacy save entry point. The fix installs detached candidates only after immediate success or explicit DEFERRED admission, keeps RAM and rows coherent, and fences completions by source/cohort/sequence. Existing modal and live transaction controls remain; native post-fix qualification is pending.

The ongoing register now contains **40 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-036 additional settled-capture sibling

Native replay `41901785093` at `afc1dd3` reproduced both `activation-revoked`
and `activation-successor` failures at the exact zero-emission assertion,
individually and reversed. The existing special-result control passed. A native
timer pauses, invokes the genuine empty-ledger remap drain, observes that the
already-settled SIHO capture no longer exists, resumes and optionally admits a
fresh SIHO successor. The old OneShot body still emits its special result.

The fix retains the same gesture epoch through OneShot activation and output;
it returns without touching a successor when revoked. SICS/SICU extracted native
children now carry the two real owner helpers. This extends AHK-036 and does not
increase the register beyond **40 distinct findings**. The earlier seven-case
compatibility selection refused discovery because another ownership test shares
its tag (eight matches); no behavioral pass is claimed from that refused plan.
The next cohort uses exact discovered case names.

## AHK-041: Cold hotstring caches can register rules from retired or replaced sources

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

infra/hotstrings/hotstrings_cache.ahk treats later TSV timestamps as source identity, skips missing dependencies, and derives cache paths from an effective resolver that can point at extensions. The TSV has no record of the canonical index image actually consumed, source paths/presence or content hashes. The initial rebuilt RAM projection also needs admission after the writer and its yielding diagnostics.

Reproduction: Publish a genuine cache, remove its authoritative bundled TOML, or edit that TOML after actual BuildRows but before actual WriteTsv. Alternatively build while a real scanned extension binds autocorrection, then remove that extension and route. Native run41903520217 atdd8ee6ae63db99448f548466b3fbfba89389e8d0 passed the unchanged live control and reproduced all three ghost registrations through the real Ensure/category registrar, individually and reversed.

Consequence: Removed or replaced rules become active native triggers on a cold load. A cache can silently retain extension data after its source is gone, or bless older parsed content with a newer publication timestamp.

Regression: Four native fail-before cases use real temporary canonical sources, the actual index memo, real extension scan/routing and actual HSE registration. The single-file TSV fix records consumed index/source provenance plus closed row/count/payload proof and validates the exact parsed candidate. Physical bundled resolution is separate from adopted extension routes. Two additional initial-publication cases use real stage sharing denial and the genuine logger sink to edit a category or index after BuildRows. Rebuilt RAM snapshots are checked after writer callouts, retried at most twice and otherwise refused with cleared maps. Valid TOML loading still works when cache writes fail. Three existing freshness owners now publish genuine source-backed fixtures. Native post-fix qualification is pending; no cold-load performance measurement or filesystem-wide external CAS is claimed.

The ongoing register now contains **41 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-042: Raw body retries bypass current access-token preparation

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

LLM_RemotePostBody_Async in modules/llm/api_remote.ahk reserves its request then dispatches the retained Resolved.Token directly. Generate calls \_LLMRemote_NeedsAccess and \_LLMRemote_WithAccess, but thinking retries and screen-reading bodies using RawPost omit that preparation. NeedsAccess must be called even when it returns false because it refreshes the retained Token from the current slot.

Reproduction: Prepare an original resolved record through the genuine cached-access owner, then renew or expire its token slot before calling RawPost. Native run41904156246 ate26726d4ca7ea2d98dd2370648ca15f1dcc5dbf0 passes the fresh control but publishes Bearer old-token instead of the actual renewed new-token. Four expired-slot variants also reach a transport before starting exchange. All failures reproduce individually and reversed.

Consequence: A later body can carry an expired or superseded credential and receive an avoidable authentication refusal despite a valid current cached access token or available refresh.

Regression: Six token-rawpost-owner cases run the actual resolver, original access preparation, token engine, RawPost reservation, managed facade and transport.json serializer. Only exchange HTTP and process spawning use existing explicitly controlled I/O ports; this is no native wire-success claim. The actual published header must use current access; expired slots await exchange under the same id, clock and deadline. Cancellation, elapsed deadline and native pause must prevent dispatch. The optional final TransportPort defaults to zero and forwards the preexisting downstream test boundary without changing current callers. Native fail-before proof is measured; native post-fix qualification is pending.

The ongoing register now contains **42 distinct new findings**. The requested target of 1,000 remains unmet.

## Native partial qualification checkpoint: 41904156246

At `e26726d`, all **38 selected OneShot/capture cases passed individually and
in reverse**, including the two previously failing activation variants and both
updated extracted-child families. This qualifies the additional AHK-036 sibling.
The fresh RawPost control also passed; the five remaining RawPost variants failed
at the measured stale-header or premature-transport assertion recorded in AHK-042.
The earlier six RawPost failures at `afc1dd3` only exposed a fixture setup omission:
resolver output intentionally starts without an access token, so the setup now
performs the same genuine initial access preparation as Generate.
No aggregate green verdict is claimed for this mixed 44-case discovery run.

## AHK-043: Managed HTTP failures discard the provider classification and message

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_LLMRemote_PollRequest classifies the actual managed response then replaces reason and server_message with hard-coded transport and an empty string when terminal_ok is false. The curl consumer already forwards these classifier fields.

Reproduction: Native loopback run41907263356 at8a5643a passes the real HTTP200 completion control. The HTTP400 peer receives exactly one POST and returns owned-classification-refusal, but the genuine callback receives transport and an empty server_message rather than provider_error and the actual refusal. The same failure occurs individually and reversed.

Consequence: Provider refusals lose their explanation and cannot reach existing request-field retry decisions; callers instead receive an inaccurate transport failure.

Regression: Two managed-http-classification cases use the actual Generate path, native owned loopback peer, real managed HTTP body and neutral callback collectors. The genuine network host is initialized and restored under an exclusive fixture scope. HTTP200 must complete once; HTTP400 must preserve the actual classifier reason, exact server message and retained network report. Native fail-before measured; post-fix qualification pending.

The ongoing register now contains **43 distinct new findings**. The requested target of 1,000 remains unmet.

## Native cache and editor qualification: 41907002685

At `14c9580`, all **66 selected cases passed individually and in reverse**, including the complete selected cache provenance family and the five editor gateway/isolation adapters. This qualifies AHK-041 and completes the AHK-040 native evidence alongside the previously passing 71 UI cases. The complete production graph compiled, all 15 selected SQLite regressions passed and native hotstring E2E passed **90/90**. Native HTTP E2E was outside selection; no complete-suite qualification is claimed.

## AHK-044: Cancelled API tests can dispatch a thinking-field retry after losing their original reservation

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

The Menu API test supplies callbacks and a request kind to Generate without its supported CurrentFn authority. CancelAsync(original) cannot find a retry that has not yet been reserved, so the retry sender is admitted after the progress owner is gone.

Reproduction: Native run41908674329 at944d513 passes the two-POST thinking-retry control. At the actual refusal logger cutpoint the original reservation is already retired; cancel the genuine progress window there. Its owner and window retire, but a new second reservation and second native HTTP POST still appear. The exact expected1/observed2 failure reproduces individually and reversed.

Consequence: Clicking Cancel can still send another prompt to the provider after the native progress window closes and the auxiliary test owner is retired.

Regression: Two api-thinking-retry-owner cases drive the actual native Menu progress GUI, genuine Generate/managed HTTP and an owned loopback peer. A real logger sink cancels exactly between original retirement and retry admission; the positive control must issue two requests and settle successfully, while cancellation must leave one request, no retry link and no retired UI publication. The fix binds the exact progress owner through the existing Generate CurrentFn argument. Native fail-before measured; post-fix qualification pending.

The ongoing register now contains **44 distinct new findings**. The requested target of 1,000 remains unmet.

## Native LLM qualification checkpoints: 41908552045 and 41908674329

At `36e7a60`, all **15 selected access-token/RawPost cases passed individually and reversed**, with complete production compile and the 15 SQLite controls. This qualifies AHK-042. At `944d513`, both native HTTP classification cases passed, including the actual HTTP400 provider message, qualifying AHK-043; the positive thinking retry also passed, while its cancellation sibling reproduced AHK-044. No aggregate green is claimed for that four-case mixed run. Both E2E families were explicitly outside these selections.

## AHK-045: Queued key-combination chords replay input during native pause

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

KeyCombinationChordTick treats suspension as a reason to flush a waiting key, and KeyCombinationChordDrain sends its retained queue without pause admission. Neither batch retains lifecycle authority, so resume before delivery and reentrant successor callbacks also require fencing.

Reproduction: Native run41908766133 atb4eff5c passes both unpaused controls. Suspending before real SetTimer delivery still emits the waiting key (expected0/observed1) or the queued scan (expected1/observed2). Both failures repeat individually and reversed.

Consequence: The paused driver can inject a key it retained before pause. A retired callback can also act on a newly admitted waiting or queued batch after lifecycle teardown and resume.

Regression: Four chord-native-pause cases deliver real native poll/drain timers around Suspend; production chord policy and engine remain genuine while keyboard transport is observed through its existing recorder. Two positive controls prove actual replay; two paused cases must discard unsent work and keep it retired after resume. No balancing-Up change or physical keyboard proof is claimed. Native fail-before measured; source correction and extended owner regressions are under review.

The ongoing register now contains **45 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-045 correction under native qualification

The chord batch now retains exact lifecycle authority through waiting, queued replay and yielded probes. Each directly owned short send is admitted atomically; old callbacks cannot clear a successor batch. Four additional owner cases cover resume before timer delivery and held-state/logger interruptions. The fixture refuses foreign live chords and restores exact inactive state; physical key-release behavior is unchanged and unqualified here. Native post-fix results are pending.

## AHK-046: Clipboard native monotonic ages are truncated into DWORD aliases

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

KL_Clip_OnPaste computes native A_TickCount differences with an explicit UInt32 mask for copy_lag_ms and retained paste_ticks. These origins are full-width monotonic ticks rather than clipboard sequence DWORDs. Retained old copy/burst state can therefore alias recent activity after 2^32 milliseconds.

Reproduction: Native run41909512571 ata6373a4 passes the ordinary clock control but both one-era and two-era cases fail the full copy-age assertion, individually and reversed. Genuine accepted copy/paste producers own the timestamps; only the actual paste clock observation is bound to a later native64 value.

Consequence: Long-lived retained clipboard metadata reports a short copy age and can turn ancient pastes into a fresh burst after roughly49.7 days or a multiple thereof.

Regression: Three clipboard-paste-native64 cases use actual accepted copy/paste producers, native privacy/context/queue owners and an isolated existing child. Only the unique current paste-clock read is bound; no timestamp state is assigned. Ordinary activity, one/two DWORD eras and subsequent fresh activity must preserve full lag and burst retirement. TickElapsed64 replaces the two masks without changing copy provenance. Native fail-before measured; post-fix pending. No49-day native uptime is claimed.

The ongoing register now contains **46 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-047: A late token answer can mark an expired readiness request successful

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_LLMRemote_ReadyOnAccess checks auxiliary identity but omits the stored absolute whole-request deadline. For a nonlisting request it publishes true immediately after successful token preparation even if the due deadline timer has not yet run.

Reproduction: Native run41909512571 ata6373a4 passes the timely token answer. A genuine answer timer begins while the request owner is current and its clock live, then crosses the unchanged96ms deadline under Critical before delivering the actual token answer. Readiness returns true instead of false, individually and reversed.

Consequence: Save-time credential validation can report success after its total request budget expired, depending on native callback delivery order. The shared usable token may correctly remain cached while the expired individual validation must fail.

Regression: Two token-ready-deadline cases run public readiness and the genuine token engine through the existing passive exchange HTTP port, with actual AHK timer delivery. The late reply crosses the original real budget; neither origin nor duration is moved. Timely control, current-owner checks, exact one-result receipt and preserved token cache distinguish authority from credential lifetime. The narrow fix checks the original deadline in ReadyOnAccess. Native fail-before measured; post-fix pending. macOS/Linux token readiness continues through a request rather than this Windows-only nonlisting shortcut.

The ongoing register now contains **47 distinct new findings**. The requested target of 1,000 remains unmet.

## Native partial qualification checkpoint: 41909512571

At `a6373a4`, both native thinking-retry cases passed individually and reversed, qualifying AHK-044: the positive control issued two HTTP requests and cancellation retained exactly one. The complete production metrics JSON NUL regression also passed. Ordinary clipboard timing and timely readiness passed; the two native64 clipboard probes and late readiness case reproduced AHK-046/AHK-047. The eight-case mixed cohort is intentionally not reported green. Complete production compile passed; both E2E families were outside selection.

## AHK-048: Clamped hotstring delays lose their persistent relative offset

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_HotstringsRecordApplyBase clears PendingOffset after storing only the clamped effective Delay. Rebase and serialisation later reconstruct the offset from this lossy projection, while transaction clones also omit the original finite intent. The shared delay corpus explicitly requires retaining the original offset when the effect clamps.

Reproduction: Native run41910772341 atf7e7b2f passes the unclipped, unlimited and explicit replacement controls. Three cases fail individually and reversed: rebasing a clamped offset disagrees with a genuine reload; an unrelated colour save changes the source offset; returning the base after an intermediate clamp fails to restore the original effective delay.

Consequence: Changing a base delay or saving an unrelated colour silently changes a user’s configured timing intention, both in the live projection and on disk.

Regression: Six HotstringsConfig persistent offset cases use real TOML, the canonical typed decoder, production parser/projection/resolver, actual public colour and delay writers and fresh reload comparisons. The fix retains StoredOffset through projection and detached transaction clones; explicit delay edits replace it and clears retire it. Category and section paths are checked. Native fail-before measured; post-fix qualification pending. Shared Lua already preserves the offset in its rung and computes clamping only in projection.

The ongoing register now contains **48 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-049: Finite hotstring offsets override an explicit unlimited delay

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

The Windows parser independently admits the two correctly typed leaves, then \_HotstringsRecordApplyBase consumes the pending finite offset after Delay has already been set to zero by the explicit unlimited flag. The shared Lua resolver explicitly prioritizes true unlimited. This occurs above the clamp and is distinct from AHK-048.

Reproduction: Native run41910772341 atf7e7b2f passes unlimited-only and offset-only controls but fails both source orders containing delay_unlimited=true and delay_offset=-0.25 at base0.75. The actual valid TOML resolves finite instead of unlimited, individually and reversed.

Consequence: A valid explicit unlimited setting silently acquires a finite activation deadline, so expansions can be refused contrary to the chosen configuration.

Regression: Four HotstringsConfig unlimited precedence cases use real typed TOML, the actual parser/base projection/resolver and both category and section scope. Both leaf orders must be unlimited; single-leaf controls preserve finite and unlimited behavior. The fix clears finite projection state and returns when explicit unlimited has already been parsed. No format change. Native fail-before measured; post-fix pending.

The ongoing register now contains **49 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-050: The native personal-editor case checkbox does not control exact matching

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_BuildEntry derives is_case_sensitive from the checkbox but derives strict_case from an unrelated hidden argument. Add defaults that argument false and Save supplies the previous entry flag regardless of the current checkbox. The shared editor already maps this checkbox to both producer flags, matching the documented exact-match UI contract.

Reproduction: Native run41910772341 atf7e7b2f fails both genuine GUI probes individually and reversed: Add with the case checkbox checked persists strict_case=false; unchecking an existing strictly matched entry preserves strict_case=true after Save. Both use actual BM_CLICK and the durable native writer.

Consequence: The checked native editor can still match a differently cased trigger, while unchecking can leave exact matching enabled. The persisted configuration contradicts the visible option.

Regression: Two real PEER native GUI cases verify durable typed flags and then observe the registry actually published by the real commit through the genuine matcher, without output injection. A detached registry/matcher scope refuses an active prefix watcher, drains its genuine auxiliary timer and restores original state. The obsolete hidden-argument unit oracle becomes a checkbox matrix, and the unused argument is removed. Generic parsing/cache/dispatch preserve the independent flags. Native fail-before measured; post-fix pending. macOS/Linux shared editor producer already implements this mapping.

The ongoing register now contains **50 distinct new findings**. The requested target of 1,000 remains unmet.

## Native partial qualification checkpoint: 41910772341

At `f7e7b2f`, **52 selected cases passed and seven probes failed**, identically in individual and reversed execution. All 21 chord engine/lifecycle cases and 21 roll cases passed, qualifying AHK-045 with its adjacent admission callers. All three clipboard clock cases and both readiness deadline cases passed, qualifying AHK-046/AHK-047. The seven failures are the independently measured AHK-048/AHK-049/AHK-050. The full production graph compiled; hotstring and HTTP E2E were outside selection and no full-suite qualification is claimed.

## AHK-051: A token exchange revoked by pause imposes a provider-failure cooldown after resume

Severity: medium. Confidence: high. Evidence: source-derived; native Windows execution pending.

The managed facade loses the cause of its refusal when it represents pause revocation as an aborted status0 response. The later token polling consumer treats that result as a provider/transport failure and installs the normal60-second backoff. Checking current suspension only cannot distinguish a consumer delivered after resume.

Reproduction: Run41910983878 atc93908c passes success, HTTP403 and original-deadline controls. Pause after actual managed admission and deliver a late valid token response through the genuine facade. The facade correctly aborts with status0, but after resume the token slot retains retry_at and serves a cached failure: posts remain1 instead of2 and verdicts become2. The same failure reproduces individually and reversed.

Consequence: An explicit driver pause creates an artificial provider refusal for subsequent legitimate token requests, delaying normal operation after resume despite no provider authentication failure.

Regression: Five token-managed-pause cases use genuine Prepare/Begin/Post, managed facade admission and original deadlines, actual token polling timers and native Suspend. Only Job/HTTP process I/O is controlled, not a wire/process-native proof. Success,403 and timeout retain their intended policies; pause and resume-before-Poll require a fresh exchange without cooldown. A narrow facade latch records only an actual pause refusal on a still-active unexpired request, and the internal Answer conveys that fact to token settlement. Secondary cleanup failures remain visible. Native four-case fail-before measured; post-fix qualification pending. Prompt cancellation of a silent server is outside this finding.

The ongoing register now contains **51 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-052: Rollover can delete an unconsumed journal that replaces the checked file

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_KL_RolloverResume verifies the original consumed file through a reader that denies write sharing but permits deletion/rename. It then deletes by path, so the verified object and the deleted object can differ. Holding journal logical ownership does not pin an external filesystem replacement.

Reproduction: Native run41912869071 ate4e5e62 passes the unchanged-file control. In the swap case, real MoveFileExW succeeds while the verified reader remains open, a new today.log is written and its distinct native identity is confirmed. Resume then returns true instead of refusing. Its successful branch executes FileDelete on that replacement path and publishes final rollover state. The failure repeats individually and reversed; the baseline test stops before directly observing the post-return absence.

Consequence: A concurrent replacement journal containing new events can be deleted even though only its predecessor was consumed and committed, permanently losing those new events.

Regression: Two actual ingest/prepare/recovery cases use a narrow original I/O cutpoint, real native rename/replacement, actual journal owners, durable receipts and SQLite event verification. The fix clones the original consumed snapshot and uses FSDeleteVerified with a native receipt comparator; final removal marks the exact exclusively verified handle. A replacement must survive unchanged and retain pending recovery/offset; retry remains fenced without duplicate ingestion. The unchanged control must complete. Source-wiring tests retain EOF/prepare/save ordering and now require verified deletion with the original proof. Native fail-before measured; post-fix pending.

The ongoing register now contains **52 distinct new findings**. The requested target of 1,000 remains unmet.

## Native partial qualification checkpoint: 41912869071

At `e4e5e62`, **53 selected cases passed and seven probes failed**, with the same outcome individually and reversed. AHK-048 passed its six new plus ten adjacent override cases; AHK-049 passed all four precedence cases; AHK-050 passed both native GUI cases and its checkbox unit matrix; AHK-051 passed all five token cases and 14 adjacent managed-owner cases. Production compile passed, native hotstring E2E passed **90/90**, and HTTP adapter proxy-override E2E passed **11/11**, with no not-executed cases. The seven failing probes are assessed separately, including one gesture probe that needs its per-key setup adapted to native Max termination. No aggregate green or complete-suite qualification is claimed.

## AHK-053: Sticky modifier capture leaks the original nontext key before its modified replay

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

StickyModifier creates a text-suppressive InputHook but leaves VisibleNonText at its native true default. Ending nontext keys such as Backspace can reach the foreground application before the one-shot owner replays them with its chosen modifiers.

Reproduction: Native run41912869071 ate4e5e62 passes letter and Enter controls but fails Backspace individually and reversed. A real timer sends Backspace to a verified child-owned Edit while genuine StickyModifier/SIHO captures it: one original WM_KEYDOWN reaches the editor and removes its last character before the passive Ctrl replay is recorded.

Consequence: An application receives an unmodified editing/navigation action in addition to the requested sticky shortcut. The raw edit can already change text even if the modified output later refuses, or can make the combined shortcut remove more text than intended.

Regression: Three sticky-native-nontext cases extract the actual StickyModifier/Names owner and include genuine SIHO. Actual SendEvent input is explicitly opted in and confined to a verified child-owned foreground Edit; TextPressKey alone is passive. Native WM_KEYDOWN, edit content, exact modified output and cleanup must agree. Letter and Enter are native controls, not claimed failing variants; Backspace proves the defect. Setting VisibleNonText=false retains standard modifier visibility under the native InputHook policy. Native fail-before measured; post-fix pending.

The ongoing register now contains **53 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-054: A stale navigation-layer editor can overwrite a newer configuration

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

The Windows layer editor reads text for the page but retains no source receipt bound to its exact host, epoch, folders and target. GUI Save then uses an explicit unconditional writer, so it can adopt and replace later bytes from another editor.

Reproduction: Native run41912869071 ate4e5e62 opens the actual layer host with sourceA, independently writes valid sourceB, then delivers the old page save through the real SDK bridge and host dispatch. Its receipt records save_entered1, save_returned1, apply_calls1 and newer_bytes_preserved0, individually and reversed. The three adjacent ready-delivery controls pass.

Consequence: Saving an unchanged older page erases a newer navigation binding and requests applying that stale content. A retired host must also lose authority to request apply after a successful durable save.

Regression: The real LRDT host/native GUI, SDK callback, host timer dispatch and canonical corpus drive source-stale plus a fresh-host successful save. The fix captures the offered source once per host and uses the existing lease and admitted unchanged-source publisher; explicit non-GUI Save retains its existing contract. Exact host/epoch/folders/target admission persists through publication and is checked again after success logging before apply. A separate real WM_CLOSE-at-success-log probe observes saved=true/applied=false with zero apply calls. FakeHost save cases become explicitly inert rather than manufacturing consent. Native stale-source fail-before measured; post-fix pending. Linux already retains this opening receipt; the macOS sibling remains outside this Windows correction.

The ongoing register now contains **54 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-055: Wrap-symbol TOML projection can erase or corrupt valid settings

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

\_WS_Load interprets TOML using exact header strings and greedy double-quote regex captures without canonical lexical handling. Comments can hide a recognized table or enter its value. Literal/multiline strings and invalid recognized types also need a trustworthy typed projection so an incomplete interpretation cannot later be acknowledged as empty configuration.

Reproduction: Native run41912869071 ate4e5e62 passes four canonical/quoted/legacy controls. Three annotated valid TOML cases fail individually and reversed: an unrelated accepted AddCustom deletes the original pair after an annotated header; an annotated disabled value is serialized incorrectly; an annotated custom value prevents an otherwise valid save.

Consequence: A routine unrelated wrap-symbol edit can permanently remove a valid custom pair or re-enable/corrupt a disabled symbol. Valid source annotations can also make persistence unusable.

Regression: Seven inline-comment/quote/legacy cases use real Init, the actual shared catalogue, public AddCustom, independent typed disk decoding and genuine reload. The corrected loader alone uses the existing canonical lexer/decoder, preserves legacy semicolon comments and CSV/default-right behavior, projects into detached state and latches recognized unprojectable data. Writer and transactions are unchanged. Twelve extra spelling/compatibility/type-preservation probes cover the same family without increasing the count. The historical custom-before-disabled metadata test becomes an actual save/reload fixture retaining its original test identity. Native three-case fail-before measured; post-fix pending. Extra grammar variants are coverage, not separate native-confirmed findings.

The ongoing register now contains **55 distinct new findings**. The requested target of 1,000 remains unmet.

## Native fixture discovery checkpoint: 41918560789

At `c177720`, the 85-case replay never began: discovery exited2 at the wrap fixture’s single-quoted inline semicolon. This is a test-source parse failure, not a behavioral verdict. The production graph compiled and hotstring E2E still passed **90/90**; HTTP E2E was outside selection. The fixture now constructs the same semicolon character with Chr(59), without changing its source or semantic oracle. The next replay reuses those unchanged production-source E2E results and selects only the 85 affected cases. No new finding is counted for the fixture.

## AHK-056: Sorting the native personal-entry list targets a different stored entry

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

The native personal editor permits automatic header sorting but its form, Save and Delete handlers use the visible row number directly as the TOML entry-array index. Header ordering therefore separates displayed identity from the record mutated. This differs from AHK-031’s initial active-model insertion ordering.

Reproduction: Native run41919871873 at2298478 uses the real native constructor, header click, selection and original Save/Delete buttons. Both cases report displayed alpha/form zeta/header_clicks1. Save changes the other stored entry while alpha remains unchanged; Delete leaves alpha present after a different entry was removed. The same failures repeat in reverse.

Consequence: Editing or deleting the selected visible row can mutate another persistent personal expansion. The form and confirmation may also describe the wrong record, rather than the row the user selected.

Regression: Two personal-native-sort-owner probes use the production public native fallback, a real header HWND click, actual selection and BM_CLICK on the original buttons. Independent durable TOML checks follow the displayed trigger identity and inspect the result before the form assertion. No copied ListView style or fake writer is used. Adding NoSort retains TOML row order; the native editor does not advertise a separate sorting feature. Native fail-before measured; post-fix qualification pending.

The ongoing register now contains **56 distinct new findings**. The requested target of 1,000 remains unmet.

## Native partial qualification checkpoint: 41919871873

At `2298478`, discovery succeeded and all **85 cases executed: 76 passed and nine failed**, identically in individual and reversed runs. The nine rollover recovery cases plus nine adjacent metadata/EOF cases qualify AHK-052; all three native sticky cases qualify AHK-053; all35 wrap loader/transaction cases qualify AHK-055. All five genuine layer-ready/source cases and ten host cases pass, but two old layer-save fixtures lack the newly required public page receipt and never reach their logger cutpoint; those fixtures remain to adapt and replay. The already-paused layer-save control passes. Native sort failures establish AHK-056. Both default-section cases fail an incorrect fixture control-type lookup (DropDownList instead of DDL), so that hypothesis remains unconfirmed. The two incomplete-journal drains need their bounded lifecycle escape; the advancing empty-batch control passes. Raw gesture logs separately establish acquisition and Max termination followed by the final held-debt failure; they are not an acquisition failure despite the last generic observation label. Production compile passed; E2E was outside this replay and the unchanged production-source90/90 hotstring evidence remains the previous checkpoint.

## AHK-057: The click-release watcher stops after three characters while Button Up is still owed

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

GestureStartKeyboardWatcher constructs InputHook("V L3") and describes L3 as an input level. L is a collected-text length limit, so three characters terminate the only shared keyboard observer even when a refused mouse release still needs later retries.

Reproduction: Raw native evidence from run41919871873 at2298478 proves Down accepted, two genuine keyboard callbacks with refused Up, then Input=abc/EndReason=Max/InProgress=false on the third character. Sending d returns under the owned Edit target guard, but no further Up is attempted and the final held-debt assertion fails, individually and reversed. The one-character retry control passes. The generic last-observation phase label was initially misread as an acquisition failure; the actual failing assertion is subject.ahk:554 after the next-key observation.

Consequence: A synthetic held mouse button can remain held after later keyboard input because its recovery observer has already ended. Retaining typed text is unnecessary for a key-down observer.

Regression: Three gesture-keywatcher-length cases use the actual native hook and callbacks, keyboard injection confined to an explicitly opted-in verified child-owned Edit, and passive mouse I/O. One, three and eight refused-key sequences must retain the same observer, recover at the next allowed Up and pass the complete typed text through. The fix uses V L0 and KeyOpt All NI, preserving MinSendLevel0, notifications and visible input while ignoring text collection. Old pins are adapted; final held-state and cleanup oracles remain strict. Native three-character fail-before measured; long/text-retention coverage and post-fix qualification pending. No physical mouse injection or physical-key claim is made.

The ongoing register now contains **57 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-058: Day rollover never yields when the journal ends in an incomplete record

Severity: high. Confidence: high. Evidence: source-derived; native Windows execution pending.

KL_DayRollover repeats every successful non-EOF ingest without checking committed byte progress. The reader deliberately preserves an unterminated record, so each iteration revisits the same offset and cannot complete the rollover or yield to the resident writer.

Reproduction: Native Windows run41919871873 at2298478 executes torn-drain and undelimited-drain through the real journal reader and rollover owner. Both require the bounded one-second rescue timer to revoke initialization; the committed offset stays108. The blank-batch-drain control advances over5001 empty lines and succeeds.

Consequence: A final partial journal record can trap day rollover in a tight loop. The journal must remain intact until its final delimiter arrives.

Regression: The three new rollover-state-recovery cases exercise actual files, reader, SQLite ledger and owner. Torn and complete-but-undelimited final records must return journal_no_progress promptly, retain the exact source and pending events, then succeed after the real delimiter is appended. Empty batches with real offset progress remain accepted. Guard added after successful non-EOF ingest; native post-fix qualification pending.

The ongoing register now contains **58 distinct new findings**. The requested target of 1,000 remains unmet.

## AHK-059: Legacy terminator migration reuses occupied record and state keys

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

HotstringsTerminatorMoveLegacy assigns custom\_<codepoint> without reserving the admitted raw record and state namespace. An existing record or future false state can shadow a newly migrated character. The ordinary UI already owns a collision-free allocator.

Reproduction: Native run41924556519 at9a8ebad: both existing-record and future-false-state cases acknowledge migration but the actual engine omits the legacy character; fresh allocation and existing-character controls pass, individually and reversed.

Consequence: An acknowledged delimiter migration silently changes matching behavior and may disable a newly imported terminator.

Regression: Four terminator-move key allocation cases exercise real source admission, ConfigCommitUpdates and runtime projection, including second-boot idempotence. The fix reserves the raw namespace and uses \_HotstringsTerminatorFreshKey; native post-fix execution pending.

## AHK-060: Terminator string membership merges case-distinct Unicode characters

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

Windows terminator consumers use the default case-insensitive InStr and StrReplace despite exact scalar record identity. This affects matcher, consumption, framing, boundaries, preview and legacy migration. Lua sibling membership is exact.

Reproduction: Native run41924556519 reproduces seven lowercase engine/preview failures with uppercase controls passing, plus both exact-consumption migration failures with both/neither controls passing. Four Unicode-boundary/magic-membership probes stop on a missing headless validation helper and do not qualify those paths.

Consequence: Typing an unconfigured case-distinct character can trigger an expansion, consume user text, invent a boundary, alter retained framing or reset preview incorrectly.

Regression: Twenty-two probes cover genuine engine and public migration consumers. All identified character-set comparisons now request case sensitivity. Four fixture prerequisite repairs and complete post-fix native qualification pending; no per-call-site count.

## AHK-061: A deleted default personal section hides the entries of the displayed section

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

OpenPersonalEditor trusts a saved nonempty default_section even when no section has that identity. The native dropdown displays its first live item while the model and list still address the absent section.

Reproduction: Native run41924556519 case29 reports pointer=deleted_section, dropdown=Alpha, source_entries=2, visible_entries=0. The live-default control passes; reverse replay agrees.

Consequence: An apparently selected personal section can look empty and invite unnecessary recreation of existing entries.

Regression: Two personal-native-default-owner cases use the actual constructor and DDL control, require unchanged opening files/preferences, and compare the live list with real source entries. The fix chooses an existing section before projecting both controls; post-fix pending.

## AHK-062: An old personal section switch destroys a successor opened during native retirement

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

\_SwitchEditorSection destroys its retired window and then unconditionally calls OpenPersonalEditor. Native WM_DESTROY callbacks can legitimately publish a newer session before that old call resumes.

Reproduction: Native run41924556519 case32 observes destroys=1, newer_seen=1, newer_alive_after=0, final_section=beta, newer_is_current=0. The ordinary switch control passes; reverse replay agrees.

Consequence: The older user operation closes and replaces a newer personal editor session.

Regression: Two personal-native-switch-owner cases reenter the public constructor from exact owned-window WM_DESTROY. The fix checks the retired session epoch and successor slot after Destroy, and removes the redundant stale model read. Post-fix pending.

## AHK-063: A stale personal editor constructor publishes a dead priority control

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

OpenPersonalEditor assigns \_PersonalEditorPrioCtrl during construction before its final session-epoch check. A successor created through native control notifications owns a live priority edit, but the older constructor overwrites the global and then destroys that obsolete control.

Reproduction: Native run41924556519 case34 proves parent_create=1, newer_seen=1, native_priority_alive=1, global_priority_matches=0 and priority_error=Error. The no-reentry control passes; reverse replay agrees.

Consequence: The current visible editor retains a dangling priority-control reference and cannot reliably save its entry.

Regression: Two personal-native-constructor-owner cases observe real WM_PARENTNOTIFY creation, exact HWND ownership and a subsequent genuine save. The priority control remains private until atomically published with the admitted GUI/source at the final epoch check. Post-fix pending.

## AHK-064: A rebuild guard admission failure waits forever for a nonexistent peer

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

FSOpenExclusiveGuard returns the same zero for genuine sharing contention and all other native opening or file-type failures. \_KLR_RebuildAcquire interprets every zero as peer ownership and loops without a build deadline.

Reproduction: Native run41925176895 at81d5aae: a real directory at rebuild.lock requires the one-second rescue timer to remove the obstruction before acquisition returns; the real peer-handle release control passes, individually and reversed.

Consequence: A wrong-type or inaccessible lock path leaves the statistics rebuild waiting indefinitely rather than reporting an admission failure.

Regression: Two klr-rebuild-guard-admission cases retain actual CreateFile/CloseHandle behavior and bounded rescue, plus an added caller case verifying the prior published SQLite image and exact ledger remain intact. The adapter now reports Contended only for sharing/lock violations; other failures return promptly. Post-fix pending.

## AHK-065: Capacity eviction invokes the failure callback of an already cancelled request

Severity: high. Confidence: high. Evidence: native Windows fail-before; source correction integrated; native post-fix pending.

\_LLMRemote_TrimAsyncRegistry detaches and cleans up the oldest request but calls its on_fail callback without honoring the cancelled flag. CancelAsync deliberately marks logical cancellation before deferred cleanup.

Reproduction: Native run41925176895 at81d5aae: actual RawPost, CancelAsync and successor admission at capacity1 yield predecessor_callbacks=1 instead of0. Both real facade handles retire, both controlled native jobs spawn, and the successor completes. The live-eviction control delivers its one trimmed failure as expected; reverse agrees.

Consequence: An explicitly cancelled request can later publish a stale error through a callback whose owner already revoked delivery.

Regression: Two remote-trim-cancel cases use the public request/cancellation pipeline and actual managed facade with controlled Job I/O. The fix suppresses only the cancelled predecessor callback while retaining cleanup and live eviction notification; post-fix pending.

## Native qualification at 9a8ebad

Run41924556519 discovered and executed92 selected cases individually and reversed:64 passed,28 failed in each order. AHK-056 native sort, AHK-057 watcher length and owner controls, AHK-058 rollover recovery and progress, and repaired AHK-054 save admission pass. Full production compile and90/90 native hotstring E2E pass; HTTP E2E was not selected. Four delimiter probes fail on a missing headless validation prerequisite and do not establish their intended invariant. AppPicker refusal reproduces a presentation-after-failed-durability variant of AHK-025; no extra finding count. Crash receipt controls require correction before attributing a Unicode-only defect.

Run41925176895 at81d5aae executes17 new probes in both orders:6 pass and11 fail, including real override data loss, cancelled callback revival and false peer contention. The override correction is being completed with legacy preservation before integration.

The register contains65 distinct findings; the requested1,000 target remains unmet.

## AHK-066: Remote usage casts and inferred totals overflow the signed native integer domain

Severity: high. Confidence: high. Evidence: native Windows fail-before; source fix integrated; native post-fix pending.

\_LLMRemoteExtractUsageRoot treats every nonnegative finite Number as safely castable to signed64 Integer and adds two valid counters without a representation check. JSON validity alone does not establish the native consumer domain.

Reproduction: Native run41924556519 at9a8ebad: the real classifier and managed Poll both accept a finite1e30 usage count as MININT, publish a negative inferred total and negative estimated cost. Individually valid MAXINT prompt plus1 completion also wraps the inferred total to MININT. Both normal controls pass, and actual callbacks and exact handle/registry retirement still complete in all modes.

Consequence: A successful response can publish negative usage totals and estimated costs even though its provider supplied nonnegative values.

Regression: Six genuine classifier/managed-completion probes plus an eight-row boundary test preserve valid response text, exact callback count and retirement. The fix admits only representable counts and infers a total only when subtraction proves the addition safe; otherwise total remains unknown0. No product token cap is introduced. Native post-fix pending.

## AHK-067: Sticky replay drops modifier flags released before the captured key is replayed

Severity: high. Confidence: high. Evidence: native Windows fail-before; source fix integrated; native post-fix pending.

StickyModifier sends Hook.EndKey with only the selected sticky modifiers and discards Hook.EndMods. A native captured modifier may already be released when Wait unwinds, so current key state or Blind cannot restore the captured shortcut.

Reproduction: Native run41924556519 at9a8ebad: sticky-native-modifier-flags plain passes, shift fails after native capture reports EndMods=<+, Shift is released, and replay reaches the receiving F6 handler with Ctrl1/Shift0. Actual synthetic transaction is Critical, finalization is not Critical, and both canonical buffers remain unchanged. Same inverse result; input injection is confined to a verified owned Edit, not a claim about physical keys.

Consequence: For example sticky Ctrl followed by Shift+F6 becomes Ctrl+F6, changing the requested application action.

Regression: The two real-hook/native-receiver probes include the production HS_RunSyntheticInputTransaction and TextPressKey pipeline. The fix unions captured Ctrl/Alt/Shift/Win groups with the sticky modifier without duplicates; it does not claim preservation of left/right modifier identity. Post-fix qualification pending.

The ongoing register now contains67 distinct findings. The requested1,000 target remains unmet.

## AHK-068: Full-state override saves erase valid TOML settings omitted by the regex projection

Severity: high. Confidence: high. Evidence: native Windows fail-before, source correction integrated, post-fix pending.

\_ParseOverrides and \_ParseGlobalKey use partial regex scanners rather than the canonical typed TOML model. The full-state serializer then assumes that its projected Map represents the complete admitted source. Recognized but unadopted LegacyDelay and reserved migration strings expose the same read-to-write loss boundary.

Reproduction: Native run41925176895 at81d5aae: five canonical syntax cases lose existing category and section leaves after genuine HotstringsConfigReload and unrelated public saves. Literal/quoted-key colors, signed/exponential offsets and separated integer priorities fail; three ordinary lexical controls pass. Four source-preservation cases also acknowledge erasure of unknown/deeper/array/wrong-type source data; the supported extension control passes. Same reverse results.

Consequence: An unrelated acknowledged settings edit can permanently erase an existing delay, color, priority or future source field. Legacy delimiter intent can also be retired without proving transfer of the exact source values.

Regression: Thirteen native file/public-save probes establish fail-before and controls. The fix projects canonical typed leaves, refuses source shapes the serializer cannot preserve, and requires an exact durable migration receipt before retiring nonempty legacy delimiter strings. Additional tests cover four canonical legacy spellings, eight legacy-delay states, four retirement receipts and a functional real-decoder owner check. Raw LegacyDelay survives pre-boot saves; ordinary runtime adoption preserves finite delay intent, while pending \_global default migration refuses runtime reload. Native post-fix qualification pending. These related projection/preservation variants are one finding, not one count per syntax or field.

The ongoing register contains68 distinct findings. The requested1,000 target remains unmet.

## AHK-069: An accepted supplementary character key emits no native input

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

\_SendInputAhkKey forwards a literal surrogate pair to TextPressKey, which braces it as an AutoHotkey key name. A braced unknown two-unit name is ignored; supplementary Unicode requires the explicit U+codepoint syntax.

Reproduction: Native run41926489533 at69c71ef: actual SendInputParse/Emit and TextPressKey accept the shared corpus emoji, execute the real Critical synthetic transaction and default prefix finalizer, but the receiving owned Edit obtains0 UTF-16 units instead of2. ASCII and BMP controls pass; reverse repeats the astral failure.

Consequence: The action reports accepted input and commits its synthetic context while the requested character never reaches the application.

Regression: Three owned native receiver cases test ASCII, BMP and astral output through the actual transaction. The adapter now converts only well-formed supplementary pairs to U+codepoint; named/BMP/braces remain unchanged. Four extra action assertions cover U+10000, U+1F44B, U+10FFFF and a modified supplementary key. Native post-fix pending.

## AHK-070: Crash worker output corrupts acknowledged Unicode report paths

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

PowerShell5.1 Write-Output encodes its console receipt using an OEM code page, while the parent native runner reads the staged bytes as ANSI CP0 without a byte-order mark. Native Unicode paths therefore cross incompatible codecs.

Reproduction: Native run41926489533 at69c71ef: after correcting the independent8.3 input alias fixture, ASCII passes exact_path1 with a physical artifact. Primary and fallback workers both create the Unicode artifact but their returned path does not exist; expected UTF-16 unit233 is decoded as8218 under CP0. Same reverse failures. Initial run41924556519 had an additional fixture alias mismatch and did not alone establish the codec defect.

Consequence: A report can be written successfully while its acknowledged filename is unusable, preventing the driver from locating or opening that report.

Regression: Three genuine worker/mapping/file controls independently locate and inspect the physical report before comparing the raw acknowledged path. Both writers now emit explicit UTF-8 bytes with BOM on stdout; FileRead autodetects the encoding without changing ShellRunner or OK:path semantics. Native post-fix pending.

## AHK-071: Failed screenshot cleanup adopts and deletes a stage created by another owner

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The stage path is derived from process ID and epoch without acquiring file ownership. WorkerDone calls \_GestureScreenshotCaptureStage even after pre-write failure; that routine creates its cleanup authority by observing whatever file is now present at the path.

Reproduction: Native run41927538467 at09e8ea2: the public GestureCaptureRegion owner and genuine deferred worker receive a pixel-I/O refusal before any write. A pre-existing file acquired independently by CREATE_NEW at the deterministic stage path disappears; terminal count1 and jobs0 prove cleanup completed. The no-stage control passes. No screen pixels or clipboard content are captured.

Consequence: A failed capture may delete an unowned existing temporary file, including an artifact left by an earlier process with a recycled ID.

Regression: Two public-owner/native filesystem cases prove pre-write failure must preserve the exact independently created stage identity and bytes. A synthetic one-pixel GDI compatibility probe separately refutes the proposed zero-access metadata lease: DeleteFile succeeds, so that proposal cannot be used as a fix. Native run41930158432 qualifies the actual read lease with real GDI encoding. The production correction now acquires CREATE_NEW before capture and retains its owned handle through cleanup; post-fix qualification is pending.

## Native qualification at 69c71ef and 09e8ea2

Run41926489533 executes75 cases:64 pass,10 assertions fail and one constructor-successor case times out without a terminal receipt. The inverse completes65 passes and the same10 assertions. The constructor has the corrected priority identity before the timeout, and passes in reverse; its independent timeout diagnosis remains open. All26 terminator identity/migration cases, personal sort/default/switch, counter-domain controls, cancelled eviction, real rebuild guard and sticky flags pass. Integer-price arithmetic and supplementary key/Unicode report-path defects are retained for correction. Six legacy source tests fail on this earlier snapshot before AHK-068.

Run41927538467 at09e8ea2 executes58 cases in each order:55 pass and3 fail. All selected AHK-068 business cases pass; one empty-file fixture fails before the reader and is corrected separately. Screenshot pre-write failure deletes an independently owned file; its no-stage control passes. The proposed zero-access metadata lease is experimentally rejected because it does not block native deletion. All4 bounded PCRE cases pass; no Windows PCRE resource defect is established at the measured sizes. Both runs compile the complete production entry and pass90/90 native hotstring E2E; HTTP E2E is not selected.

The register now contains84 distinct findings. AHK-071, AHK-072 and AHK-073 have integrated corrections awaiting native post-fix qualification. AHK-074 has an integrated original-event correction awaiting native post-fix qualification. The requested1,000 target remains unmet.

## AHK-072: Override saves overwrite a source changed after the loaded snapshot

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The full-state override writer serializes its cached Map without proving that the current exact source bytes still belong to that same loaded Map. A path or cloned Map alone is not source authority.

Reproduction: Native run41930158432 at5d857ae: four external-source changes and one staging-time change are silently overwritten by public override saves; three unchanged-source controls pass. The inverse repeats the same five failures.

Consequence: An acknowledged setting edit erases edits made by another writer after loading, including changes during save preparation.

Regression: Integrated receipts bind exact UTF-8 source state, canonical path and actual Map identity. Save admission checks the captured receipt again after staging; successful readback publishes a new receipt with RAM. Eight original native probes, two final-gate cases and two direct-owner cases cover refusal and controls. Existing actual-writer fixtures are adapted; post-fix qualification pending.

## AHK-073: Anthropic requests transmit temperatures outside the provider domain

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The generic0..2 option range reaches the Anthropic-specific serializer unchanged although this provider accepts only0..1.

Reproduction: Native run41930158432 at5d857ae: actual Anthropic request building emits1.02 and2.0 from accepted settings; the0.9 control passes. Official versioned Anthropic SDK documents temperature0.0..1.0 for the configured model family. No upstream HTTP request was made.

Consequence: A supported UI configuration constructs a request outside the provider temperature contract.

Regression: The Anthropic builder now clamps to its documented0..1 domain, leaving other providers unchanged. Three actual request-building cases await post-fix qualification. Versioned SDK URLs, content hashes and normative excerpts are retained in anthropic-sampling-contract.json.

## AHK-074: Deferred layout-row replay loses a captured Shift modifier

Severity: high. Confidence: high. Evidence: native Windows fail-before.

\_LayoutRowPassthrough replays only the scan code with Blind and discards the selected modifier identity. Current key state no longer describes the original event after deferred dispatch.

Reproduction: Native run41930158432 at5d857ae: the +SC010 variant is selected, Shift is released before dispatch, and callback/receiver both observeShift0. Plain and still-held modifier controls pass; inverse repeats the failure.

Consequence: A captured modified key can reach the application as an unmodified key and invoke a different action.

Regression: Native run41939048652 at46019fb confirms the same released-Shift failure across distinct process/input queues; plain and held controls pass individually and reversed, and all callback queue/logical/async Shift flags are0. The integrated correction keeps the same240/five-prefix identities and exact I2/I3 levels but uses tilde to admit the original event without synthetic replay. Chosen plain magic remains protected after marker normalization. Local/external probes retain exact modifier/key-count oracles and now require original event provenance, one real I1 keydown/host character and exact Edit text. Priority and emulated-output controls remain strict. Post-fix native qualification pending.

## Native qualification at 5d857ae

Run41930158432 executes60 cases in each order:48 pass and12 assertions fail, with no timeout and complete production compilation. AHK-025 durable outcomes, AHK-063 constructor ownership, AHK-069 supplementary keys, AHK-070 crash Unicode and the AHK-066 integer-price case pass. The real read lease passes all3 GDI compatibility cases. Five stale-source failures establish AHK-072; two Anthropic contract failures establish AHK-073; one deferred layout failure establishes AHK-074. Two finite-cost failures and two request-budget failures extend existing numeric and deadline findings rather than adding duplicate counts. Both optional E2E groups were explicitly not selected.

Native run41930158432 proves that a GENERIC_READ lease with read/write sharing permits actual GDI encoding while retaining stage identity and preventing deletion. The integrated fix acquires CREATE_NEW before capture, retains the native handle and snapshot through publication/cleanup, refuses unowned stages, preserves close-failure debt and releases unstarted job cycles. Existing cleanup fixtures now carry actual ownership receipts. Three real one-pixel composition tests and two unstarted lifetime witnesses are added; post-fix Windows qualification pending.

## AHK-075: Legacy default migration retires its source after the destination refuses the write

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The cross-file migration updates session RAM after WriteFeatureV2 refusal but continues to persist the projected override state, deleting \_global despite lacking a destination durability acknowledgment.

Reproduction: Native run41938680258 at a7fa655: real base-config lease refusal and writer-refusal cases still rewrite the override file without its legacy global delay. A subsequent unrelated color save also loses that only durable default. Three failures repeat in reverse; successful migration and no-default controls pass.

Consequence: Restart restores the old base while the only durable record of the intended default has been erased.

Regression: Five real cross-file migration probes include actual lease refusal, subsequent public color save, a refusal seam and two positive controls. Integrated correction keeps the legacy record and original source receipt in the session projection, returns refusal before rewriting the source and publishes fallback only to the still-current owners. Post-fix qualification pending.

## AHK-076: Numeric UI prompts wrap decimal text before validating its intended magnitude

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

Text+0 and Integer(Raw) apply native signed64 modulo conversion before the setting domain is checked. Lexical integer validity does not prove representability.

Reproduction: Native run41938680258: the actual idle-reset parser turns decimal18446744073709551616 into disabled0. The LLM prediction-count prompt accepts18446744073709551619 as3 without a validation notice. Ordinary and wider finite-float idle controls pass.

Consequence: A value outside the intended setting domain is accepted as a different small value, including a disabled timer.

Regression: Three idle decimal-domain probes and one actual LLM normalizer probe retain the original lexical inputs. Idle parsing now uses checked decimal parsing and finite Float fallback without forcing wide values back to Integer. The LLM sibling correction must preserve its already accepted plus/hex/whitespace forms while refusing overflow; qualification pending.

## AHK-077: Token refresh-margin validation overflows while doubling an admitted integer

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

Margin\*2 wraps signed64 before comparison to the bounded default lifetime, turning a huge positive margin into a small or negative value.

Reproduction: Native run41938680258: parsed margins2^62 and MAXINT pass the below-half-lifetime check and produce refresh due one second after token issue. Four ordinary/even/odd boundary controls behave correctly; reverse repeats the two invalid admissions.

Consequence: An invalid authentication configuration is accepted and newly issued usable tokens are immediately treated as requiring refresh.

Regression: One six-row real parser/reader/state test observes both admission and refresh behavior. The fix compares Margin >= Default/2 after the default lifetime has already been validated in its intrinsic bounded domain. Post-fix qualification pending.

## Native qualification at a7fa655

Run41938680258 executes165 cases in each order:149 pass and the same16 fail. Complete production compilation and90/90 native hotstring E2E pass. Screenshot ownership29/29, external/staged source ownership8/8, Anthropic3/3, token request budgets8/8, finite cost3/3 and picker11/11 pass. Three source migration failures establish AHK-075; two numeric UI failures establish one shared AHK-076 family; the margin test establishes AHK-077. DayLog and Ollama Unicode extend existing033/070 families. The released layout case remains fail-before for the subsequently integrated074 correction. Two old source guards need the actual new atomic owner; three profile probes stop at an undefined A_Pid fixture variable, now corrected to ProcessExist(). One reload fixture tries to acquire its second private scope before retiring the first; its first business assertions pass, but the full case remains unqualified until the scope transition is repaired. The requested1,000 target remains unmet.

## AHK-078: Accepted CapsWord inactivity durations compile into disabled native policies

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The shared policy multiplies seconds by integer1000 then rounds without establishing representability in the native timer domain. Windows publishes that policy without platform admission.

Reproduction: Native run41940017179 at0888bda: public config reading accepts2^62 integer seconds and1e308 float seconds. Real compilation publishes idle_ms0 and MININT respectively, arms a character subscription but no inactivity timer. The ordinary0.05s control actually delivers its native timer once; inverse repeats both failures.

Consequence: An accepted positive inactivity setting silently disables the requested automatic CapsWord shutdown.

Regression: Three public config/compile/arm cases inspect genuine HookDispatcher subscriptions and native timer ownership. Correction must explicitly admit the intrinsic native timer domain or use the existing documented fallback before policy publication and durable stores; implementation pending.

## AHK-079: A valid base-delay change pushes existing hotstring offsets outside the engine duration domain

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

HotstringsDelayFromOffset enforces only a lower duration boundary, while HotstringsSetBaseDelay validates only the base rather than the resulting effective projections.

Reproduction: Native run41940017179: real public setters produce category and section offset+0.25, then acknowledge a valid base at the DWORD elapsed-clock ceiling. Both effective durations exceed that ceiling and the actual engine time gate expires them even at the current character timestamp. Below-cap, zero-offset and unlimited controls pass.

Consequence: An acknowledged valid base setting disables existing time-gated hotstrings with positive relative offsets.

Regression: Four real public-write/time-gate cases preserve exact stored source and prove that returning the base restores original relative intent. The integrated projection clamps at the existing canonical TICK_MAX_DURATION_MS ceiling without mutating StoredOffset. Post-fix qualification pending.

## AHK-080: Explorer navigation redirects new-file rename preparation to an unrelated file

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

GestureSysNewTextFileHere captures the creation folder, then reacquires Window.Document after filesystem I/O/logging and resolves only the base filename without checking the resulting folder or item path.

Reproduction: Native run41940017179: the genuine SystemControl CreateNewFile creates an empty file in original folderA. A controlled Explorer document navigation during that external call exposes a same-named pre-existing file in folderB; the public action selectsB with rename flags. The unchanged-document control selects the createdA file. Both real files and exact selected paths are independently checked; no real Explorer window is automated.

Consequence: The action can start renaming a same-named unrelated file after the user navigates while the new file is being created.

Regression: Two native filesystem cases use explicit Shell/Document ports and the actual creation adapter. The integrated guard retains the folder object, checks its exact path against the captured folder and requires the returned item path to equal the created path before SelectItem. Post-fix qualification pending.

## AHK-081: Gesture configuration publishes cached RAM candidates outside its configuration lease

Severity: high. Confidence: high. Evidence: native Windows fail-before.

GestureSetActionParameter and \_GestureCommitAssignment clone mutable state before ConfigCommitUpdates acquires its owner and publish the prebuilt Maps after that owner is released.

Reproduction: Native run41940017179 parameter and assignment probes delegate the genuine clone, admit a second real MenuCommandRun mutation before the first acquires its lease, and execute both actual writers. TOML contains both acknowledged updates but the first cached Map replaces RAM with the second field still old. Diagnostics disk_b_new1/ram_b_new0 repeat in reverse.

Consequence: A successfully persisted independent menu change disappears from live behavior until restart, and later actions can operate on stale assignment state.

Regression: Two real native-writer/dispatcher cases assert exact durable/live agreement and one second invocation. A CapsWord sibling probe stops before its first writer acknowledgment and is not counted as evidence. Correction is being prepared using ConfigCommitBuilt with lease-owned candidate construction and memory publication; implementation pending.

## Native qualification at 0888bda

Run41940017179 executes68 cases in each order:58 pass and the same10 fail. Complete production compilation passes; optional E2E groups are not selected. All3 external modifier cases pass, including released Shift. Three local children satisfy their strict character/key/provenance assertions and emit PASS, but the parent incorrectly rejects the preceding observation line; its receipt check is repaired to require both exact lines. The other failures establish AHK-078 through081: two CapsWord numeric cases, one effective duration case, one wrong Explorer rename target and two cached gesture publication cases. The CapsWord cached-publication sibling stops before its first writer acknowledges, so no business conclusion is drawn for it. The target of1,000 remains unmet.

## AHK-082: Boot readers bypass the admitted typed configuration and reinterpret outdated values

Severity: high. Confidence: high. Evidence: native Windows fail-before.

KeyCombinationChordsReadConfig reads the compatibility cache and coerces its leaves instead of consuming the associated admitted typed source. Compatibility cache integers cannot retain the Boolean-versus-number distinction.

Reproduction: Native run41943680113 at231d481: quoted false and numeric2 activate chord symmetry; quoted500 and Boolean true replace the canonical100ms timing with500ms or1ms. The actual source snapshot already supplies the correct defaults. Four malformed-source failures repeat in reverse; three valid controls pass.

Consequence: Outdated configuration can route a chord to its reverse action or unexpectedly shorten/extend its recognition window despite the canonical loader rejecting that value.

Regression: Seven actual parse/snapshot/policy cases establish fail-before and controls. The integrated reader takes delay, symmetry and enabled from one admitted snapshot. Related LoneTap/CapsWord readers now consume their associated canonical leaves while detached Map contracts remain intact. Thirteen additive sibling/enabled cases await qualification; no separate defect is counted per leaf or consumer.

## AHK-083: The native profile prompt truncates pasted multiline instructions to one line

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The system prompt fallback uses InputBox, whose native Edit is single-line even when the dialog height is increased.

Reproduction: Native run41943680113: genuine WM_PASTE of a two-line Unicode clipboard into the actual profile fallback produces multiline_style0, one control/returned/durable line and a successful save containing only the first line. Single-line save and second-prompt cancellation controls pass in both orders.

Consequence: An acknowledged profile edit permanently loses all pasted instruction lines after the first.

Regression: Three real dialog/WM_PASTE/durable codec cases retain the exact multiline text and cancellation behavior. The integrated native fallback uses a real multiline Edit with WantReturn and no text limit, explicit OK/Cancel/Timeout receipts and owned timer/window teardown. Existing input ports remain compatible. Native automation targets the actual replacement control and buttons; post-fix qualification pending.

## AHK-084: Window-title rollups attribute destination captions to the outgoing application

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

KLR_RebuildTitleCounts groups next_title under the outgoing app from events_window_switch. It also counts focus visits although the shared applications table labels c as manual keystrokes.

Reproduction: Native run41943680113 cross-app SQLite/rebuild/manifest probe observes appA/TitleB and appB/TitleA counters; the same-app round trip control passes. Source events deliberately follow the genuine outgoing-app producer contract, and independent walker durations remain2500/3500ms.

Consequence: The applications dashboard shows another application's caption, omits the correctly timed title when c is0, and presents visit counts as character activity.

Regression: The integrated reader sums its existing accepted typing projection by actual typing app/title, excluding synthetic output and retaining physical backspaces; the walker continues to own ms. Tests add exact3/4 typing counts independent of committed text length while preserving app ownership and2500/3500ms assertions. Native title-cap/refusal and obsolete cache18 controls are retained; cache19/checkpoint5 force reconstruction before new admission. Post-fix qualification pending.

## Native qualification at 231d481

Run41943680113 executes94 cases after the earlier strict discovery mismatch was corrected from21 to24 CapsWord matches. Each order has81 successes and13 failures. All selected075–081 primitive fixes pass, including8 default-migration,4 effective-duration,6 CapsWord-domain,24 auto-off,4 LLM integer,3 idle decimal,1 token-margin,2 Explorer and both gesture publication probes. The repaired CapsWord concurrent-publication sibling fails and is corrected separately. Profiles establish083 and an extension of072; malformed chord settings establish082; cross-app title attribution establishes084. The scalar failures stop at canonical key spelling or hook readiness; they do not yet prove native leakage and are being repaired without a subject change. Both actual native DLL editor cases reach their text/caret/timeout/retirement assertions successfully but reject a fixture warning in the exact completion receipt; local/global variable names are repaired before qualification. The full production graph compiles; optional E2E groups are not selected. The target of1,000 distinct defects remains unmet.

## Native qualification at f6245d0

Run41947380519 admits98 selected cases. Both orders return73 successes and the same25 failures; the production graph compiles. All24 profile cases, title attribution/cap/cache controls and both shipped native-editor cases pass. The scalar Backspace probes now reach their receiver assertions and prove original-key leakage in one-shot and dead-key paths, extending053. The run establishes085–088 below. It also exposes a genuine082 integration regression: a private enabled switch has no manifest default, and generic parser caches were incorrectly treated as boot-owned snapshots. Both are repaired before the next replay. Bare numeric0/1 are valid legacy Boolean spellings: two malformed fixtures are changed to signed zero and the numeric marker-one probe is retained as a valid migration control. Wrap probes stop at a missing parent setup global, so they establish no business defect yet. Optional E2E groups are not selected. No native success is inferred for the remaining fixes.

## AHK-085: Same-caption application switches retain the outgoing title clock

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

KL_Hook_RefreshContext in modules/keystats/keystats_hook.ahk: title interval retirement compares caption text alone, after app identity changes.

Reproduction: Switch between two public applications with the same window caption, then change the second caption.

Observation: Native run41947380519 observes only one window row and an unchanged title origin after the application switch; the distinct-caption control passes.

Regression: Actual context refresh and canonical append must emit both application-owned title intervals and advance their real clock even when captions match.

The production correction is integrated; post-fix native qualification is pending.

## AHK-086: Superseded parsers replace the active slot display metadata

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

\_LLM_Engine_ParseSlots in modules/llm/prediction_exec.ahk: RememberSlotDisplays runs after a yielding parser without rechecking request and semantic ownership.

Reproduction: Allow a parser refusal diagnostic to admit a new request, then resume the old parser and replay the new request from its exact cache.

Observation: Native run41947380519 records one parser refusal, one cache replay and no additional network call, but corrected text becomes continuation text in the active cached display.

Regression: Require current request identity after actual parser reentry and preserve the active correction projection on exact cache replay; retain stale-entry and pure parser controls.

The production correction is integrated; post-fix native qualification is pending.

## AHK-087: Refused layout publication strands its owned download stage

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

\_LayoutCatalogueWriteText in modules/keymap/keylayout/layout_catalogue.ahk creates a fixed .download stage but never retires that owned stage when replacement fails.

Reproduction: Hold the target against replacement, attempt composer or local catalogue publication, release the handle and retry.

Observation: Native run41947380519 repeats first_ok0, stage_left1 and retry_ok0 for composer, layout and record targets in both orders.

Regression: Three real filesystem refusal/retry cases require owned stage retirement and successful retry; twelve foreign-stage controls must preserve foreign bytes.

The production correction is integrated; post-fix native qualification is pending.

## AHK-088: Malformed updater cadence silently disables update checks

Severity: high. Confidence: high. Evidence: native Windows fail-before.

Updater_LoadCheckInterval in modules/updater/core.ahk reads the compatibility cache and coerces/truncates wrong source types before interval admission.

Reproduction: Boot from an actual typed TOML snapshot containing false, quoted zero or fractional0.5 as check_interval_seconds.

Observation: Native run41947380519 resolves all three malformed values to0 instead of the86400-second default, disabling checks; legitimate0 and3600 controls pass.

Regression: Five actual boot snapshot/loader cases preserve legitimate disabled and hourly settings while malformed source types fall to the canonical default; runtime guards cover strings, negative and huge values.

The production correction is integrated; post-fix native qualification is pending.

## Discovery refusal at 3189ef7

Run41950173319 stops before discovery with AutoHotkey exit2: a test assertion and its following else share line570 of test_key_combination_chord_engine.ahk. None of the86 selected subjects executes, so this run qualifies no behavioral fix. The production entry compiles and both optional E2E groups remain explicitly unselected. The fixture syntax is repaired before replay. The next selection adds uncounted source-ownership, final-publication, argument-representation, boot-admission, case-only caption, native-window-close and profile-navigation-source probes; they remain hypotheses until the actual production path reaches its business assertion.

Cross-driver inspection for086 finds no equivalent mutable global display store: Linux and macOS retain the parser display metadata in result records. No Lua correction is justified by the demonstrated Windows store race. Argument-representation probes separately retain the actual JSON-decoded input length before native dispatch; the Linux process adapter already rejects embedded NUL, while macOS shortcut input travels in a file rather than as a native argument. These comparisons establish scope, not unexecuted Windows success.

## Native qualification at b70dd87

Run41950852781 discovers and executes113 selected cases:92 pass and21 fail, with the same names in reverse. The production graph compiles; both optional E2E groups remain unselected. Scalar receiving6/6 now proves the053 suppression fix, including the formerly leaked Backspace. Typed chord boot12/12, marker legacy controls3/3, updater cadence5/5, request parse-gap2/2, refused layout retry3/3 with foreign-stage controls, configuration publication3/3 and same-caption cross-app2/2 pass. The genuine CapsWord store/candidate integration now passes with the registered boot-cache guard.

The run establishes089 below. It also extends existing families: a same-app caption changing only case retains its old title clock (085); profile editing overwrites a different navigation preference written before opening (072); wrap-symbol add/toggle overwrites externally changed source (072), and wrap publication still proceeds after native-boundary suspension or reinitialization (038). These extensions do not create new IDs. Two malformed real boot cases exit1 without exporting their child diagnostic and remain under investigation. Four spent-control and two clipboard-render probes stop at missing fixture arguments; two Wi-Fi probes lack their initialization prerequisite; both native Show probes inspect an unrelated vanished window. None of those ten fixture failures is counted as a product defect. Their setup is being repaired before the next targeted replay.

## AHK-089: Native shortcut arguments silently lose text after NUL

Severity: high. Confidence: high. Evidence: native Windows fail-before.

AL_QuoteArgument accepts embedded NUL although Windows native command lines terminate at that code unit. The genuine System2 JSON action decoder retains the full string, and the shortcut connector acknowledges native launch without detecting truncation.

Reproduction: Run41950852781 dispatches head, middle and tail NUL inputs with complete pre-dispatch lengths7/13/7. The actual independently identified child receives respectively0/6/6 units; connector_ok stays1. All three outcomes repeat in reverse. The legal12-unit Unicode/quoting control passes.

Regression: Four actual JSON/discovery/connector/native-launch cases preserve complete producer input before dispatch, verify child PID and creation FILETIME, inspect actual A_Args code units and join the owned receiver. The integrated guard uses length-aware NUL matching and refuses before native launch with an explicit unsupported-argument reason. Post-fix native qualification is pending. Linux already refuses NUL in its process argument adapter; macOS sends shortcut input through a file, so this Windows argument guard does not change its supported representation.

## Discovery refusal at da9fc06

Run41953170311 stops with AutoHotkey exit2 before discovery: the new gesture child-source builder still uses legacy doubled-quote escaping in three string constructions. None of the96 selected subjects executes. Those constructions are rewritten with valid v2 literals; the other new builders are inspected for the same mistake. Production compilation passes, optional E2E groups are not selected, and no behavioral result is attributed to this run. The next replay preserves the previously unexecuted cases and adds eight unqualified WPM, ROI-context and same-window selection probes. The register remains89 distinct confirmed findings.

## Native qualification at f51d742

Run41954012438 executes104 selected cases in each order:77 pass and27 fail, with identical failing names. The production entry compiles; optional E2E groups remain unselected. Native argument NUL guards4/4, launcher controls6/6, title ownership3/3 and all45 selected Wrap cases pass. This selection does not repeat the scalar, updater, typed-chord or layout-retry groups qualified at b70dd87.

The run establishes090–099 below. It also reproduces the existing082 typed-boot and081 WPM compensation families. Spent-control observers and native Changelog Show notification fixtures do not establish new product defects. Several clipboard positive cases reach correct receiver assertions but fail because the fixture mistakenly retains its cleanup owner; those cleanup calls are repaired without adopting a newer clipboard sequence. Post-fix native qualification of090–099 remains pending.

## AHK-090: Diagnostics acknowledge an empty buffered replacement

Severity: high. Confidence: high. Evidence: native Windows fail-before.

FSWriteUtf8ReplaceStrict uses buffered FileOpen writing without requiring the native write receipt before replacement.

Reproduction: Collect a real diagnostic replacement through a handle whose write rights are refused, then inspect the acknowledged target bytes.

Observation: Run41954012438 in both orders acknowledges Result1 with publishedBytes0; the genuine skipped-collection control passes.

Regression: Use the owned native replacement stage, require WriteFile and flush acknowledgement, preserve foreign stages, and assert refusal with Win32 error5.

The production correction is integrated; post-fix native qualification is pending.

## AHK-091: Mistral typed text content is discarded as an empty answer

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The canonical choices.message.content reader admits only String, although the provider contract also admits typed text arrays.

Reproduction: Feed official OpenAI-compatible Mistral content arrays containing typed text, with and without a preceding thinking chunk, through actual request completion.

Observation: Run41954012438 classifies both actual answers canonical_empty, invokes one empty callback and retires the real request; string and reasoning-only controls pass.

Regression: Concatenate ordered strictly typed text chunks; ignore reasoning and nontext chunks, refuse malformed text arrays, preserve no-decoy fallback and exactly-once request retirement.

The production correction is integrated; post-fix native qualification is pending.

## AHK-092: A second agent action deletes a calendar file before its handler reads it

Severity: high. Confidence: high. Evidence: native Windows fail-before.

LLM_AgentConnector_Execute deletes previous temporary files without any consumption acknowledgement from the asynchronous native handler.

Reproduction: Start an independently owned delayed calendar reader, execute a second real connector action, then release the first reader.

Observation: Run41954012438 observes existsbefore_release0 and MISSING in the joined real reader; the single-action reader control reads the complete calendar bytes.

Regression: Retain each calendar handoff in an exclusively created user-private directory; delayed-reader and independent native ACL, collision, UTF-8 and NUL controls cover publication.

The production correction is integrated; post-fix native qualification is pending.

## AHK-093: The Wi-Fi dashboard ignores actual network change events

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

KLR_RebuildAggregates counts legacy events_system wifi_change rows while the active producer writes events_network network_change.

Reproduction: Produce canonical baseline, network-switch and signal rows through the genuine Wi-Fi poll, ingest them into real SQLite and rebuild the manifest.

Observation: Run41954012438 retains three genuine network rows but exposes manifest wifi_changes0 instead of1; signal-only control passes.

Regression: Count known connectivity and SSID transitions from canonical metadata, preserve legacy events, exclude startup/signal/unknown observations, and invalidate obsolete cache/checkpoint versions.

The production correction is integrated; post-fix native qualification is pending.

## AHK-094: ROI joins word fragments across application contexts

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The in-progress ROI word has no canonical focus owner and survives context discontinuities.

Reproduction: Type abc in application A, switch context without a delimiter, type def and space in application B through actual context and ROI producers.

Observation: Run41954012438 reports compound_count5 and a compound candidate across applications, with zero hook errors; same-application continuity control passes.

Regression: Bind fragments to immutable app/title/HWND identity; discard on context, caret, privacy, synthetic and lifecycle gaps without promoting incomplete words; preserve same-context refresh continuity.

The production correction is integrated; post-fix native qualification is pending.

## AHK-095: Enter and Tab are each recorded twice by the real InputHook

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The key intent records the named control event and the following character intent records its control-code echo as another text unit.

Reproduction: Deliver one native Enter or Tab to an owned receiver while observing the actual installed InputHook key and character callbacks.

Observation: Run41954012438 observes one receiver keydown, one hook keydown and one LF or TAB callback, but two canonical events and text units in both orders; letter and Backspace controls pass.

Regression: Associate an echo with its exact hook, lifecycle, generation and successfully recorded predecessor; preserve genuine OnChar-only Unicode packets and unrelated-key release behavior.

The production correction is integrated; post-fix native qualification is pending.

## AHK-096: Storage clearing acknowledges denied native enumeration as an empty store

Severity: high. Confidence: high. Evidence: native Windows fail-before.

Reg_EnumValues collapses registry enumeration refusal into an empty array, which ST_Clear treats as complete discovery.

Reproduction: Create a private registry subtree, deny value-query permission with a reversible native DACL, and call the real storage clear path.

Observation: Run41954012438 measures native query5 and enum5 while ST_Clear returns1; accessible and genuinely empty controls pass and the exact original ACL is restored.

Regression: Use an explicit complete-enumeration receipt, publish no partial names on error, distinguish absent keys from denied access, and grow buffers for legal long names.

The production correction is integrated; post-fix native qualification is pending.

## AHK-097: SendInstant pastes a foreign copy made after its clipboard receipt

Severity: high. Confidence: high. Evidence: native Windows fail-before.

SendInstant does not revalidate the original owned sequence at the final native paste boundary.

Reproduction: Let an independent clipboard writer replace the published payload after its authentic sequence receipt and before the actual paste.

Observation: Run41954012438 independently verifies payload sequence23/40 changes to28/45 and the actual Edit receives foreign text while ok remains1; inverse repeats the defect.

Regression: Reject a changed sequence immediately before paste, retain the original cleanup ownership, and test actual receiver bytes plus a stable positive control. The initial positive case reached correct receiving assertions but failed fixture cleanup, repaired separately.

The production correction is integrated; post-fix native qualification is pending.

## AHK-098: A clipboard renderer redirects SendInstant output into another control

Severity: high. Confidence: high. Evidence: native Windows fail-before.

SendInstant captures no native window/process/control authority across the yielding clipboard snapshot and final injection.

Reproduction: During the real ClipboardAll rendering callback, focus another native Edit before the pending wrap or gesture emits its text.

Observation: Run41954012438 records wrong_target1, one emission and transformed old text in EditB for both wrap and gesture in both orders.

Regression: Capture and revalidate native target identity across clipboard and send boundaries; refuse the wrap fallback after focus loss. Initial unchanged-target cases receive the correct output but require the separate fixture cleanup repair.

The production correction is integrated; post-fix native qualification is pending.

## AHK-099: Selection capture transforms another control within the same window

Severity: high. Confidence: high. Evidence: native Windows fail-before.

GetSelectionAsync binds foreground identity and physical generation but not the focused control before its first clipboard call.

Reproduction: During the initial real ClipboardAll renderer, move focus from EditA to EditB inside one foreground HWND, then complete selection transformation.

Observation: Run41954012438 records wrong_control1 and transforms bravo in EditB instead of the original selection in both orders.

Regression: Bind every real capture to a nonzero native control token, revalidate after callouts and before delivery, preserve manually built legacy jobs, and retain exact owner cleanup. The stable positive receiver case initially fails cleanup only.

The production correction is integrated; post-fix native qualification is pending.

## Profile publication follow-up for AHK-072

The profile source guard now compares the complete persisted LLM projection through the shared feature and private-menu collectors, including navigation preferences. It admits canonical loader equivalences without accepting unknown API selections or lossy future profile fields. A detached persisted RAM snapshot and the existing API authority protect against in-place dependency failure during the actual native writer. If durability succeeds but RAM publication is withdrawn, the existing exact-path session refusal prevents later stale full saves from overwriting the acknowledged profile; feedback states that the saved configuration requires restart. Ten added controls cover canonical values, unknown selection and both sides of native acknowledgement. Native post-fix qualification remains pending. This extends072, without increasing the distinct finding count.

## WPM compensation follow-up for AHK-081

The original104 native fail-before remains the evidence for the lost acknowledged successor. The correction now reserves each two-coordinate storage operation, captures its previous pair atomically in RAM, and publishes an opaque success receipt. Enclosing TOML failures can compensate only that exact receipt; a later success with identical coordinates also retires it. The local owner is released before failure notification so a notifier can legitimately publish its own successor. Storage and notification execute outside Critical, including for callers which inherited it. Eight additional tests cover two ABA cases, local callout reentrance, ordinary refusal, inherited Critical and a failure-notifier successor. Two separate Registry values are not represented as an atomic cross-process transaction; repeated native rollback refusal remains a reported failure. Native post-fix qualification is pending.

## Native qualification at a735586

Run41960804242 strictly discovers289 cases. Each order records267 successes and the same22 failures; complete production compilation succeeds and the selected native hotstring E2E corpus executes90/90 successfully. HTTP E2E is not selected and the full OS suite is not qualified. All090–099 corrections pass their primary native probes, as detailed in the register;095 standalone Unicode Tab remains blocked by a receiver prerequisite, while LF and all named-key InputHook cases pass. Profiles35, boot-feature6, clipboard receiving/selection, Wi-Fi, ROI, storage and diagnostics pass.

Two optional full-save probes confirm a072 extension: physical max_words21 becomes15 while RAM stays15 and the save returns1. Reload-B and unchanged-A controls pass. Four stronger WPM cases stop at an overly narrow native contention-code prerequisite; the inverse native operation will distinguish both5 and32 from unrelated failures. Seven Prompt fixtures omit a genuine request-plan constant, two final-context fixtures read an absent pre-start registration property, one meta mutant no longer changes its assignment, and two Changelog fixtures miss their native notification. These fixture failures do not establish new product findings. Escape and captured-Ctrl controls extend053/067 with actual receiving evidence, and are corrected separately.

## Native qualification at c5eda7e

Run41962516263 discovers72 different targeted cases:34 pass and38 fail in each order with identical failing names. Production compilation succeeds; both optional E2E groups are unselected. The run establishes100–101 below. It extends existing families: five personal-information syntax/type cases erase authored fields or aliases during an unrelated edit (projection/preservation family068); two API aggregation cases publish infinity or a positively wrapped Int64 total (066); two Backspace repeat frames emit after pause/restart (036); a pre-existing Wrap stage is overwritten and consumed (071); and the true default full collector overwrites an independently changed non-LLM locale during a profile edit (072). Their ordinary controls pass. These variants do not inflate the distinct count.

The newly introduced WPM authority object incorrectly used AutoHotkey's reserved base slot for a storage path and raises Invalid base before assertions. It is immediately corrected to storagePath at fec406d, without counting an introduced regression as a new finding. Two clipboard snapshot probes stop at an independent-owner prerequisite, and the redirected long-transform probe fails to establish its intended timing boundary. They remain unconfirmed hypotheses.

## AHK-100: Malformed locale catalogues escape safe translation fallback

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

\_I18nLoadLocaleMap in infra/locale.ahk catches JSON syntax errors but does not validate the flat String-to-String catalogue before iteration, substitution and TSV caching.

Reproduction: Call the actual public translator with genuine locale JSON containing a Boolean root, array root, nested value, numeric value or null value.

Observation: Run41962516263 reaches the real private source in all5 malformed modes: Boolean/nested/null values throw, array is incorrectly loaded and numeric translation returns Integer. Flat and empty-object controls pass; inverse repeats.

Regression: Validate the entire catalogue inside the existing protected parse boundary; refuse before any cache publication, and retire v1 TSV files whose serialization erased bad source types. Eight cases include a genuine newer legacy cache.

Post-fix native run41967942121 at1152bd8815094b59581f62a65c663fbf7b089f6a passes all8 cases individually and reversed. The mixed250-case cohort remains red and does not qualify the full suite.

## AHK-101: Program providers reject an absolute UNC share root

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

ProgramProviderAbsolute in the Windows shared AHK owner requires a descendant character after the UNC server/share separator instead of admitting the complete share root itself.

Reproduction: Call the actual ProgramProviders_ConfigRoute with configuration at a UNC volume root, with and without a trailing separator.

Observation: Run41962516263 returns false for both complete UNC roots while drive-root, UNC descendant and malformed/device controls pass. No SMB access or discovery success is inferred.

Regression: Nine independent real route/admission cases admit complete UNC roots and preserve all malformed/device refusals; the path policy permits an optional descendant suffix.

Post-fix native run41967942121 at1152bd8815094b59581f62a65c663fbf7b089f6a passes all9 cases individually and reversed. The mixed250-case cohort remains red and does not qualify the full suite.

## Additional integrated corrections awaiting qualification

The071 Wrap publisher now retains its exclusively created stage and folder handles through native rename and cleanup. Pre-existing stages remain untouched. A structured receipt distinguishes actual rename from complete durability, and a failed post-rename flush fences only the obsolete live projection; a newer real reload remains usable. True writes, rename, close and retry controls retain explicit partial-failure feedback. The066 request aggregator independently bounds each counter and cost and retains unknown fields until finalization. One-shot053/067 controls replay Escape as a named key and preserve captured logical modifier flags without adding one-shot Shift. All require their next targeted native receipts.

## Scoped profile and optional boot follow-up for AHK-072

The five profile actions now collect and write only the canonical LLM subtree. Their native writer rejects broader roots even through an injected collector, and their RAM publication rebases the LLM result over the current other roots without replacing unrelated metadata. The two original full-collector locale oracles are preserved and two additional controls cover RAM identity and refusal of a collector broader than the profile owns.

Automatic optional boot full saves retain their actual admitted boot source in the existing private request ledger. If the physical source has changed, only that exact optional generation may settle without a fabricated durable commit, stale collection, notification or retry loop. A coalesced mandatory request cannot be discarded; matching source A remains bound through the existing WAL. These corrections and their targeted controls await native qualification.

## Personal-information projection follow-up for AHK-068

The reader now decodes its single held byte buffer through the existing BOM-aware decoder and projects the canonical TOML document. Known identity fields and aliases require actual String-token intent; wrong types latch write refusal before cache or RAM publication. Literal, multiline, inline, dotted and UTF-16 BOM forms receive explicit coverage. The publication-race fixture uses a valid TOML invalid-length alias to reach the actual warning callout; duplicate exact TOML assignments are no longer used as a substitute for a valid document. The existing ownership, bytes and generation oracles remain. Native qualification of the canonical reader is pending.

## AHK-102: Locale fast caches silently rename delimiter-bearing translation keys

Severity: low. Confidence: high. Evidence: native Windows fail-before.

The locale cache writer emits raw keys into tab/newline-delimited records. The reader then interprets a key's delimiter as structure while the entry-count sentinel still matches. An unknown source key can therefore become a different lookup key after a warm reload.

Run41969593070 at320cd51a8171a8b8ed84f74c46acb7e198768865 reaches both real generated caches with `warm_ok=1 warm_fast=1 count=1`, but `exact_key=0` for tab and newline keys. Cold JSON decoding and the three carriage/backslash/value controls pass. Both failures repeat in inverse order.

The correction escapes both fields with the same codec, decodes complete keys, distinguishes sentinel records from data and regenerates historical v2 caches. The five original native cases and an additional genuine v2 cache case cover the fix. This TSV format belongs to Windows; the Lua drivers do not consume it. Post-fix native qualification is pending.

## Personal-information encoding follow-up for AHK-068

The same10-case native run proves an additional source-fidelity failure in the existing068 family: an unrelated public edit acknowledges success over invalid UTF-8 (92 original bytes become98) and an odd UTF-16 BOM image (191 become101). Neither reader latches refusal. All three genuine UTF-8, UTF-8 BOM and UTF-16 BOM controls pass, and both failures repeat in inverse order. Strict decoding of the same captured Buffer is integrated and awaiting native qualification; no extra distinct count is assigned to these source-preservation siblings.

## AHK-103: A physical wrapping trigger invalidates its own prewarmed selection capability

Severity: medium. Confidence: high. Evidence: production and upstream source ordering; analogous native composition.

A physical wrapping key in a later clock tick invalidates the otherwise-current cached selection before its own callback consumes it. The epoch guard is necessary to refuse stale selection text. The missing part is a fresh acquisition path for this case.

AutoHotkey2.0.26 [hook.cpp](https://github.com/AutoHotkey/AutoHotkey/blob/v2.0.26/source/hook.cpp) updates `g_TimeLastInputPhysical` in `KeybdEventIsPhysical` before posting the hotkey callback (lines428/3056 before1807/2060); the inspected file SHA256 is `a57af3904a523710eed8872a62789c76583f2da41f79e5431439e5e404417a58`. Suppressed nonmodifier keys still reach this update. The audited baseline already contains the strict consumer guard. Same-tick inputs and direct invocations can succeed; this finding does not claim every invocation fails.

Runs41954012438 and41960804242 reproduce a no-hook RegisterHotKey/injected-input analogue with unchanged target and selection while the direct control passes. These runs are not physical-hardware or installed-hook input measurements. Production physical reachability is derived from the exact upstream ordering above.

The correction retains the strict getter and starts a new default asynchronous copy only for an otherwise-valid snapshot rejected by epoch. It never promotes the old text or epoch. The original target, lifecycle owner, command id and input generation remain required at the final send. Only a same-context timeout whose cleanup debt has settled may type its original bare symbol; failed starts, empty successful captures, cancellation and supersession cannot. Four native composition cases and nine cleanup controls await post-fix qualification. Gesture transforms retain the same original-target admission across their actual work as a sibling of098.

## AHK-104: Pointer movement alone never reaches the durable distance aggregate

Severity: medium. Confidence: high. Evidence: source and native Windows fail-before.

The hook tick, public flush and snapshot publisher each test only events, clicks and scrolls when deciding that a buffer is empty. All three omit accumulated pointer distance.

Run41967942121 at1152bd8815094b59581f62a65c663fbf7b089f6a drives the genuine sampler from0,0 to3,4. Both direct and periodic flush report `samples=2 pending_rows=0 remaining_distance=5 errors=0`; cold canonical SQL contains no distance. Both failures repeat in inverse order. The with-click control is not qualified by this run: its child omits the genuine JsonStringLiteral dependency and fails on that binding before its comparison.

The correction includes distance in all three empty guards. The control composition now includes the actual JSON owner; no serializer or SQL oracle is replaced. The same three native cases await post-fix qualification.

## AHK-105: Unblocking a selected folder mutates an external junction target

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The recursive FilesUnder iterator follows a real NTFS junction below the selected folder. Run41967942121 at1152bd8815094b59581f62a65c663fbf7b089f6a removes both the ordinary inside file's Zone.Identifier and the stream of the separate outside target: `inside_stream=0 outside_stream=0`. The outside-preservation assertion fails in both orders.

The action now uses its own bounded native iterator and excludes encountered file and directory reparse points. The explicitly selected root remains the chosen starting point. The generic FilesUnder contract is unchanged. This is cooperative pathname confinement, not an identity guarantee against concurrent component replacement. Native post-fix qualification is pending.

## AHK-106: Incomplete unblock enumeration reports successful completion

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The generic recursive loop silently omits a real ACL-denied subtree. The same native run proves Win32 error5, removal of the accessible stream and preservation of the inaccessible stream, yet the action records `error_log=0 success_log=1`. The required partial-failure assertion fails in both orders.

The action-specific iterator now reports native FindFirst/FindNext/FindClose failures and entry/path-budget exhaustion, while retaining already enumerated ordinary files. The caller logs incomplete processing as an error. Existing genuine junction/ACL tests and a native bounds control await post-fix qualification. A native FindClose refusal is reported but its handle retirement has not been measured; no zero-leak guarantee is asserted.

## AHK-107: Accepted carriage returns escape calendar and mail newline encoding

Severity: low. Confidence: high. Evidence: native Windows fail-before.

The real model JSON and action schema admit standalone carriage returns. Both connector encoders normalize CRLF and LF while leaving a lone CR unchanged. Calendar TEXT then contains an unescaped physical carriage return; mail bodies contain `%0D` without the `%0A` required for their canonical CRLF line ending ([RFC5545 section3.3.11](https://www.rfc-editor.org/rfc/rfc5545#section-3.3.11), [RFC6068 section5](https://www.rfc-editor.org/rfc/rfc6068#section-5)).

Run41971633136 at7a7e1e8ec8d4aeb252a8d2456b12c115ca190abb fails all four carriage/mixed calendar/mail cases in both orders. Calendar records `exact_record=0 lone_break=1`; mail emits `first%0Dsecond`. The six LF, CRLF and literal-backslash controls pass. These receipts qualify payload conformance, not an external application import.

The Windows correction normalizes CRLF and then standalone CR to LF before the existing destination encoding. All ten original tests remain. The shared Lua homologues retain this edge and are explicit parity debt outside the requested Windows scope. Post-fix native qualification is pending.

## Native qualification of the latest corrections

Run41971226185 at639de1fcae98920d622bf345ee2e675d4c7b146b passes the six102 cache cases, four103 fresh-selection cases plus nine cleanup-continuation controls, all three104 distance cases and the genuine105/106 junction/ACL/bounds cases individually and reversed. All seven strict personal source-encoding cases and the complete27-vector decoder contract pass. The full production parse and90/90 hotstring E2E pass, while the mixed122-case cohort remains red at109 passes/13 failures per order; this does not qualify the full suite.

The same run proves six091 Anthropic/Gemini response siblings while four ordinary/reasoning controls pass. Complete text concatenation and refusal of malformed partial data are integrated and await postfix qualification. Run41971633136 also proves a068 public-writer NUL sibling (result1/parsed1, bytes98 to97) with both legal controls passing. The writer now checks the original UTF-16 scalar span before String operations; public and direct-owner qualification is pending.

## AHK-108: A copy made after SendInstant snapshots the clipboard is overwritten and lost

Severity: high. Confidence: high. Evidence: native Windows fail-before.

SendInstant captures ClipboardAll A, then unconditionally publishes its payload after another native process has copied B. The later restore legitimately owns the payload sequence but restores stale A over the user's newer copy. This precedes publication and differs from097's missing post-publication guard.

Run41971226185 authenticates the independent HWND, exact transferred HGLOBAL, full native UTF-16 bytes and stable sequences28/50 before the actual publication. Both real pastes succeed, yet final sequences39/61 have another owner and `clipboard_original_a=1`. Both different-text and same-payload-text copies are lost, including in inverse order; the stable control passes.

The correction using the existing native snapshot/CAS/owned-restore primitives is integrated. Its original ClipboardAll, exact debt, prior097 attacks and receiving/cleanup oracles must remain. Post-fix qualification is pending.

## AHK-109: Closing the initial changelog Show leaves its native window alive

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

The window builder publishes its GUI only after Show. A real Close during Show therefore invalidates the epoch but cannot destroy the local host; the old opening then republishes it and calls the WebView factory. Run41971226185 observes `close_entered=1 native_closes=1 critical_at_show=0`, followed by `native_alive=1 gui_global=1 factory_calls=1`. The ordinary Show control passes, and inverse order reproduces the failure.

The proposed correction claims the exact native GUI before Show and validates its epoch/identity after Show before factory creation. Abandoned local hosts are destroyed without touching a successor. The correction is integrated; native postfix qualification is pending.

## AHK-110: Stopping keystats discards the final foreground interval

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

Stop invalidates capture and its privacy tracker, then flushes existing rows without closing the active app/title clocks. Runs41967942121 and41971226185 observe terminal `rows=0 elapsed=46-47 errors=0` and cold SQL app time0. The corrected positive control emits two switch rows and47ms of canonical app time in the latter run. Both results repeat in inverse order.

The pending correction must close accepted origins through independent acknowledgements, preserve privacy refusals and retain transition ownership across native Stop reentrancy. Four extra accepted-row/Stop cutpoint controls are integrated for the next native run. Implementation and postfix qualification remain pending.

## AHK-111: A selected existing application path can launch its executable prefix

Severity: high. Confidence: high. Evidence: native Windows fail-before.

The chooser stores an unquoted file path, while open_app passes that value as a raw Run command line. Windows can therefore select an existing executable prefix before the first space. Run41974178449 at26b1ecd81954794d09806e746265724e60332bc1 launches the private `witness.exe` instead of `witness.exe folder/target.exe`; the quoted control succeeds. Both exact processes are authenticated by retained handle, PID, creation FILETIME and image, and joined before cleanup. The failure repeats in inverse order. No privilege elevation or execution of external applications is claimed.

The correction quotes a complete value recognized as an existing file, preserves legacy shell URI/argument strings and leaves generic Launch unchanged. The original lifecycle owner remains required after the filesystem probe, including actual suspend/resume. Native receiver, shortcut and compatibility controls await postfix qualification. A missing or unobservable path string remains indistinguishable from a legacy command without additional stored provenance; that separate domain is outside this correction's claim.

## AHK-112: Malformed locator bytes silently select a different configuration profile

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

ReadPathsToml replaces malformed UTF-8 before routing. The native run independently proves invalid original bytes and native replacement decoding, then reaches `refused=0 selected-target=1 actual-profile=redirected` in an actually existing private U+FFFD profile. The valid Unicode control selects its intended profile. Both results repeat in inverse order; no user profile is modified by these fixtures.

The correction reads one raw Buffer and decodes it strictly through a pure early-boot codec extracted from the qualified068 algorithm. Personal helper signatures remain intact. Four actual routing cases preserve malformed-byte refusal and the valid Unicode, UTF-8 BOM and UTF-16LE BOM protocols. Native postfix qualification is pending.

Native replay41974178449 (26b1ecd81954794d09806e746265724e60332bc1) qualifies the ten calendar/mail newline cases (AHK-107), five public/direct scalar writer cases (AHK-068), ten Anthropic/Gemini cases (AHK-091), and both initial native changelog Show/Close cases (AHK-109), individually and reversed. The full45-case cohort remains red (36 pass,9 fail); these are selected-case qualifications. Production-entry compile passes; neither E2E flag was enabled.

The ordinary TOML foreign-stage failure in that same replay extends AHK-071 rather than the distinct-finding count. Commit a5b3687b retains exclusive stage ownership through exact readback and publication, and preserves truthful session feedback after an unacknowledged native rename. Five additional native-I/O regressions and the nine adapted atomic contracts await Windows replay.

AHK-113 is a source-confirmed field-run timestamp defect: date and time were formatted from separate UTC reads, allowing a midnight crossing to produce a timestamp one day behind. The helper now captures one instant; deterministic formatting and single-read source contracts await native qualification. No system clock change or measured midnight race is claimed.

Replay41980253833 at3005ee52e6c0a2b67e785395a52a3cab79f1c890 executes all142 selected cases:138 pass and4 fail, with the same names and counts reversed. Production compile and90/90 native hotstring E2E pass. It qualifies the selected SendInstant native CAS, locator byte handling, ordinary held TOML publication and existing-file OpenApp regressions. The remaining profile before-ACK fixture cutpoint and decimal-only atomic scanner require review; neither is silently promoted to a product defect.

AHK-114 is independently demonstrated by the real Jev requester/private HTTP peer: after original requester withdrawal, one actual POST still publishes before the stale consumer ignores it. Exact transport and registry retirement succeed. The live control passes; the withdrawn case fails in both orders. The same replay confirms a destruction-reentrancy sibling of AHK-109: a native replacement changelog window survives but the returning old Close clears its global owner. Both fixes are in progress.

Replay41981613076 executes no business cases: its discovery stops on the reserved AHK variable name Case in the newly added UTC test. That test syntax is corrected; no qualification is attributed to this failed discovery.

Native replay41983518296 atba6cc6c6b7a5c0cfa9eae5cc8d2e9c6d289ae5d5 executes137 cases:122 pass and15 fail, with the same names and counts reversed. Production compilation passes; both E2E manifests are unselected. It qualifies the selected Jev requester correction, changelog detachment, held/relative TOML writer, profile retirement, final context clocks and UTC snapshot contracts. It is not a whole-suite qualification.

Five new distinct families are confirmed:115 decoded physical-key membership,116 Norwegian catalogue mapping,117 user UI language versus regional formats,118 Kana tap admission,119 canonical SQL thinking-pause reconstruction. Additional observed proxy, Wrap scalar, existing-folder target, nonempty context and onboarding failures extend existing072/068/111/110/109 families and add no count. One shutdown-chain failure is only an incomplete fixture class graph and is corrected separately.

Native replay42004194057 at5f7909360bf96c03f96b62b1b40719010b19b761 executes63 selected cases:58 pass and5 fail, with the same names and counts reversed. Production compile passes; both E2E manifests are unselected. It qualifies the selected escaped-key boot ownership, UI-language/Norwegian mapping, Kana tap, scalar admission, existing-directory prefix, onboarding and authenticated proxy boot corrections. Personal-output probes already pass through central scalar admission; no speculative writer patch is applied.

The two actual proxy full-save failures extend072, and the simulated timezone second-boundary failure extends113. A separate excluded-source debounce request is observed with both negative/positive controls; its ownership chain is under review before allocating a distinct finding. The shutdown-chain failure is again a missing real dependency in the generated child, not a demonstrated product failure. Source96db265f corrects nonempty A-to-B preparation ownership; source04970810 implements SQL thinking-pause reconstruction; e2e33a1d observes a single native timezone bias. Their targeted native qualification remains pending.

AHK-120 is independently confirmed by replay42004194057: after24 actual injected characters arm the real timer in excluded A, a focus-only switch to allowed B produces one genuine private HTTP POST with A context. The excluded-stays0POST and allowed-stays1POST controls pass; inverse repeats. Current focus alone cannot admit a retained excluded-source payload. Correction and native postfix qualification remain pending.

Replay42006372296 at7cba520271a2568c094c7b475688ea40207c66ac executes no business cases: discovery stops on reserved variable Local in the new independent timezone test. Production compilation passes; neither E2E is selected. The fixture variable is renamed LocalTime before retry; the unexecuted134-case cohort receives no qualification.

Replay42007542450 at9dd5c4f12fbdd56ad34394fb4c2443e8088d0149 executes152 selected cases:144 pass and8 fail, with identical failure names reversed. Production compile and90/90 native hotstrings pass. The selected HTTP override step passes its explicit11-case completion guard; its detailed TAP is not retained in these two archives. Selected SQL thinking-pause, timezone, proxy full-save and excluded-source debounce corrections are qualified; this is not a whole-suite result.

The8 failures comprise personal/migration/locator stage ownership, two raw TOML update-name variants, successive ABC context ownership, mutable registry cache ownership and Sticky Kana capture. Only the mutable registry cache introduces a new distinct family (AHK-121); the others extend existing071/068/110/067. Correctors retain the original fail-before controls and exact native prerequisites. Replay42009207272 at7974f33b executes30 distinct targeted cases:29 pass and1 fails, identically reversed. Local/public prediction ownership and all3 queued proxy controls pass; the actual override-stage collision fails while its ordinary control passes.

## Native continuations and two additional confirmed families

Replay42012445164 executes52 selected cases:47 pass and5 fail in each order, with identical failures. Production compilation passes; neither E2E is selected. It qualifies the selected raw TOML names, locator, pending registry clone, migration-stage and Sticky Kana admission corrections. The cache-stage failure extends071. Three genuine password/rolling-context failures extend120: a password source followed by a focus-only switch sends A, and actual fresh allowed B input still sends both A and B after excluded or password A. The configuration-name positive control was unadmitted because its fixture omitted actual boot preparation; it proves no production failure and is repaired separately.

Replay42016035455 executes110 selected cases:109 pass and1 fails in each order. Production compilation passes; neither E2E is selected. It qualifies the selected observed-context FIFO, same-app title transition, override ownership, personal/info/cache held-stage and configuration-name corrections. The sole partial-publication case reaches a nonexistent reload function in its fixture after the native rename; commit92ba8c6b calls the actual HotstringsConfigReload API. Its full qualification remains pending.

Replay42017171434 executes19 selected cases:11 pass and8 fail in each order. Production compilation passes; neither E2E is selected. The four provider-NUL cases already pass, so no speculative provider patch is applied. The eight failures comprise two distinct new families below plus ROI094 and released-Kana067 siblings. The ordinary controls pass. Commitfe18d899 makes ROI mutation conditional on the canonical current snapshot; commit8f9566d8 captures custom modifier state at the endpoint rather than after its native release. Native postfix qualification is pending.

### AHK-122: Exhausted signed event identities rewind recovery or publish a negative allocator

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

A genuine source containing signed MAXINT produces resolved1, accepted1, new_id1 and inserted0; INSERT OR IGNORE hides the lost event. A source containing MAXINT-1 accepts MAXINT but leaves counter_after=-9223372036854775808. The ordinary40-to41 case passes, and inverse order repeats both failures. Commitb31e9a4c refuses capacity before publishing invalid state and preserves already-reserved terminal checkpoint replay. The original three source/SQLite tests plus the new atomic capacity control await native postfix qualification. This is a persisted-domain boundary; no natural uptime exhaustion is claimed.

### AHK-123: Embedded NUL registry names access or mutate a different shorter value

Severity: high. Confidence: high. Evidence: native Windows fail-before.

A real JSON-produced13-unit name containing NUL causes each actual ST_Set/Get/Has/Delete operation to address its distinct shorter private HKCU neighbor. Set replaces Original with Edited; Get returns Original instead of missing; Has returns1; Delete removes Original. Unicode and default-name controls pass. Commit2c5ac7cc checks the original UTF-16 span before native conversion and keeps the established numeric-key conversion contract. The six native cases and two numeric controls await native postfix qualification. Separate scalar-persistence and counted-name inventory probes are hypotheses until their own actual native receipts arrive; they add no finding count.

Replay42020967359 at0fd15d38839c8d58b7e9978a79aa69210f0f1703 executes65 strictly selected cases:62 pass and3 fail, with identical failures reversed. Production compilation passes; both E2E flags are unselected. The signed event-domain/capacity, stale ROI, public registry-name/coercion, override partial-publication and custom Kana endpoint corrections all pass their selected controls in both orders. This remains a selected-case qualification, not a whole-suite result.

Its three failures are a personal-information close/reopen sibling of109, a counted native-name inventory sibling of123 and one distinct scalar-persistence family124. The real WM_DESTROY callback issues the public reopen request but no successor is constructed (windows1/factories1/newer_seen0); ordinary close passes. Actual NtSetValueKey accepts a distinct counted NUL name, raw Win32 enumeration proves its full13 units, yet ST_Clear acknowledges1 with1 of2 values still present. Conversion to a truncated String precedes name validation. Both cases await correction and add no new distinct count.

### AHK-124: A successful scalar String write silently truncates embedded NUL content

Severity: medium. Confidence: high. Evidence: native Windows fail-before.

A genuine3-unit JSON-produced String A/NUL/B is persisted through actual ST_Set into an exclusively owned HKCU fixture. Result1 is followed by actual_string_units1: the suffix is lost. The same content in the supported JSON Map envelope roundtrips3 units, and exact/wide binary64 controls preserve the independent expected bit patterns. Both orders reproduce the scalar failure. Direct scalar envelope construction reaches a null-terminated native conversion without validating the original span. The correction must either preserve every unit or refuse before mutating Original; it is pending. The numeric precision hypothesis is refuted for the qualified controls, so no numeric encoding rewrite is proposed.

The next corrections are integrated separately:2d3d2fe1 preserves complete NUL-bearing scalar Strings through a strict q: envelope while keeping ordinary protocols; d57bd717 refuses an unaddressable counted-name inventory before any deletion;9d40b9d0 detaches the personal-information host before native retirement; ff64593a binds rolling LLM context and its original privacy receipt through debounce and automatic agent System1/System2. Original native business oracles remain, with explicit compatibility for earlier private refusal. Replay42023834421 has started with177 selected cases, both E2E flags enabled; no completion result or postfix qualification is attributed while it runs.

Further test-only probes are independent hypotheses: actual prefix-observer destructor lifetime, native custom flags in OneShot, an override reserved-root roundtrip, existing registry-key identity controls, retained agent-pause cancellation capability and TakeNote pause/reentrancy. The agent-pause probe manually recalls an older scheduler fixture callback; a failure would establish that protocol invariant, not prove that native SetTimer delivers after cancellation. They add no distinct count before assessment. The follow-up23-case replay has a separate immutable checkout and does not replace or resume the177-case run.

The audit helper's verify-commit command requires its canonical fix-ahk-audit worktree and refuses this user-requested fix/windows checkout as missing. That refusal is not test evidence. The current branch is preserved as requested; finding trailers and source commits remain directly reviewable in Git, and native/behavioral qualification is reported separately.

## Later native receipts and observer lifetime

Replay42023834421 at4c5999f01d9c1f26c3feae061b83e737e7d0e626 executes177 selected cases:169 pass/8 fail individually,168 pass/9 fail reversed. Production compilation and90/90 hotstring E2E pass. The selected managed HTTP override step completes its explicit11-case guard. Storage quoted-scalar, counted-name refusal and personal-information close/Reset corrections pass their selected cases in both orders, including exact native successor survival. The Sticky preheld control passes. This is not a whole-suite qualification.

Its four native menu suffix collisions are confirmed in both orders: personal sections retain only2 of3 native rows, and the profile frame retains31 of32. These extend preexisting named uniqueness contracts and add no family count. Commitd91f90f3 reserves actual outputs in both consumers; a separate actual Menu case-comparison receipt is still pending. Two TakeNote pause probes fail their resume prerequisite before any business oracle, so no TakeNote defect is confirmed. The private child lacked the unrelated KeyboardArbiterEnsureForLedger resume port;098b36af declares and authenticates that passive prerequisite and prints real debts before assertions. Production lifecycle is unchanged.

The scalar-framing focus-change observer-count failure and live-expansion target-control failure require compatibility review. Privacy passes all8 real source cases and10 new units individually. Reversed password-switches-typed retains no A canary but loses fresh B context despite48 real characters and one POST: exactBbuffer0/engine0/Bcanary0. This is a loss/admission divergence, not evidence of A transmission. Its cause is being fixed before full privacy qualification.

Replay42025538508 at3263811d executes23 selected cases:14 pass and9 fail with identical names reversed. Production compilation passes; neither E2E is selected. Original plain/standard OneShot controls pass while the custom released modifier reaches the actual replayed Backspace as absent; it extends067. Bare ext override ACK1/reload1 loses its record and blocks the next valid write, while ext.demo passes; it extends068 and is corrected bye4098414. Three existing registry-key controls pass, refuting the suspected predefined-HKEY pointer defect on the actual runtime. No registry-pointer patch is applied.

TakeNote's four resumed modes remain unadmitted due to the same child prerequisite; same-epoch passes. The retained agent-pause fixture proves loss of the successor cancellation capability, but explicitly recalling that old callback does not prove native delivery after SetTimer cancellation. Commit360ec610 adds a short RAM generation claim before clearing that capability as protocol hardening; it adds no distinct finding.

### AHK-125: Retired per-character prefix observers retain a callback cycle

Severity: medium. Confidence: high. Evidence: actual AHK destructor and native-scheduler fail-before.

Both cancellation and genuine one-shot completion reach global_retired1 with fake_callbacks0, then keep owner_deleted0 after exact native callback cancellation and release of local references. The independent acyclic control is destroyed once. The owner retains its BoundFunc, which retains that same owner; removing its global never breaks the cycle. The mechanism already exists at9154723b, so it is a new campaign finding rather than a regression introduced by the privacy correction. No RSS, byte-rate or latency claim is made.

Commit06b42cec detaches the reverse edge before cancellation and in the old owner's own finally, even when a successor has been published. The original two lifetime tests remain unchanged. Ten privacy/reentry controls now retain actual callbacks before revocation and explicitly check that returning old frames preserve the successor. Postfix native qualification is pending.

### Native qualification update: replays63 and64

Replay42028281855 executes63 selected tests:57 pass and6 fail in both orders. Production compilation passes; neither E2E is selected. It qualifies AHK-125 callback retirement, the bare-extension name refusal, menu suffix preservation and the agent pause-capability controls. Four admitted TakeNote lifecycle failures establish AHK-126 below. Two actual TapHold source A-to-B failures extend072 and await correction.

Replay42031267454 executes64 selected tests:54 pass and10 fail individually;53 pass and11 fail reversed. Production compilation passes; neither E2E is selected. It qualifies the TakeNote lifecycle correction, scalar source guards and all8 actual menu suffix/case tests. Two causal admission-order cases corroborate unresolved120 character loss: a genuine later native timer arrives during the genuine secure-field read and the final buffer is b rather than ab. Reverse plain-stays also loses a fresh B character. Eight model-browser tests fail their stale diagnostic catch-entry prerequisite before child construction; they establish no product defect and their fixture is repaired separately. Both native TapHold inheritance controls pass before the proposed leaf-writer correction, so no inheritance defect is counted.

### AHK-126: Deferred note jobs survive suspension and resume

Replay42028281855 admits the genuine lifecycle with keyboard_port1 and debt0. Queued, waiting, inflight-file and clock-acquisition probes all allow old note work after resume; the unchanged-epoch control passes. Both orders reproduce. A current-suspension check cannot withdraw an older request after resume.

Commite5a7025d captures the epoch before callouts, revokes exact jobs during SuspendEnter and checks ownership before each external effect and pending publication. Replay42031267454 qualifies all6 lifecycle tests plus13 existing note controls in both orders. The clock-port cutpoint is controlled reentry, not a claim that A_TickCount spontaneously pumps a callback. Real Notepad same-basename document probes are a separate unexecuted hypothesis.

### Native replays54,67 and13

Replay42034174395 atf305db51 finishes48/54 passing individually and49/54 reversed. Production parsing passes; E2E is unselected. The selected OneShot flag and balancing corrections pass. A genuine delivered Down followed by an explicitly thrown port error remains untracked after lifecycle cleanup (037). The six older model close/pause tests now pass after repairing their fixture. The API backend selection leaves the API backend active despite an acknowledged Ollama model choice; its ordinary backend control is initially unadmitted because the physical sparse TOML omits the actual default. The fixture now reads that canonical default; no model-policy fix is inferred before the control runs. A managed bootstrap retains its canceled bound timer (125). Sticky preheld fails an isolated injection prerequisite and passes reversed, so this is not product failure evidence.

Replay42034753005 ataa51a694 passes65/67 in each order. It qualifies the selected source-B TapHold correction and typing admission correction, including all8 genuine source/privacy cases, both causal ordering probes and90 native hotstring E2E cases. Production parsing passes. Its two failures are a stale loader-signature meta repaired in0c27c169 and a real default-stage collision extending071. The original producer enters and returns after an exclusively created concurrent stage, then reports result1, consumes the stage and publishes enter. A held-stage correction is integrated for the next targeted replay, without claiming recovery after an unacknowledged post-rename flush.

Replay42035395037 atc160aceb passes11/13 in each order. The admitted native settings Close exposes a stale Layout opening (109); the actual private-title lag exposes5 accepted paste rows plus1 burst despite captured-source refusal (016). Their controls pass. Source068df7d4 corrects paste source admission; native postfix qualification is pending.

### AHK-127: A different note directory reuses the wrong actual document

Replay42034174395 opens genuine private A/Notes.txt, then requests B/Notes.txt. The active native document still contains A's authenticated canary, launches remain1 and the public job finishes without an error. Both orders reproduce; same-folder reuse passes. Cleanup authenticates and retires the exact owned processes/windows before releasing private files.

Basename matching cannot establish full document identity. A replacement which merely launches B and then searches that same basename could still accept A before B appears. The correction remains under investigation; current evidence does not justify a new document identity claim based on title, HWND or process alone.

### Native qualification: replays42 and40

Replay42037461104 at8ad112fd passes38/42 in each order. It qualifies paste/copy-title8, native Settings/Show/successor6, typing entry-lifecycle4 and the selected owned TapHold stage/transaction/loader/persistence controls. Its subscription Close proves an old add_Event continuation outlives native controller retirement (109). Source3dfc52f5 retains that host until unsubscribe can precede Close and Destroy; postfix qualification is pending. Model backend current reaches the desired selected model/backend but fails its Errors0 prerequisite, which remains enforced. A separate diagnostic now exports those retained errors; the API backend still remains API after model selection, without counting another family before the current control is explained.

Replay42039178724 at67757700 passes35/40 in each order. Production parsing and90 native hotstring E2E pass. It qualifies the uncertain-Down correction4e83ef8a and the minimal bootstrap timer retirementa2a2c25a. Its remaining failures are4 actual resource-option retention graphs (125) and1 controlled scalar restoration release (037). Those are confirmed extensions under correction, not five new distinct findings.

### AHK-128: A native password-style transition reuses an ordinary verdict

Replay42037461104 establishes a genuine normal Edit/cache/focus-hook receipt, then enables native ES_PASSWORD without changing HWND or element identity. Native inspection reports secure1 and conclusive1, but the actual adapter returns secure0 at47ms inside the unmodified1000ms TTL; diagnostics0. Both orders repeat. The normal and naturally expired controls pass.

Source92e4c1c7 refreshes bounded native classification before cache reuse and keeps inconclusive fallback conservative. Two added controls preserve exact UIA-negative reuse and reject stale native-negative reuse. Postfix qualification is pending. This detector proof is separate from any keyboard/HTTP leak claim; a native prefix retention/publication composition is newly integrated for testing. No IO is added to the RAM-only prefix reader by that getter-only change.

### Native qualification: replays37,41 and24

Replay42040988578 passes34/37 selected cases in both orders, with production parsing green and E2E unselected. All10 Layout retirement controls pass, including actual Destroy-then-throw retry, as do the5 secure-field getter/cache controls. The remaining prefix composition retains24 private units from actual InputHook callbacks despite fresh native password classification; the private peer receives0 requests. The public control produces1 real public POST. Source0388b174 corrects immediate retention through fresh gateway hints and a private-gap barrier;8 additional units and the original2 native oracles await postfix qualification.

Replay42055350664 passes40/41 in both orders. Production parsing and90 native hotstring cases pass, as does one selected actual launcher/relay owner case using its stub daemon. This does not qualify the complete proxy/SSPI suite. All20 selected scalar custody controls,11 bootstrap lifetime controls and2 native navigation controls pass. The sole failure confirms129 below with a now-clean ordinary control.

Replay42062852930 passes19/24 selected cases in both orders. Production parsing passes; all E2E flags are unselected. The original model2, earlier6 and3 admission controls qualify V1, while2 later admission cutpoints remain red. The power-unknown case confirms130. A failed actual bootstrap constructor retains its owner while the throwing acyclic control is destroyed, extending125. The action-level NUL launch probe refuses safely and its valid control passes; the direct adapter launches the shorter prefix despite retaining all original110 input units. The latter requires primitive-contract correction and does not establish a public action/config bypass.

### AHK-129: Native model selection leaves the previous API backend active

The actual API-to-Ollama selection persists B and closes the catalogue, but leaves the API backend active. Replay42055350664 has clean lifecycle retirement and errors0 in both ordinary/API probes; the ordinary Ollama control passes. The Web selector and other drivers activate Ollama for the same model-selection intent.

Sourceefda9c0a requires both persistence acknowledgements and current native ownership. Replay42062852930 qualifies the original controls and3 new refusal/replacement/lifecycle cases. Two further cutpoints expose an old selection activating a newer model and a second commit adopting a resumed lifecycle. Source9cffc325 validates the original receipt inside the existing mutator after bundle acquisition, then binds model/backend before closing. Those2 postfix cases remain pending.

### AHK-130: Unknown power status becomes a definite offline reading

The sensor receives documented AC255/battery73 bytes through an explicit native power port and publishes on_ac0. The genuine central publication and known AC/DC controls execute in both orders. Sourcec2787b90 omits the unknown AC field, preserving known values and the existing unknown-battery policy. Native postfix qualification is pending. The test does not claim these bytes came from runner hardware.

### Native qualification: replay75

Replay42065111326 at e152e4ed passes74/75 selected cases in each order, with production parsing and90 native hotstring E2E cases passing. It qualifies the character-input correction128, including zero retained private units in the actual password-style prefix composition, and all selected scalar/lifecycle/privacy controls. It also qualifies the two original-admission fixes129 and the power-status correction130. This remains a selected cohort; Backspace, late durable-writer replacement and natural Show/Hide probes are newly added hypotheses.

### AHK-131: Old brightness completion disables a successor timer

The original completion detaches A, an actual AHK timer admits B at the open cutpoint, then A stops the shared poller. B remains owned with0 retirements and0 completions after619ms despite its expired10ms fixture deadline. Both orders reproduce. Native scheduling is real; the process is an explicit passive port and no physical display effect is claimed. The same source separation exists at9154723b.

Commit632b4b35 makes detach/disarm atomic and carries the observed id from poll to cancellation, keeping process retirement outside the short claim. A stale-poll successor control accompanies the original real-timer regression. Postfix native qualification is pending.

### Native qualification: replay61

Replay42068231096 at d89176eb passes54/61 selected cases in both orders. Production parsing passes; every E2E flag is unselected. It qualifies the6 constructor cases and8 prior bootstrap controls, all12 selected launch/path controls, all13 brightness controls and5 native PNG geometry cases. The brightness worker remains an explicit process port; generated PNGs are real GDI+ output and do not capture the desktop.

Seven failures remain admitted: generic and display-sleep jobs execute after a fully settled Suspend/Resume (126), active Backspace ignores its fresh private receipt (128), a second model writer outlives its native window (129), older native Hide overwrites a newer Show (109), and two display discovery calls publish an effect while actually suspended (132). Their corresponding ordinary controls pass. Source0c1cb487,3d9c15e2,ba03a328,8dd602fe and64e3c737 address those scopes; their postfix qualification is pending. The actual WM_CLOSE dispatcher is tested separately because AutoHotkey may apply a default Cancel after a false GUI-event return; a direct handler call is not that proof.

### AHK-132: Display discovery loses pause admission before its effect

Both real display-buffer query stages can yield to native Suspend. The current action still applies one recorded topology and remembers it with suspended1. The private effect port protects the runner's screens; unchanged controls prove the ordinary action, and both orders repeat. This discovery-to-effect omission differs from126 stale deferred work after resume.

Source64e3c737 revalidates suspension and the original canonical lifecycle after each native read, before the first apply. It leaves bookkeeping after acknowledged application intact. Selected native postfix qualification is pending. Other actions interrupted during discovery are new probes, not additional confirmed variants or counts.

### Native qualification: replay107

Replay42077733273 at9db29fb4 passes88/107 selected cases in each order. Production parsing and90 native hotstring E2E cases pass; HTTP and relay-owner E2E were unselected. It qualifies the selected queued system, Backspace, display discovery, model durable-writer and original Show/Hide corrections. Unicode ledger-hole probes and ordinary/locked/foreign stage controls also pass.

Nineteen failures require separate treatment. Three privacy-gap cases, three in-flight system discovery cases, two selected reparse-entry cases, two native64 stage cases, one actual WM_CLOSE case and both proxy cases have admitted business evidence. Five model constructor/visibility probes fail setup or timeout, and one managed timing case has a different transport outcome under investigation; those six are not new product findings. The corresponding targeted corrections are integrated for a follow-up replay, without claiming postfix native success yet.

### AHK-133: An absent static proxy protocol is refused

Independent native WinHTTP controls establish direct success, absent-scheme DIRECT success and refusal through the unreachable matching proxy. The actual PS resolver and strict AHK selector still refuse a valid map containing only the other HTTP protocol. Commit3ab3785c permits that absence only after validating the map, retaining refusal for malformed endpoints and unsupported maps. This counts the two sibling selectors once.

### AHK-134: Authenticated plaintext HTTP uses the wrong proxy protocol

A private authenticated forward proxy serves the independent native absolute-form HTTP request with200/bodyOK. The genuine resolver/owned-hop request instead sends CONNECT to port80 and receives502. Native engine retirement and private proxy joining are confirmed in both orders. Commitd8575215 forwards plaintext HTTP using absolute form, keeps its own credential header and preserves secure/SOCKS tunnels. Native postfix qualification remains pending.

### Native audit: replay32

Replay42082616671 atf712b710 passes16/32 selected cases in each order, with production parsing green and all E2E flags unselected. Six native64 age failures and two cached Backspace failures extend046 and128. Three current-clock and three Backspace policy controls pass. Source91b73c31 andbb42f3c8 address these scopes; native postfix qualification remains pending.

Four distinct admitted defects raise the register to138: supplementary InputHook event characters become FFFD at the actual JSON/UTF-8 boundary (135); deep typing inventory disappears during a composed live frontend update despite real SQL counts2 (136); the actual detached app worker omits an ongoing interval visible in its parent (137); and provider discovery refuses two native exact-case-distinct scripts after independently qualified executions (138). The corresponding BMP, character, parent and ordinary-name controls pass. Provider source067cbec1 preserves exact duplicate refusal; the other three corrections remain in progress.

Prompt and model-Web subscription probes also expose native host destruction before the subscription call returns, extending109. The HCW destruction case instead has a technical error before its successor witness and needs that error explained. The third model visibility probe now proves its intended later Close was never invoked; it is an unadmitted test cutpoint rather than product failure evidence. Neither result adds a finding. Native hook input is software supplied, the frontend DOM is controlled, and none of these results qualifies physical hardware or a complete suite.

### Postfix qualification: replay107 at75367037

Replay42081608315 passes105/107 selected cases in both orders. It qualifies the selected seven correction scopes: cached character gaps, selected reparse confinement/feedback, in-flight system lifecycle admission, native64 stage recognition, actual model Close visibility, absent-scheme proxy routing and authenticated HTTP forwarding. The repaired managed timing control passes. Production parsing,90 native hotstring E2E cases and the targeted real relay-owner case pass. The HTTP override workflow step is green with its11 required controls; its output is not in the entry archive and no standalone raw HTTP receipt is claimed here.

The failed native model constructor now has admitted evidence: actual TypeError leaves its hidden HWND alive and its marker undisposed while the ordinary constructor works, extending125. The third-order visibility probe still never produces its intended later Close and is not a product verdict. The separate32-case replay passes the actual-hop CONNECT443 and SOCKS-domain80 component control; IPv4 explicit-port and IPv6 probes require their own later execution.

### Native qualification: replay50

Replay42085043186 atfec21431 passes46/50 selected cases in both orders, with production parsing and90 native hotstring E2E cases passing. It qualifies retained-input age correction046, cached Backspace128 and provider138, including the20 time-gate corpus vectors and actual wrap/selection controls. The expanded component relay control passes both independent and genuine-hop domain/IPv4-explicit-port/CONNECT protocols. No application TLS or IPv6 success is inferred from that component control.

Two public TakeNote counted-NUL destinations are admitted with a pending job and timer after the native path query aliases their existing prefix, extending111. Source707fbb2a refuses the original units before clock/job admission and at the native query/effect boundary; its postfix replay is pending. The actual different-directory note still reuses A instead of requested B (127); the authenticated UIA identity diagnostic supplies no full private path match, so no false document authority is introduced. The remaining IPv6 failure lacks a terminal child receipt and stays unclassified until its diagnostic stdout/exit is available.

### Native qualification: constructor21 and subscriptions18

Replay42088003052 at563ed472 passes15/21 cases in both orders. It qualifies the two original native model constructors, both new pre/post native Destroy refusal controls, TakeNote NUL3, the repaired third-order visibility probes3 and four earlier age controls. WPM and screenshot controls fail on missing genuine child dependencies; test-only source imports now repair those graphs. HCW exports an actual foreground warning while public reopen borrows its dying global A; IPv6 still fails a retirement prerequisite and has no product verdict.

Replay42088874728 atf368b97e passes18/18 subscription/startup/repoint/navigation/fallback/teardown/meta cases in both orders. The native Prompt and model-Web HWNDs remain alive until returned subscription ownership is known, then handles retire before controller Close and native destruction. Production parsing passes; no E2E was selected in either cohort. Close-after-effect COM exceptions remain unqualified; the exact protocol conservatively retains unacknowledged debt.

Source23858460 corrects partial live typing inventory without adding three heavy queries to every ordinary push. Targeted local JS metadata/selection tests, range bridges and feature inventory pass. The existing Reset command reports42 frontend passes and2 Lua subprocess environment failures, so it is not a full green command. Worker137 receives a separate real-initialization baseline before any source change; its previous protocol-level native observation did not authenticate the parent store routes. Unicode135 remains under correction, with independent native Backspace and publication-boundary checks required before adoption.
