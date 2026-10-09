; tests/meta/test_keylogger_webview_bridge_and_i18n.ahk

; ==============================================================================
; MODULE: Keylogger WebView Bridge + i18n Meta Test (Patterns 4 and 6)
; DESCRIPTION:
; Three independent bugs found in the same file:
;
; 1. (Pattern 4) `webview.WebMessageReceived := handler` is a PROPERTY
;    ASSIGNMENT, not a method call. Vendor WebView2.ahk's base class has no
;    __Set meta-method, so the assignment is a silent no-op and the JS->AHK
;    bridge never actually subscribes -- the "ready" handshake and the
;    Refresh/Clear-cache buttons were permanently dead. The fix calls
;    WebMessageReceived(handler) as a method, matching every other WebView2
;    host in this codebase, and stores the returned subscription handle
;    (not discarded) so AHK's refcounting does not __Delete and
;    unsubscribe it almost immediately.
;
; 2. (Pattern 6) The dashboard window title was hardcoded French text
;    ("Métriques de frappe" / "Temps sur les applications") instead of
;    routed through t(), breaking the window title for any non-French
;    locale user.
;
; 3. KLWV_Open used local monitor-coordinate variable T while also calling
;    the global t() translator. AHK identifiers are case-insensitive, so the
;    local shadowed t() throughout the function and dashboard launch threw
;    before creating the Gui.
;
; SCOPE: source introspection of modules/keylogger/keylogger_webview.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================
; ======================================================
; ======= 1/ WebMessageReceived is a method call =======
; ======================================================
; ======================================================

_KLWVB_CheckMethodCallNotAssignment() {
	Body := _DriverFuncBody("KLWV_Open")
	Assert(Body != "", "KLWV_Open must exist in modules/keylogger/keylogger_webview.ahk")

	Assert(InStr(Body, "webview.WebMessageReceived := ") = 0,
		"KLWV_Open must NOT assign webview.WebMessageReceived as a property -- vendor WebView2.ahk has no __Set meta-method, so the assignment is a silent no-op and the bridge never subscribes")

	Assert(InStr(Body, "webview.WebMessageReceived(") > 0,
		"KLWV_Open must call webview.WebMessageReceived(handler) as a METHOD, matching every other WebView2 host in this codebase")
}
Test("keylogger_webview: WebMessageReceived is subscribed via method call, not property assignment (webview-bridge-property-assignment)",
	_KLWVB_CheckMethodCallNotAssignment)

_KLWVB_CheckSubscriptionNotDiscarded() {
	Body := _DriverFuncBody("KLWV_Open")

	CallPos := InStr(Body, "webview.WebMessageReceived(")
	Assert(CallPos > 0, "webview.WebMessageReceived(...) must be called")

	; The call must not be a bare statement -- its return value (the
	; subscription handle) must be captured, or AHK's refcounting frees it
	; via __Delete almost immediately and silently unsubscribes.
	LineStart := CallPos
	loop {
		if (LineStart <= 1 or SubStr(Body, LineStart, 1) = "`n")
			break
		LineStart--
	}
	Line := Trim(SubStr(Body, LineStart, CallPos - LineStart + 40))
	Assert(InStr(Line, ":=") > 0,
		"KLWV_Open must capture the return value of webview.WebMessageReceived(...) (e.g. msg_sub := ...) -- a bare, uncaptured call lets AHK's refcounting free the subscription almost immediately")

	Assert(InStr(Body, '"msg_sub"') > 0,
		'KLWV_Open must store the WebMessageReceived subscription handle in KLWV.windows[which] (e.g. under "msg_sub") so it stays alive for the life of the window')
}
Test("keylogger_webview: WebMessageReceived subscription handle is captured and persisted, not discarded (webview-bridge-property-assignment)",
	_KLWVB_CheckSubscriptionNotDiscarded)





; =====================================================
; =====================================================
; ======= 2/ Dashboard title routes through t() =======
; =====================================================
; =====================================================

_KLWVB_CheckTitleUsesI18n() {
	Body := _DriverFuncBody("KLWV_Open")

	Assert(InStr(Body, "Métriques de frappe") = 0,
		"KLWV_Open must not hardcode the French dashboard title -- it must route through t() so the window title is correct for non-French locales")
	Assert(InStr(Body, "Temps sur les applications") = 0,
		"KLWV_Open must not hardcode the French dashboard title -- it must route through t() so the window title is correct for non-French locales")

	Assert(InStr(Body, 't("keylogger_ui.typing_metrics")') > 0,
		'KLWV_Open must route the typing-dashboard title through t("keylogger_ui.typing_metrics")')
	Assert(InStr(Body, 't("metrics_apps.window_title")') > 0,
		'KLWV_Open must route the apps-dashboard title through t("metrics_apps.window_title")')
}
Test("keylogger_webview: dashboard window title is routed through t(), not hardcoded French (hardcoded-french-strings)",
	_KLWVB_CheckTitleUsesI18n)

_KLWVB_CheckTranslatorIsNotShadowed() {
	Body := _DriverFuncBody("KLWV_Open")

	Assert(!RegExMatch(Body, "i)\&t\b"),
		"KLWV_Open must not declare a local T output variable while calling global t() -- AHK identifiers are case-insensitive, so the local shadows the translator for the entire function and opening either dashboard throws before the Gui is created")
}
Test("keylogger_webview: monitor coordinates do not shadow the t() translator (local-function-name-shadow)",
	_KLWVB_CheckTranslatorIsNotShadowed)
