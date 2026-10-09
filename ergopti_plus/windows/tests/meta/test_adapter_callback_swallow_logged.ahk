; tests/meta/test_adapter_callback_swallow_logged.ahk

; ==============================================================================
; MODULE: Adapter Callback-Swallow Logging Guard
; DESCRIPTION:
; Regression guard for the 6 bare `try Callback(...)` sites across
; adapters/text_sender.ahk and adapters/http_client.ahk that swallowed a
; throwing completion callback with zero log trace, unlike sibling adapters
; (adapters/shell_runner.ahk's on_done wrapper, adapters/timer_scheduler.ahk's
; _OneShot/_Repeating wrappers), which both log via LoggerError.
;
; Fix: text_sender.ahk's 5 sites now route through a shared
; _TextSenderInvokeCallback helper that wraps the call in try/catch +
; LoggerError; http_client.ahk's single site (HTTPPost) gets an inline
; try/catch + LoggerError. Source-scan style, matching the existing precedent
; in tests/meta/test_gesture_toggle_ui_errors_logged.ahk for the identical
; bug class (bare try silently swallowing a callback exception).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ text_sender.ahk: shared callback helper ================
; ===================================================================
; ===================================================================

_MetaTextSenderCallbackHelperLogs() {
	Body := _DriverFuncBody("_TextSenderInvokeCallback")
	Assert(Body != "", "_TextSenderInvokeCallback must exist in adapters/text_sender.ahk")
	Assert(InStr(Body, "catch"),
		"_TextSenderInvokeCallback must catch a throwing Callback instead of letting it propagate")
	Assert(InStr(Body, "LoggerError"),
		"_TextSenderInvokeCallback must call LoggerError so a throwing Callback leaves a log trace")
}
Test("text_sender: _TextSenderInvokeCallback wraps Callback in try/catch + LoggerError", _MetaTextSenderCallbackHelperLogs)

_MetaTextSenderNoBareCallbackSites() {
	Body1 := _DriverFuncBody("_TextSendClipboard")
	Assert(Body1 != "", "_TextSendClipboard must exist")
	Assert(!InStr(Body1, "try Callback()"),
		"_TextSendClipboard must route every completion callback through _TextSenderInvokeCallback, not a bare try Callback()")

	Occurrences := 0, SearchFrom := 1
	loop {
		Pos := InStr(Body1, "_TextSenderInvokeCallback(Callback", , SearchFrom)
		if !Pos
			break
		Occurrences++
		SearchFrom := Pos + 1
	}
	Assert(Occurrences >= 4,
		"_TextSendClipboard must call the success-aware _TextSenderInvokeCallback at all 4 of its bail-out/completion sites, got " . Occurrences)

	Body2 := _DriverFuncBody("TextSend")
	Assert(Body2 != "", "TextSend must exist")
	Assert(!InStr(Body2, "try Callback()"),
		"TextSend's direct-mode branch must route its completion callback through _TextSenderInvokeCallback, not a bare try Callback()")
	Assert(InStr(Body2, "_TextSenderInvokeCallback(Callback") > 0,
		"TextSend's direct-mode branch must call the success-aware _TextSenderInvokeCallback")
}
Test("text_sender: no bare 'try Callback()' sites remain in _TextSendClipboard/TextSend", _MetaTextSenderNoBareCallbackSites)




; ===================================================================
; ===================================================================
; ======= 2/ http_client.ahk: HTTPPost callback site =================
; ===================================================================
; ===================================================================

_MetaHttpPostCallbackLogged() {
	Body := _DriverFuncBody("HTTPPost")
	Assert(Body != "", "HTTPPost must exist in adapters/http_client.ahk")
	Assert(!InStr(Body, "try Callback(Result)"),
		"HTTPPost must not use a bare 'try Callback(Result)' with no catch")
	Assert(InStr(Body, "Callback(Result)") > 0, "HTTPPost must still invoke Callback(Result)")
	Assert(InStr(Body, "catch") > 0 && InStr(Body, "LoggerError") > 0,
		"HTTPPost's Callback(Result) invocation must be wrapped in try/catch + LoggerError")
}
Test("http_client: HTTPPost's completion callback is wrapped in try/catch + LoggerError", _MetaHttpPostCallbackLogged)
