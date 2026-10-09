; tests/meta/test_case_transform_synthetic_mark.ahk

; ==============================================================================
; MODULE: Case Transform Synthetic Mark Meta Test
; DESCRIPTION:
; Regression guard ensuring the case-transform injector in
; modules/gestures/actions.ahk marks its output as synthetic before calling
; SendInstant, so the keylogger does not record injected characters as real
; keystrokes that would corrupt ngram statistics, and that the Win+U / Win+W
; shortcuts go through that injector instead of a copy of it.
;
; SCOPE: source introspection of modules/gestures/actions.ahk and
; modules/shortcuts/win.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Test implementations ===================
; ===================================================
; ===================================================

_CTSM_CheckGestures() {
	; The initiating gesture only starts asynchronous selection capture. Pin the
	; injection invariant to its completion callback, the sole place that can
	; call SendInstant after the capture has validated its foreground context.
	Src := _DriverFuncBody("_GestureSendTransformedSelection")
	Assert(Src != "", "_GestureSendTransformedSelection must exist")

	Assert(InStr(Src, 'KL_MarkSynthetic("case-transform")'),
		"the case actions must call KL_MarkSynthetic before SendInstant")
	Assert(InStr(Src, "KL_ClearSynthetic"),
		"the case actions must schedule KL_ClearSynthetic after SendInstant")
}

_CTSM_CheckWinShortcuts() {
	for _, Name in ["ConvertToTitleCase", "ConvertToUppercase"] {
		Src := _DriverFuncBody(Name)
		Assert(Src != "", Name . " must exist")
		Assert(InStr(Src, "GestureTransformSelection("),
			Name . " must go through the marked case-action injector, not a copy of it")
	}
}


Test("meta case-transform: gestures.ahk marks output as synthetic",
	_CTSM_CheckGestures)

Test("meta case-transform: shortcuts/win.ahk reuses the marked injector",
	_CTSM_CheckWinShortcuts)
