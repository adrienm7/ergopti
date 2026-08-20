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

_KLPW_AsyncFailureKeepsFailClosedVerdict() {
	global UIA
	hwnd := 0x7FFFFFFF
	UIA := _KLPWTestUia
	_KLPWTestUia.throw_probe := true
	KL_CommitPwCache(hwnd, 41, true)
	KLPasswordCache.pending_hwnd := hwnd

	KL_AsyncPasswordDetect(hwnd)

	AssertTrue(KLPasswordCache.last_val,
		"a failed UIA probe must not turn the conservative password verdict into ordinary text")
	AssertEqual(hwnd, KLPasswordCache.last_hwnd,
		"a failed probe must leave the already-published cache entry intact")
	AssertEqual(0, KLPasswordCache.pending_hwnd,
		"a failed probe must release the scheduler latch so a later retry can run")

	_KLPWTestUia.throw_probe := false
	_KLPWTestElement.secure := false
	KLPasswordCache.pending_hwnd := hwnd
	KL_AsyncPasswordDetect(hwnd)

	AssertFalse(KLPasswordCache.last_val,
		"a conclusive ordinary UIA verdict must be allowed to relax the conservative cache")
	AssertEqual(0, KLPasswordCache.pending_hwnd,
		"a conclusive probe must also release the scheduler latch")
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
