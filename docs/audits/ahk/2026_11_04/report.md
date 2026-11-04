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
