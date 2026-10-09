; tests/meta/test_secure_field_native_detect_conclusive_order.ahk

; ==============================================================================
; MODULE: SFD_DetectNative Conclusive-flag Ordering Guard
; DESCRIPTION:
; SFD_DetectNative reports two things: the verdict, and whether that verdict is
; conclusive. It used to set Conclusive := true on the strength of the window
; CLASS alone, and only then evaluate WinGetStyle. The enclosing try had no
; catch, so a control destroyed between the class read and the style read made
; WinGetStyle throw, control fell through to `return false`, and the caller
; received a CONFIDENT "not a password field".
;
; SFD_IsSecureField then skipped its fail-closed branch entirely, never
; scheduled the UIA probe, and cached {secure: false} for a full TTL. Every
; other unknown in this adapter fails closed; that one failed open, and the
; catch-less try meant it produced no log line at any level, so it was
; indistinguishable from a genuine non-password Edit control.
;
; ROOT CAUSE ENCODED: a confidence flag must never be raised before the last
; operation that can fail, and an OS call that throws must not be swallowed
; silently (conventions 5.3). The shipped guard only asserts that the Edit class
; check precedes the ES_PASSWORD bit test, which says nothing about where the
; flag is set relative to the throwing call.
;
; SCOPE: source introspection — the failure window is a few microseconds wide
; and cannot be provoked from a test.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ The flag follows the style read =======
; ==================================================
; ==================================================

_SFNC_ConclusiveIsSetAfterTheStyleRead() {
	Body := _DriverFuncBody("SFD_DetectNative")
	Assert(Body != "", "SFD_DetectNative() must exist")

	StylePos := InStr(Body, "WinGetStyle(")
	ConcPos  := InStr(Body, "Conclusive := true")
	Assert(StylePos > 0, "prerequisite: SFD_DetectNative still classifies via the window style")
	Assert(ConcPos > 0, "prerequisite: SFD_DetectNative still reports a conclusive verdict")
	Assert(InStr(Body, "WinGetStyle(", , StylePos + 1) = 0,
		"the style must be read exactly once, into a variable — a second read after the flag is raised would reopen the same window this guard closes")
	Assert(ConcPos > StylePos,
		"SFD_DetectNative must raise Conclusive only AFTER the style read has succeeded — flagging the verdict conclusive before the one remaining call that can throw turns an OS failure into a confident 'not a password field', and the caller then skips its fail-closed branch and caches that answer for a whole TTL")
}





; =========================================================
; =========================================================
; ======= 2/ The failure is reported, not swallowed =======
; =========================================================
; =========================================================

_SFNC_StyleReadFailureIsNotSwallowed() {
	Body := _DriverFuncBody("SFD_DetectNative")
	Assert(Body != "", "SFD_DetectNative() must exist")

	CatchPos := InStr(Body, "catch as")
	Assert(CatchPos > 0,
		"SFD_DetectNative must not wrap its OS calls in a catch-less try — that made a thrown WinGetClass/WinGetStyle indistinguishable from a genuine non-password control, at any log level (conventions 5.3)")

	Tail := SubStr(Body, CatchPos)
	Assert(InStr(Tail, "Conclusive := false") > 0,
		"the failure path must leave Conclusive false so the caller falls back to fail-closed plus a UIA probe — a verdict obtained from a throw is not a verdict")
	Assert(InStr(Tail, "Logger") > 0,
		"the failure path must log its reason, or a control class that has started failing systematically looks exactly like one that is simply never a password field")
}


Test("meta secure-field: SFD_DetectNative raises Conclusive only after the style read succeeds",
	_SFNC_ConclusiveIsSetAfterTheStyleRead)
Test("meta secure-field: SFD_DetectNative reports a thrown style read instead of swallowing it",
	_SFNC_StyleReadFailureIsNotSwallowed)
