; tests/unit/test_keylogger_password_fail_closed.ahk

; ==============================================================================
; MODULE: Keylogger Password Probe Fail-Closed Tests
; DESCRIPTION:
; A deferred UIA probe begins from a conservative password verdict. UIA being
; unavailable is not evidence that the control is ordinary, so a failed probe
; must leave that verdict in place. Only a conclusive UIA response may relax it.
; ==============================================================================

class _KLPWTestElement {
	static secure := false
	RuntimeId := "test:focused-element"

	GetCurrentPropertyValue(*) {
		return _KLPWTestElement.secure
	}
}

class _KLPWTestUia {
	static Property := {IsPassword: 30019}
	static throw_probe := true

	static GetFocusedElement() {
		if _KLPWTestUia.throw_probe
			throw Error("injected UIA failure")
		return _KLPWTestElement()
	}
}

_KLPW_CacheSnapshot() {
	return Map(
		"last_hwnd", KLPasswordCache.last_hwnd,
		"last_at", KLPasswordCache.last_at,
		"last_val", KLPasswordCache.last_val,
		"last_focus_generation", KLPasswordCache.last_focus_generation,
		"last_element_id", KLPasswordCache.last_element_id,
		"generation", KLPasswordCache.generation,
		"pending_hwnd", KLPasswordCache.pending_hwnd,
		"pending_focus_generation", KLPasswordCache.pending_focus_generation,
		"focus_generation", KLPasswordCache.focus_generation,
		"current_element_id", KLPasswordCache.current_element_id,
		"focus_tracking_active", KLPasswordCache.focus_tracking_active)
}

_KLPW_RestoreCache(Snapshot) {
	KLPasswordCache.last_val := Snapshot["last_val"]
	KLPasswordCache.last_at := Snapshot["last_at"]
	KLPasswordCache.last_focus_generation := Snapshot["last_focus_generation"]
	KLPasswordCache.last_element_id := Snapshot["last_element_id"]
	KLPasswordCache.generation := Snapshot["generation"]
	KLPasswordCache.pending_hwnd := Snapshot["pending_hwnd"]
	KLPasswordCache.pending_focus_generation := Snapshot["pending_focus_generation"]
	KLPasswordCache.focus_generation := Snapshot["focus_generation"]
	KLPasswordCache.current_element_id := Snapshot["current_element_id"]
	KLPasswordCache.focus_tracking_active := Snapshot["focus_tracking_active"]
	KLPasswordCache.last_hwnd := Snapshot["last_hwnd"]
}

_KLPW_AsyncFailureKeepsFailClosedVerdict() {
	SavedCache := _KLPW_CacheSnapshot()
	hwnd := 0x7FFFFFFF
	try {
		KL_CommitPwCache(hwnd, 41, true)
		FocusGeneration := KLPasswordCache.focus_generation
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := FocusGeneration
		Context := Map("Hwnd", 501, "Control", hwnd,
			"InputEpoch", 601, "ProcName", "test.exe")
		CurrentContext := (*) => Context
		CurrentHwnd := (*) => hwnd

		KL_OnPasswordWorkerTerminal(hwnd, FocusGeneration, CurrentHwnd,
			CurrentContext, "failed", Context,
			Map("Status", "failed", "Hwnd", 501, "Control", hwnd,
				"Text", "injected UIA failure"))

		AssertTrue(KLPasswordCache.last_val,
			"a failed UIA probe must not turn the conservative password verdict into ordinary text")
		AssertEqual(hwnd, KLPasswordCache.last_hwnd,
			"a failed probe must leave the already-published cache entry intact")
		AssertEqual(0, KLPasswordCache.pending_hwnd,
			"a failed probe must release the scheduler latch so a later retry can run")

		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := FocusGeneration
		KL_OnPasswordWorkerTerminal(hwnd, FocusGeneration, CurrentHwnd,
			CurrentContext, "ok", Context,
			Map("Status", "ok", "Hwnd", 501, "Control", hwnd,
				"Text", "0`ntest:focused-element"))

		AssertFalse(KLPasswordCache.last_val,
			"a conclusive ordinary UIA verdict must be allowed to relax the conservative cache")
		AssertEqual(0, KLPasswordCache.pending_hwnd,
			"a conclusive probe must also release the scheduler latch")
	} finally {
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: UIA failure stays fail closed (password-uia-failure-fail-closed)",
	_KLPW_AsyncFailureKeepsFailClosedVerdict)

_KLPW_InconclusiveFieldUsesWorker() {
	AsyncBody := _DriverFuncBody("KL_AsyncPasswordDetect")
	Assert(AsyncBody != "" && InStr(AsyncBody, "UIASW_RequestPassword") > 0,
		"the inconclusive native path must delegate to the password worker")
	Assert(InStr(AsyncBody, "UIA.") = 0,
		"the resident async dispatcher must never touch the unsafe UIA provider")
	WorkerBody := _DriverFuncBody("UIASW_WorkerHandleRequest")
	Assert(WorkerBody != "" && InStr(WorkerBody, "UIA.GetFocusedElement") > 0
		&& InStr(WorkerBody, "UIA.Property.IsPassword") > 0,
		"the disposable worker must retain the focused-element IsPassword probe")
}
Test("Keylogger password: inconclusive fields reach UIA only in the worker (password-inconclusive-uia-worker)",
	_KLPW_InconclusiveFieldUsesWorker)

_KLPW_SameHostElementTransitionInvalidatesSafeVerdict() {
	CachedVerdictName := "KL_PwCachedVerdict"
	AssertTrue(IsSet(%CachedVerdictName%),
		"the password cache must expose its exact focused-element lookup")
	if !IsSet(%CachedVerdictName%)
		return
	CachedVerdict := %CachedVerdictName%
	CommitVerdict := KL_CommitPwCache
	SavedCache := _KLPW_CacheSnapshot()
	KLPasswordCache.focus_tracking_active := true
	hwnd := 0x6F000001
	try {
		for Surface in ["native", "chromium", "wpf"] {
			NormalElement := Surface . ":normal"
			PasswordElement := Surface . ":password"
			FocusGeneration := 70
			CommitVerdict(hwnd, A_TickCount, false, FocusGeneration, NormalElement)

			Fresh := CachedVerdict(hwnd, FocusGeneration, NormalElement)
			AssertTrue(Fresh.Get("known", false),
				Surface . " must reuse a fresh verdict only for the exact focused element")
			AssertFalse(Fresh.Get("secure", true),
				Surface . " normal element must retain its conclusive ordinary verdict")

			Moved := CachedVerdict(hwnd, FocusGeneration + 1, PasswordElement)
			AssertFalse(Moved.Get("known", true),
				Surface . " focus transition inside one HWND must invalidate the ordinary verdict")
			AssertTrue(Moved.Get("secure", false),
				Surface . " element mismatch must fail closed until the new element is probed")
		}
	} finally {
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: same-host element transitions invalidate fresh safe verdicts (audit-ahk-003-element-cache-key)",
	_KLPW_SameHostElementTransitionInvalidatesSafeVerdict)

_KLPW_StaleAsyncProbeCannotPublishAcrossFocusChange() {
	SavedCache := _KLPW_CacheSnapshot()
	hwnd := 0x6F000002
	try {
		KLPasswordCache.focus_tracking_active := true
		KLPasswordCache.focus_generation := 120
		KL_CommitPwCache(hwnd, A_TickCount, false, 120, "chromium:normal")
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := 120
		Context := Map("Hwnd", 502, "Control", hwnd,
			"InputEpoch", 602, "ProcName", "test.exe")

		KL_InvalidatePasswordFocus()
		KL_OnPasswordWorkerTerminal(hwnd, 120, (*) => hwnd, (*) => Context,
			"ok", Context, Map("Status", "ok", "Hwnd", 502,
				"Control", hwnd, "Text", "0`nchromium:normal"))

		AssertEqual(120, KLPasswordCache.last_focus_generation,
			"a probe owned by the previous element must not publish into the new focus generation")
		Current := KL_PasswordFocusSnapshot()
		Verdict := KL_PwCachedVerdict(hwnd, Current.Generation, Current.ElementId)
		AssertFalse(Verdict.Get("known", true),
			"the new focused element must remain unknown after a stale ordinary probe")
		AssertTrue(Verdict.Get("secure", false),
			"the stale-probe window must remain fail closed")
	} finally {
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: stale async verdict cannot cross a same-host focus change (audit-ahk-003-stale-probe)",
	_KLPW_StaleAsyncProbeCannotPublishAcrossFocusChange)

_KLPW_MissingFocusTrackerRejectsNegativeCache() {
	SavedCache := _KLPW_CacheSnapshot()
	hwnd := 0x6F000003
	try {
		KLPasswordCache.focus_tracking_active := false
		KL_CommitPwCache(hwnd, A_TickCount, false, 140, "wpf:normal")
		Verdict := KL_PwCachedVerdict(hwnd, 140, "wpf:normal")
		AssertFalse(Verdict.Get("known", true),
			"an ordinary verdict is unusable when focus tracking is unavailable")
		AssertTrue(Verdict.Get("secure", false),
			"focus-hook failure must degrade to secure, never to an HWND-wide safe cache")
	} finally {
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: missing focus invalidator rejects negative cache hits (audit-ahk-003-hook-fail-closed)",
	_KLPW_MissingFocusTrackerRejectsNegativeCache)

global _KLPW_WorkerRequest := 0

_KLPW_WorkerContext() {
	return Map(
		"Hwnd", 701,
		"Control", 702,
		"InputEpoch", 703,
		"ProcName", "provider.exe")
}

_KLPW_CaptureWorkerRequest(Context, OnTerminal) {
	global _KLPW_WorkerRequest
	_KLPW_WorkerRequest := Map("context", Context, "terminal", OnTerminal)
	return true
}

_KLPW_ResidentProbeDelegatesToDisposableWorker() {
	global UIA, _KLPW_WorkerRequest
	HadUia := IsSet(UIA)
	if HadUia
		SavedUia := UIA
	SavedCache := _KLPW_CacheSnapshot()
	Hwnd := 702
	try {
		; Any resident UIA touch would throw. The dispatcher must only post a
		; request; the disposable worker owns the unsafe COM object.
		UIA := _KLPWTestUia
		_KLPWTestUia.throw_probe := true
		_KLPW_WorkerRequest := 0
		KLPasswordCache.focus_tracking_active := true
		KLPasswordCache.focus_generation := 211
		KLPasswordCache.pending_hwnd := Hwnd
		KLPasswordCache.pending_focus_generation := 211

		AsyncDetect := KL_AsyncPasswordDetect
		AssertTrue(AsyncDetect.Call(Hwnd, 211, (*) => Hwnd,
			_KLPW_WorkerContext, _KLPW_CaptureWorkerRequest, (*) => true),
			"the resident password detector must dispatch to the disposable UIA worker")
		AssertTrue(_KLPW_WorkerRequest is Map,
			"the worker request and terminal owner must be captured")
		AssertEqual(Hwnd, KLPasswordCache.pending_hwnd,
			"accepted worker ownership must retain the dedupe latch until its terminal")

		Request := _KLPW_WorkerRequest
		Request["terminal"].Call("ok", Request["context"], Map(
			"Status", "ok",
			"Hwnd", 701,
			"Control", 702,
			"Text", "0`nprovider:normal"))
		AssertFalse(KLPasswordCache.last_val,
			"a context-matched worker verdict may relax the fail-closed cache")
		AssertEqual("provider:normal", KLPasswordCache.last_element_id,
			"the worker's focused-element identity must own the cached verdict")
		AssertEqual(0, KLPasswordCache.pending_hwnd,
			"the exact worker terminal must release the scheduler latch")
	} finally {
		_KLPW_WorkerRequest := 0
		if HadUia
			UIA := SavedUia
		else
			UIA := unset
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: UIA faults stay inside the disposable worker (password-uia-process-isolation)",
	_KLPW_ResidentProbeDelegatesToDisposableWorker)
