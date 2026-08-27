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
	global UIA
	HadUia := IsSet(UIA)
	if HadUia
		SavedUia := UIA
	SavedCache := _KLPW_CacheSnapshot()
	hwnd := 0x7FFFFFFF
	try {
		UIA := _KLPWTestUia
		_KLPWTestUia.throw_probe := true
		KL_CommitPwCache(hwnd, 41, true)
		FocusGeneration := KLPasswordCache.focus_generation
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := FocusGeneration

		KL_AsyncPasswordDetect(hwnd, FocusGeneration, (*) => hwnd)

		AssertTrue(KLPasswordCache.last_val,
			"a failed UIA probe must not turn the conservative password verdict into ordinary text")
		AssertEqual(hwnd, KLPasswordCache.last_hwnd,
			"a failed probe must leave the already-published cache entry intact")
		AssertEqual(0, KLPasswordCache.pending_hwnd,
			"a failed probe must release the scheduler latch so a later retry can run")

		_KLPWTestUia.throw_probe := false
		_KLPWTestElement.secure := false
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := FocusGeneration
		KL_AsyncPasswordDetect(hwnd, FocusGeneration, (*) => hwnd)

		AssertFalse(KLPasswordCache.last_val,
			"a conclusive ordinary UIA verdict must be allowed to relax the conservative cache")
		AssertEqual(0, KLPasswordCache.pending_hwnd,
			"a conclusive probe must also release the scheduler latch")
	} finally {
		if HadUia
			UIA := SavedUia
		else
			UIA := unset
		_KLPW_RestoreCache(SavedCache)
	}
}
Test("Keylogger password: UIA failure stays fail closed (password-uia-failure-fail-closed)",
	_KLPW_AsyncFailureKeepsFailClosedVerdict)

_KLPW_PlainEditStillFallsThroughToUia() {
	DetectBody := _DriverFuncBody("KL_DetectPasswordFor")
	Assert(DetectBody != "", "KL_DetectPasswordFor must remain reachable")
	UiaPos := InStr(DetectBody, "UIA.GetFocusedElement")
	Assert(UiaPos > 0, "the full detector must retain its focused-element UIA layer")
	NativeBody := SubStr(DetectBody, 1, UiaPos)
	Assert(InStr(NativeBody, "(style & 0x20) ? true : false") = 0,
		"a plain Edit without ES_PASSWORD is inconclusive here and must fall through to UIA")

	HelperBody := _DriverFuncBody("KL_PwFullNativeVerdict")
	Assert(HelperBody != "",
		"the full detector needs a headless-testable native verdict helper")
	Plain := KL_PwFullNativeVerdict("Edit", 0)
	AssertFalse(Plain.Get("known", true),
		"absence of ES_PASSWORD must not become a conclusive ordinary verdict before UIA")
	Secure := KL_PwFullNativeVerdict("Edit", 0x20)
	AssertTrue(Secure.Get("known", false) && Secure.Get("secure", false),
		"ES_PASSWORD remains a conclusive secure verdict without UIA")
}
Test("Keylogger password: plain Edit still reaches UIA (password-plain-edit-uia-fallthrough)",
	_KLPW_PlainEditStillFallsThroughToUia)

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
	global UIA
	SavedCache := _KLPW_CacheSnapshot()
	HadUia := IsSet(UIA)
	if HadUia
		SavedUia := UIA
	hwnd := 0x6F000002
	try {
		UIA := _KLPWTestUia
		_KLPWTestUia.throw_probe := false
		_KLPWTestElement.secure := false
		KLPasswordCache.focus_tracking_active := true
		KLPasswordCache.focus_generation := 120
		KL_CommitPwCache(hwnd, A_TickCount, false, 120, "chromium:normal")
		KLPasswordCache.pending_hwnd := hwnd
		KLPasswordCache.pending_focus_generation := 120

		KL_InvalidatePasswordFocus()
		KL_AsyncPasswordDetect(hwnd, 120, (*) => hwnd)

		AssertEqual(120, KLPasswordCache.last_focus_generation,
			"a probe owned by the previous element must not publish into the new focus generation")
		Current := KL_PasswordFocusSnapshot()
		Verdict := KL_PwCachedVerdict(hwnd, Current.Generation, Current.ElementId)
		AssertFalse(Verdict.Get("known", true),
			"the new focused element must remain unknown after a stale ordinary probe")
		AssertTrue(Verdict.Get("secure", false),
			"the stale-probe window must remain fail closed")
	} finally {
		if HadUia
			UIA := SavedUia
		else
			UIA := unset
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
