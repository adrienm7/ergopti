; tests/meta/test_text_send_direct_mode_guarded.ahk

; ==============================================================================
; MODULE: TextSend Direct-Mode Guard
; DESCRIPTION:
; Regression guard for TextSend's direct-mode branch (adapters/text_sender.ahk)
; calling _AHK_SendText.Call(Text) with no try/catch — the sole unguarded
; OS-level call in an adapter where every other function wraps its send
; primitive. Currently masked by both production callers' outer guards, but
; the adapter's own convention is that every OS-level call is defensive.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaTextSendDirectModeGuarded() {
	Body := _DriverFuncBody("TextSend")
	Assert(Body != "", "TextSend must exist in adapters/text_sender.ahk")

	CallPos := InStr(Body, "_AHK_SendText.Call(Text)")
	Assert(CallPos > 0, "TextSend's direct-mode branch must still call _AHK_SendText.Call(Text)")

	; The call must be preceded by "try" on its own line (not a bare inline call).
	Before := SubStr(Body, 1, CallPos - 1)
	TryPos := InStr(Before, "try")
	Assert(TryPos > 0, "TextSend's direct-mode SendText call must be wrapped in a try block")

	; A catch clause (and LoggerError) must follow the call.
	After := SubStr(Body, CallPos)
	Assert(InStr(After, "catch") > 0,
		"TextSend's direct-mode SendText call must have a catch clause, not a bare try")
	Assert(InStr(After, "LoggerError") > 0,
		"TextSend's direct-mode SendText failure must be logged via LoggerError")
}
Test("text_sender: TextSend's direct-mode SendText call is wrapped in try/catch + LoggerError", _MetaTextSendDirectModeGuarded)
