; static/ergopti_plus/windows/tests/meta/test_onboarding_gesture_result_token.ahk

; ==============================================================================
; MODULE: Onboarding Gesture Result-Token Meta Test
; DESCRIPTION:
; Guard for finding F-23 (audit 2026-07-20 second pass).
;
; _Onboarding_ReadGestureAutoResult opened with `if (Result = false)`, where
; Result is FSRead's String|false return. In AHK v2 `=` compares NUMERICALLY
; whenever one side is a number and the other a numeric string, and `false` is
; the integer 0 — so the worker's SUCCESS token "0" satisfied `Result = false`
; and every successful gesture auto-registration was swallowed as "result
; missing". The wizard then painted onboarding.gestures.register_failed and told
; the user to register manually, after the registry writes and PnP cycle had
; already succeeded. `Result != "0"` two lines below proved the contradiction:
; the same literal meant "file missing" on one line and "success" on the next.
;
; Only the SUCCESS path misreported ("1" = false is false), and the log said
; "result missing", pointing any debugger at file I/O rather than at the
; comparison — which is why it survived.
;
; ROOT CAUSE pinned here: a String|false result must be discriminated by TYPE,
; never by value-comparison against false. Note `==` does NOT fix it — it is
; numeric-equal in this situation too, so the test rejects both spellings.
; ==============================================================================

#Requires AutoHotkey v2.0






; ==================================================================
; ==================================================================
; ======= 1/ The reader must type-check, never compare to false ====
; ==================================================================
; ==================================================================

_OGRT_ReaderTypeChecks() {
	Body := _DriverFuncBody("_Onboarding_ReadGestureAutoResult")
	Assert(Body != "", "_Onboarding_ReadGestureAutoResult must exist in ui/onboarding/steps_metrics.ahk")

	Assert(InStr(Body, "is String") > 0,
		"_Onboarding_ReadGestureAutoResult must discriminate FSRead's String|false result by TYPE (`is String`) — the success token is the numeric string 0, and AHK v2 compares numerically, so any value-comparison against false swallows success as failure")

	Assert(RegExMatch(Body, "Result\s*==?\s*false") = 0,
		"_Onboarding_ReadGestureAutoResult must not compare Result against false with `=` or `==` — both are numeric-equal here, so 0 = false is TRUE and a successful registration reads as a missing result file")
}
Test("onboarding: the gesture auto-config reader type-checks its result (F-23)", _OGRT_ReaderTypeChecks)






; ==============================================================
; ==============================================================
; ======= 2/ The success token is a named constant =============
; ==============================================================
; ==============================================================

; §5.1: the token is not self-evident — its numeric-string nature is exactly
; what caused the bug — so it must be named rather than repeated as a literal.
_OGRT_SuccessTokenIsNamed() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "GESTURE_AUTO_SUCCESS_TOKEN") > 0,
		"the gesture auto-config success token must be a named constant (GESTURE_AUTO_SUCCESS_TOKEN), so its numeric-string nature is greppable rather than an inline 0")

	Body := _DriverFuncBody("_Onboarding_ReadGestureAutoResult")
	Assert(InStr(Body, "GESTURE_AUTO_SUCCESS_TOKEN") > 0,
		"_Onboarding_ReadGestureAutoResult must compare against the named token constant")
}
Test("onboarding: the gesture success token is a named constant (F-23)", _OGRT_SuccessTokenIsNamed)






; ==================================================================
; ==================================================================
; ======= 3/ AHK v2 numeric coercion behaves as documented =========
; ==================================================================
; ==================================================================

; Behavioural anchor for the whole finding. If a future AHK release ever changed
; this coercion the fix above would become unnecessary — this test records the
; language behaviour the fix depends on, so the reason survives.
_OGRT_NumericCoercionIsReal() {
	Zero := "0"
	Assert(Zero = false,
		"AHK v2 must still compare a numeric string against false NUMERICALLY — this is the language behaviour that made the original `if (Result = false)` swallow the success token")
	Assert(Zero is String,
		"a numeric string is still a String, so `is String` correctly distinguishes it from FSRead's integer false")
	One := "1"
	Assert(!(One = false),
		"the failure token 1 never satisfied the false comparison — which is why only the SUCCESS path misreported and the bug survived testing")
}
Test("onboarding: AHK v2 numeric-string coercion against false (F-23 root cause)", _OGRT_NumericCoercionIsReal)
