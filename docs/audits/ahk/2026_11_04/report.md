# Windows audit campaign, 4 November 2026

Audited commit: `9154723b34ee0599433cbf749a4aca839bd54b53`. Scope: ErgoptiPlus Windows; read-only parallel passes covered keystats, input, UI and LLM request handling. Evidence is derived from production source and existing tests. The findings below have not all been executed on native Windows. No performance numbers were measured.

## Goal and evidence standard

The requested goal is 1,000 distinct new confirmed defects. The ongoing register currently records **45 distinct findings**. The initial snapshot contained eight findings. Earlier fixes on the branch precede this baseline and are not counted in this snapshot. Duplicate sites, policy disagreements and unconfirmed hypotheses do not increase the count. Implementation history and native qualification remain separate from source confirmation.

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
