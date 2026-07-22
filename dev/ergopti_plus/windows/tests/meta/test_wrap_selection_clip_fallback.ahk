; tests/meta/test_wrap_selection_clip_fallback.ahk

; ==============================================================================
; MODULE: WrapTextIfSelected degrades to the plain symbol on clipboard failure
; DESCRIPTION:
; When a selection exists, WrapTextIfSelected calls SendInstant to replace it with
; LeftSymbol+Selection+RightSymbol. SendInstant returns false (and emits nothing)
; when its clipboard path fails — another process holding the clipboard open
; mid-transaction. The old code ignored the return and returned, so the pressed key
; was consumed and NOTHING appeared on screen. A clipboard failure must degrade to
; emitting the bare symbol (the selection is untouched since ^v never fired), exactly
; like the no-selection path. (F27, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_WSF_ClipFailDegradesToPlainSymbol() {
	Body := _DriverFuncBody("WrapTextIfSelected")
	Assert(Body != "", "WrapTextIfSelected must exist in modules/keymap/layout.ahk")

	GuardPos := InStr(Body, "if !SendInstant(")
	Assert(GuardPos > 0,
		"WrapTextIfSelected must check SendInstant's return value so a failed clipboard wrap does not swallow the keystroke")
	FallbackPos := InStr(Body, "SendNewResult(Symbol)", , GuardPos)
	Assert(FallbackPos > GuardPos,
		"a SendInstant failure must degrade to SendNewResult(Symbol) (the bare symbol), never to silence")
}
Test("keymap: WrapTextIfSelected degrades to the plain symbol when the clipboard wrap fails",
	_WSF_ClipFailDegradesToPlainSymbol)
