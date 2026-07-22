; tests/meta/test_webview_bridge_suspend_guard.ahk

; ==============================================================================
; MODULE: WebView2 Message Bridge Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard for finding F29: _LLM_MBW_OnWebMessage (model browser) and
; _CLW_OnWebMessage (changelog) are WebMessageReceived COM callbacks, which
; bypass native Suspend() entirely -- same exposure class as the async updater
; callbacks guarded by test_updater_callback_suspend_guard.ahk. Without an
; explicit A_IsSuspended check, a paused driver would still let the
; model-browser bridge's select_model action write config and mutate the live
; LLM engine (LLM_Menu_SetModel), and let the changelog bridge's fetch action
; dispatch a network request and mutate module state -- violating the
; "pause = tout éteint" invariant.
;
; SCOPE: source introspection of ui/model_browser/init.ahk and
; ui/changelog/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================================================
; ======================================================================
; ======= 1/ Model browser bridge guards A_IsSuspended before mutating =
; ======================================================================
; ======================================================================

_WBSG_CheckModelBrowserGuard() {
	Body := _DriverFuncBody("_LLM_MBW_OnWebMessage")
	Assert(Body != "", "_LLM_MBW_OnWebMessage must exist in ui/model_browser/init.ahk")

	SuspendPos := InStr(Body, "A_IsSuspended")
	Assert(SuspendPos > 0,
		"_LLM_MBW_OnWebMessage must check A_IsSuspended -- WebMessageReceived is a COM callback that bypasses native Suspend (webview-bridge-suspend-guard)")

	; The model application moved OUT of this handler in F-27: doing it inline
	; released the WebMessageReceived subscription that was still dispatching and
	; then destroyed the host window, an uncatchable access-violation class. The
	; invariant is unchanged — a paused driver must not mutate the live LLM
	; config/engine — so it is re-encoded across the handler AND its deferred
	; continuation rather than dropped.
	CallPos := InStr(Body, "_LLM_MBW_ApplyModel")
	Assert(CallPos > 0,
		"_LLM_MBW_OnWebMessage must still dispatch a select_model action, now via the deferred _LLM_MBW_ApplyModel hand-off")
	Assert(SuspendPos < CallPos,
		"_LLM_MBW_OnWebMessage: the A_IsSuspended guard must precede the select_model dispatch, otherwise a paused driver still mutates the live LLM config/engine (webview-bridge-suspend-guard)")

	Apply := _DriverFuncBody("_LLM_MBW_ApplyModel")
	Assert(Apply != "", "_LLM_MBW_ApplyModel must exist — it is where the select_model action now lands")
	Assert(InStr(Apply, "LLM_Menu_SetModel(") > 0,
		"_LLM_MBW_ApplyModel must call LLM_Menu_SetModel(...) — moving the call out of the COM callback must not lose it")
	Assert(InStr(Apply, "_LLM_MBW_OnClose(") > 0,
		"_LLM_MBW_ApplyModel must close the browser before applying the model, preserving the original ordering")
}
Test("model browser: _LLM_MBW_OnWebMessage guards A_IsSuspended before select_model mutates config/engine (webview-bridge-suspend-guard)",
	_WBSG_CheckModelBrowserGuard)





; ========================================================================
; ========================================================================
; ======= 2/ Changelog bridge guards A_IsSuspended before mutating =======
; ========================================================================
; ========================================================================

_WBSG_CheckChangelogGuard() {
	Body := _DriverFuncBody("_CLW_OnWebMessage")
	Assert(Body != "", "_CLW_OnWebMessage must exist in ui/changelog/init.ahk")

	SuspendPos := InStr(Body, "A_IsSuspended")
	Assert(SuspendPos > 0,
		"_CLW_OnWebMessage must check A_IsSuspended -- WebMessageReceived is a COM callback that bypasses native Suspend (webview-bridge-suspend-guard)")

	CallPos := InStr(Body, "_CLW_FetchAndInject(")
	Assert(CallPos > 0, "_CLW_OnWebMessage must still call _CLW_FetchAndInject(...) on a ready/fetch action")
	Assert(SuspendPos < CallPos,
		"_CLW_OnWebMessage: A_IsSuspended guard must precede the first _CLW_FetchAndInject(...) call, otherwise a paused driver still dispatches a network fetch and mutates module state (webview-bridge-suspend-guard)")
}
Test("changelog: _CLW_OnWebMessage guards A_IsSuspended before fetch mutates channel/network state (webview-bridge-suspend-guard)",
	_WBSG_CheckChangelogGuard)

_WBSG_CheckKeyloggerGuard() {
	Body := _DriverFuncBody("KLWV_OnWebMessage")
	Assert(Body != "", "KLWV_OnWebMessage must exist in modules/keylogger/keylogger_webview.ahk")
	SuspendPos := InStr(Body, "A_IsSuspended")
	BuildPos := InStr(Body, "KLPF_RequestBuild(")
	Assert(SuspendPos > 0 && BuildPos > SuspendPos,
		"KLWV_OnWebMessage must reject suspended WebMessages before Refresh/Clear can launch keylogger projection workers")
}
Test("keylogger WebView: paused messages cannot rebuild metrics", _WBSG_CheckKeyloggerGuard)
