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
; SCOPE: source introspection of infra/webview_utils.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Reentrancy-guard assertions ===========
; ==================================================
; ==================================================

_WSERG_AssertGuardDeclared() {
	Body := _DriverFuncBody("WebView_SharedEnvironment")
	Assert(Body != "", "WebView_SharedEnvironment must exist in infra/webview_utils.ahk")
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
		"WebView_SharedEnvironment must close synchronous setup ownership in a finally block")

	FinallyPos := InStr(Body, "finally")
	FinallyBody := SubStr(Body, FinallyPos, 300)
	OwnerCheck := InStr(FinallyBody, "_WebView_SharedEnvBootPromise == 0")
	ClearGuard := InStr(FinallyBody, "_WebView_SharedEnvCreating := false")
	Assert(OwnerCheck > 0 && ClearGuard > OwnerCheck,
		"the finally block must release the guard only when no asynchronous promise owner survives")
}
Test("webview_utils: synchronous setup failure releases an unowned creation guard (webview-shared-env-reentrancy)",
	_WSERG_AssertGuardClearedInFinally)

global _WSERG_TIMEOUT_SEEN := -1
global _WSERG_FAKE_PROMISE := 0
global _WSERG_CREATE_CALLS := 0

class _WSERG_NeverCompletes {
	SuccessFn := 0
	FailureFn := 0

	onSettled(SuccessFn, FailureFn) {
		this.SuccessFn := SuccessFn
		this.FailureFn := FailureFn
	}

	await(TimeoutMs) {
		global _WSERG_TIMEOUT_SEEN
		_WSERG_TIMEOUT_SEEN := TimeoutMs
		throw TimeoutError("fixture timeout")
	}

	Resolve(Value) {
		this.SuccessFn.Call(Value)
	}
}

_WSERG_CreateNeverCompletes(*) {
	global _WSERG_FAKE_PROMISE, _WSERG_CREATE_CALLS
	_WSERG_CREATE_CALLS += 1
	_WSERG_FAKE_PROMISE := _WSERG_NeverCompletes()
	return _WSERG_FAKE_PROMISE
}

_WSERG_SharedBootHasFiniteDeadline() {
	global _WebView_SharedEnv, _WebView_SharedEnvCreating, _WebView_SharedEnvBootPromise
	global WEBVIEW_SHARED_ENV_BOOT_TIMEOUT_MS, _WSERG_TIMEOUT_SEEN, _WSERG_FAKE_PROMISE
	global _WSERG_CREATE_CALLS
	PreviousEnv := _WebView_SharedEnv
	PreviousCreating := _WebView_SharedEnvCreating
	PreviousPromise := _WebView_SharedEnvBootPromise
	_WebView_SharedEnv := 0
	_WebView_SharedEnvCreating := false
	_WebView_SharedEnvBootPromise := 0
	_WSERG_TIMEOUT_SEEN := -1
	_WSERG_FAKE_PROMISE := 0
	_WSERG_CREATE_CALLS := 0
	TimedOut := false
	try {
		try WebView_SharedEnvironment("fixture-loader", _WSERG_CreateNeverCompletes)
		catch as Err
			TimedOut := Err is TimeoutError
		Assert(TimedOut, "a missing WebView2 completion must propagate a timeout")
		Assert(WEBVIEW_SHARED_ENV_BOOT_TIMEOUT_MS is Integer
			&& WEBVIEW_SHARED_ENV_BOOT_TIMEOUT_MS > 0,
			"the shared environment boot timeout must be a positive named constant")
		AssertEqual(WEBVIEW_SHARED_ENV_BOOT_TIMEOUT_MS, _WSERG_TIMEOUT_SEEN,
			"the actual Promise wait must receive the shared environment boot budget")
		AssertEqual(0, _WebView_SharedEnv,
			"a timed-out environment must never publish a cache entry")
		AssertTrue(_WebView_SharedEnvCreating,
			"a timed-out but live COM operation must retain creation ownership")
		Assert(_WebView_SharedEnvBootPromise == _WSERG_FAKE_PROMISE,
			"the exact timed-out promise must block a duplicate environment boot")
		SecondRefused := false
		try WebView_SharedEnvironment("fixture-loader", _WSERG_CreateNeverCompletes)
		catch
			SecondRefused := true
		Assert(SecondRefused && _WSERG_CREATE_CALLS == 1,
			"a second opener must fail fast without starting another environment")
		ResolvedEnv := {name: "fixture-environment"}
		_WSERG_FAKE_PROMISE.Resolve(ResolvedEnv)
		Assert(_WebView_SharedEnv == ResolvedEnv,
			"a late successful terminal must publish the reusable environment")
		AssertFalse(_WebView_SharedEnvCreating,
			"the real terminal must release shared creation ownership")
		AssertEqual(0, _WebView_SharedEnvBootPromise,
			"the terminal must retire the exact promise owner")
	} finally {
		_WebView_SharedEnv := PreviousEnv
		_WebView_SharedEnvCreating := PreviousCreating
		_WebView_SharedEnvBootPromise := PreviousPromise
	}
}
Test("webview_utils: shared environment boot has a finite deadline "
	. "(webview-shared-env-unbounded-await)",
	_WSERG_SharedBootHasFiniteDeadline)
