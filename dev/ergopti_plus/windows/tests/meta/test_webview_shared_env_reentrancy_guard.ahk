; tests/meta/test_webview_shared_env_reentrancy_guard.ahk

; ==============================================================================
; MODULE: WebView2 Shared-Environment Reentrancy Guard Meta Test
; DESCRIPTION:
; Regression guard for finding F36: WebView_SharedEnvironment's guard used to
; be checked/assigned only around the blocking await() call. Promise.await()
; explicitly pumps the Windows message queue while blocked, so a second
; WebView2 host opened during the first's boot could reach the unguarded
; check before the first published its result, issuing a second
; CreateEnvironmentAsync against the same locked user-data folder.
;
; The fix sets _WebView_SharedEnvCreating BEFORE the await begins (not just
; around it) and makes a second caller poll until the flag clears instead of
; racing its own CreateEnvironmentAsync call. This is a meta-static test
; because there is no live WebView2/COM runtime in the headless test harness
; to drive a genuine concurrent boot (same class as SendInstant's clipboard
; reentrancy guard).
;
; SCOPE: source introspection of lib/webview_utils.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Reentrancy-guard assertions ===========
; ==================================================
; ==================================================

_WSERG_AssertGuardDeclared() {
	Body := _DriverFuncBody("WebView_SharedEnvironment")
	Assert(Body != "", "WebView_SharedEnvironment must exist in lib/webview_utils.ahk")
	Assert(InStr(Body, "_WebView_SharedEnvCreating") > 0,
		"WebView_SharedEnvironment must declare/use a _WebView_SharedEnvCreating reentrancy guard (webview-shared-env-reentrancy)")
}
Test("webview_utils: WebView_SharedEnvironment declares a shared-env creation guard (webview-shared-env-reentrancy)",
	_WSERG_AssertGuardDeclared)

_WSERG_AssertFlagSetBeforeAwait() {
	Body := _DriverFuncBody("WebView_SharedEnvironment")

	SetPos := InStr(Body, "_WebView_SharedEnvCreating := true")
	Assert(SetPos > 0,
		"WebView_SharedEnvironment must set _WebView_SharedEnvCreating := true BEFORE calling CreateEnvironmentAsync (webview-shared-env-reentrancy)")

	AwaitPos := InStr(Body, "CreateEnvironmentAsync(")
	Assert(AwaitPos > 0, "WebView_SharedEnvironment must still call CreateEnvironmentAsync(...)")

	Assert(SetPos < AwaitPos,
		"WebView_SharedEnvironment must arm the guard BEFORE the await() call begins, not just around it -- await() pumps the message queue while blocked, so a second caller must see the flag before CreateEnvironmentAsync is dispatched (webview-shared-env-reentrancy)")
}
Test("webview_utils: creation guard is armed BEFORE CreateEnvironmentAsync/await, not just around it (webview-shared-env-reentrancy)",
	_WSERG_AssertFlagSetBeforeAwait)

_WSERG_AssertSecondCallerFailsFastInsteadOfDeadlocking() {
	Body := _DriverFuncBody("WebView_SharedEnvironment")

	GuardCheckPos := InStr(Body, "if _WebView_SharedEnvCreating")
	Assert(GuardCheckPos > 0,
		"WebView_SharedEnvironment must check 'if _WebView_SharedEnvCreating' for a second caller arriving mid-boot (webview-shared-env-reentrancy)")

	AwaitPos := InStr(Body, "CreateEnvironmentAsync(")
	Assert(GuardCheckPos < AwaitPos,
		"WebView_SharedEnvironment: the in-progress check must precede CreateEnvironmentAsync so a second caller cannot race it (webview-shared-env-reentrancy)")

	; A nested thread that sleeps here blocks the first await from receiving its
	; completion. The second open must return through its existing fallback.
	GuardBody := SubStr(Body, GuardCheckPos, AwaitPos - GuardCheckPos)
	Assert(!InStr(GuardBody, "Sleep("),
		"WebView_SharedEnvironment must not Sleep in a re-entrant creation branch (webview-shared-env-reentrancy)")
	Assert(InStr(GuardBody, 'throw Error("WebView shared environment is still initializing")') > 0,
		"a second opener must fail fast to its existing fallback rather than deadlock the first environment boot")
}
Test("webview_utils: a second caller fails fast instead of deadlocking shared-environment boot (webview-shared-env-reentrancy)",
	_WSERG_AssertSecondCallerFailsFastInsteadOfDeadlocking)

_WSERG_AssertGuardClearedInFinally() {
	Body := _DriverFuncBody("WebView_SharedEnvironment")
	Assert(InStr(Body, "finally") > 0,
		"WebView_SharedEnvironment must clear _WebView_SharedEnvCreating in a finally block so a boot failure cannot leave a waiting caller stuck forever (webview-shared-env-reentrancy)")

	FinallyPos := InStr(Body, "finally")
	FinallyBody := SubStr(Body, FinallyPos, 120)
	Assert(InStr(FinallyBody, "_WebView_SharedEnvCreating := false") > 0,
		"the finally block must clear _WebView_SharedEnvCreating := false unconditionally (webview-shared-env-reentrancy)")
}
Test("webview_utils: creation guard is cleared in a finally block on both success and failure (webview-shared-env-reentrancy)",
	_WSERG_AssertGuardClearedInFinally)
