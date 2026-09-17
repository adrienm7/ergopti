; modules/keylogger/keylogger_webview_range_script.ahk

; ==============================================================================
; MODULE: WebView Range Consumption Script
; DESCRIPTION: Acknowledge the exact stage after the asynchronous read settles.
; ==============================================================================

#Requires AutoHotkey v2.0

KLWV_BuildRangeScript(Url, RequestId, Token) {
	return "fetch(" . JsonStringLiteral(Url) . ").then(r=>r.json()).then(p=>window.receive_range_data(p," . RequestId
		. ")).catch(()=>window.complete_range_request(" . RequestId . ",'failed'))"
		. ".finally(()=>{try{window.chrome.webview.postMessage(JSON.stringify({action:'range_consumed',token:"
		. JsonStringLiteral(Token) . "}));}catch{console.warn('Range consumption acknowledgement failed.');}});"
}
