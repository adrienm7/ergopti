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
