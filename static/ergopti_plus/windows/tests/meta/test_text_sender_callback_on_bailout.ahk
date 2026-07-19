; tests/meta/test_text_sender_callback_on_bailout.ahk

; ==============================================================================
; MODULE: TextSend Clipboard Callback-On-Bailout Meta Test
; DESCRIPTION:
; Regression guard: _TextSendClipboard's early bail-outs (A_IsSuspended,
; ClipWait timeout, superseded-generation guard) used to return without
; invoking the caller's Callback. Callers such as modules/keymap/llm_bridge.ahk's
; _InjectCallback own depth-counter guards (PrefixWatcherSuppress/
; KL_MarkSynthetic) released exactly once, by the callback, on any path where
; TextSend itself did not throw -- its own finally block only releases the
; guards when TextSend THREW, on the theory that the callback always
; eventually fires on any non-throwing path. A bail-out that skipped the
; callback left those depth counters permanently incremented, permanently
; suppressing normal hotstring/keylogger observation.
;
; SCOPE: source introspection of adapters/text_sender.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Every bail-out invokes Callback ==================
; ============================================================
; ============================================================

_TSCB_CheckBailoutInvokesCallback(Needle, Label) {
	Body := _DriverFuncBody("_TextSendClipboard")
	Assert(Body != "", "_TextSendClipboard must exist in adapters/text_sender.ahk")

	BailPos := InStr(Body, Needle)
	Assert(BailPos > 0, Label . ": expected bail-out marker not found in _TextSendClipboard")

	; The nearest "return" after the bail-out marker must be preceded by a
	; Callback invocation within the same short window.
	; The status-aware callback includes an explicit error string, so retain a
	; sufficiently local but non-fragile window for the complete bail-out.
	Window := SubStr(Body, BailPos, 450)
	ReturnPos := InStr(Window, "return")
	Assert(ReturnPos > 0, Label . ": bail-out must still return")

	; Routed through _TextSenderInvokeCallback (bare-try-anti-pattern / F52b
	; fix) instead of a raw "Callback()" call -- that helper is still the
	; thing that ultimately calls Callback().
	CallbackPos := InStr(Window, "_TextSenderInvokeCallback(Callback")
	Assert(CallbackPos > 0,
		Label . ": _TextSendClipboard must invoke the success-aware _TextSenderInvokeCallback on this bail-out path -- otherwise a caller whose cleanup depends on the callback (e.g. llm_bridge.ahk's depth-counter guards) leaks forever")
	Assert(CallbackPos < ReturnPos,
		Label . ": _TextSenderInvokeCallback must be invoked BEFORE the return, not after")
}

Test("text_sender: A_IsSuspended bail-out invokes Callback before returning (textsend-callback-leaked-on-bailout)",
	() => _TSCB_CheckBailoutInvokesCallback("if A_IsSuspended {", "A_IsSuspended bail-out"))

Test("text_sender: ClipWait timeout bail-out invokes Callback before returning (textsend-callback-leaked-on-bailout)",
	() => _TSCB_CheckBailoutInvokesCallback("did not settle within", "ClipWait timeout bail-out"))

Test("text_sender: superseded-generation bail-out invokes Callback before returning (textsend-callback-leaked-on-bailout)",
	() => _TSCB_CheckBailoutInvokesCallback("Generation != _TEXT_CLIPBOARD_GENERATION", "superseded-generation bail-out"))
