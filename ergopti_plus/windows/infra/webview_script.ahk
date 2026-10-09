; infra/webview_script.ahk

; ==============================================================================
; MODULE: WebView Native Script Outcomes
; DESCRIPTION:
; Observe native execution promises without waiting on the AHK keyboard thread.
; Native completion does not certify JavaScript application-level success.
; ==============================================================================

#Requires AutoHotkey v2.0

/**
 * Submit a script and observe both native outcomes without a nested message loop.
 * @param WebView {Object} Exact native target captured by the caller.
 * @param Script {String} JavaScript source; never retained in diagnostics.
 * @param Context {String} Developer-owned operation label, without user content.
 * @param OnSettled {Func|Integer} Optional callback receiving native success.
 *        Callers that mutate UI state must validate their captured owner here.
 * @returns {Boolean} Native submission and observer registration were accepted,
 *          not that the script or its application-level work has succeeded.
 */
WebView_RunScriptAsync(WebView, Script, Context, OnSettled := 0) {
	if !(OnSettled is Integer && OnSettled = 0) && !HasMethod(OnSettled, "Call")
		throw TypeError("WebView script outcome callback must be callable or integer zero")
	Length := StrLen(Script)
	try {
		Pending := WebView.ExecuteScriptAsync(Script)
		Pending.onSettled(
			_WebView_ScriptSettled.Bind(Context, Length, OnSettled, true),
			_WebView_ScriptSettled.Bind(Context, Length, OnSettled, false))
	} catch Any as Err {
		_WebView_ScriptSettled(Context, Length, OnSettled, false, Err)
		return false
	}
	return true
}

_WebView_ScriptSettled(Context, Length, OnSettled, Succeeded, Outcome) {
	if Succeeded
		LoggerDebug("WebViewScript", "{1}: native script call completed (script_length={2}).",
			Context, Length)
	else
		_WebView_ScriptFailure(Context, Length, "native", Outcome)
	if HasMethod(OnSettled, "Call") {
		try OnSettled.Call(Succeeded)
		catch Any as Err
			_WebView_ScriptFailure(Context, Length, "callback", Err)
	}
}

_WebView_ScriptFailure(Context, Length, Phase, Err) {
	; Error messages and extra fields can embed scripts, credentials or page data.
	Code := Err is OSError ? Err.Number : 0
	LoggerError("WebViewScript",
		"{1}: script operation failed (phase={2}, script_length={3}, error_type={4}, code={5}).",
		Context, Phase, Length, Type(Err), Code)
}
