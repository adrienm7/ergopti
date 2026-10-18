; tests/meta/ui/webview/test_webview_bridge_suspend_guard.ahk

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





; ===============================================================================
; ===============================================================================
; ======= 2/ Changelog bridge guards captured pause state before mutating =======
; ===============================================================================
; ===============================================================================

_WBSG_CheckChangelogGuard() {
	Body := _DriverFuncBody("_CLW_OnWebMessage")
	Assert(Body != "", "_CLW_OnWebMessage must exist in ui/changelog/init.ahk")

	CapturePos := InStr(Body, "_Updater_ReadManualBridgeMessage(")
	ReadPos := CapturePos > 0 ? InStr(Body, "TryGetWebMessageAsString()", , CapturePos) : 0
	BornPausedPos := ReadPos > 0 ? InStr(Body, "Request.BornSuspended", , ReadPos) : 0
	PolicyPos := BornPausedPos > 0
		? InStr(Body, "_Updater_RequestMayPublish(Request)", , BornPausedPos)
		: 0
	CallPos := InStr(Body, "_CLW_FetchAndInject(")
	Assert(CallPos > 0, "_CLW_OnWebMessage must still call _CLW_FetchAndInject(...) on a ready/fetch action")
	Assert(CapturePos > 0 and ReadPos > CapturePos and BornPausedPos > ReadPos
		and PolicyPos > BornPausedPos and CallPos > PolicyPos,
		"_CLW_OnWebMessage must capture entry-time pause provenance before its yielding COM read, then reject born-paused or interrupted actions before a fetch mutates channel/network state")
}
Test("changelog: _CLW_OnWebMessage guards captured pause provenance before fetch mutation (webview-bridge-suspend-guard)",
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

; The whole cluster has ONE mechanism behind it: infra/webview_utils.ahk defines a
; WebViewHost factory that handles every documented gotcha correctly — and has
; zero consumers. All 14 windows are hand-rolled copies, so each cross-cutting
; guard was applied only to the sites its regression test happened to name.
;
; These tests are therefore written as CLASS LOOPS over every host, not as
; assertions about the sites that were broken. That shape is the actual fix:
; it makes the next hand-rolled window fail the suite instead of silently
; inheriting the omission.
;
; F-25  Only 2 of 9 WebMessageReceived handlers enforced suspend policy. COM
; callbacks bypass native Suspend, so a paused driver still let a page
; click write config, re-register hotstrings, or (onboarding) launch an
; elevated UAC driver install. Most handlers use a direct guard; the
; updater bridges (changelog, update prompt notes) capture immutable
; AHK-14 provenance before their yielding COM read and revalidate actions
; afterward. Both deliberately exempt `ready`: gating page-lifecycle
; Every WebMessageReceived handler in the driver, DERIVED from source.
;
; This was a hardcoded list of nine names guarded by "Checked >= 9" — an
; assertion that can only ever compare the list against itself, so it was
; tautological. It missed two of the eleven handlers actually registered, which
; is the exact failure this whole file was written to prevent: an invariant
; applied to the sites a list happens to name rather than to the class.
;
; Both registration spellings are matched: the direct
; `.WebMessageReceived(Handler)` form and the `.Bind(...)` form KLWV uses.
_A0720WV_MessageHandlers() {
	Src := _DriverSourceNoComments()
	Seen := Map()
	Out := []
	Pos := 1
	while (Pos := RegExMatch(Src, "WebMessageReceived\(\s*([A-Za-z0-9_]+)", &m, Pos)) {
		Name := m[1]
		; infra/webview_utils.ahk's WebViewHost registers a BOUND METHOD
		; (this._OnWebMessage.Bind(this)), which resolves to the token "this" and
		; has no top-level function body to look up. That factory has zero
		; consumers — every window is a hand-rolled copy, which is the whole
		; reason this file exists — so skipping it loses no coverage.
		if (Name = "this")
			Name := ""
		if (Name != "" and !Seen.Has(Name)) {
			Seen[Name] := true
			Out.Push(Name)
		}
		Pos += StrLen(m[0])
	}
	return Out
}

; The updater bridges (the Versions window and the update prompt's notes pane)
; share one suspend policy instead of a bare A_IsSuspended read: provenance is
; captured before the yielding COM read, and every action is revalidated after it.
_A0720WV_ManualBridgeHasSuspendPolicy(Fn, Body) {
	ReadPos := InStr(Body, "_Updater_ReadManualBridgeMessage(")
	BornPos := InStr(Body, "Request.BornSuspended")
	PolicyPos := InStr(Body, "_Updater_RequestMayPublish(Request)")
	UrlPos := InStr(Body, "_Updater_OpenManualUrl(")
	Assert(ReadPos > 0 and BornPos > ReadPos and PolicyPos > BornPos,
		Fn . " must preserve entry-time suspend provenance across its yielding COM read and revalidate it before actions")
	Assert(UrlPos > PolicyPos,
		Fn . " must apply the shared suspend policy before opening a URL")
	if (Fn == "_CLW_OnWebMessage")
		Assert(InStr(Body, "_CLW_FetchAndInject(") > PolicyPos,
			"_CLW_OnWebMessage must apply the shared suspend policy before every mutating bridge action")

	Reader := _DriverFuncBody("_Updater_ReadManualBridgeMessage")
	Assert(Reader != "",
		"_Updater_ReadManualBridgeMessage must exist — it is the updater bridges' suspend-policy owner")
	CapturePos := InStr(Reader, "_Updater_NewRequestContext(")
	YieldPos := InStr(Reader, "ReadFn.Call()")
	Assert(CapturePos > 0 and YieldPos > CapturePos,
		"the updater bridges must capture AHK-14 provenance before the COM message read can yield")
}

_A0720WV_EveryHandlerIsSuspendGuarded() {
	Checked := 0
	for _, Fn in _A0720WV_MessageHandlers() {
		Body := _DriverFuncBody(Fn)
		Assert(Body != "", Fn . " must exist — if a host was renamed, update this list rather than dropping the handler from the invariant")
		if InStr(Body, "_Updater_ReadManualBridgeMessage(")
			_A0720WV_ManualBridgeHasSuspendPolicy(Fn, Body)
		else
			Assert(InStr(Body, "A_IsSuspended") > 0,
				Fn . " must gate on A_IsSuspended: WebMessageReceived is a COM callback and bypasses native Suspend, which only disarms hotkeys, so a paused driver would still let a page click write config, re-register hotstrings or launch an elevated install")
		Checked += 1
	}
	; A floor, not a tautology: the previous ">= 9" compared a hardcoded list
	; against its own length and could never fail. Twelve handlers are registered
	; today, so a drop below that means a host lost its registration.
	Assert(Checked >= 12,
		"every WebView2 message handler must be covered by this invariant (found " . Checked . ") — the cluster this guards exists precisely because each guard was applied only to the sites its test named")
}
Test("webview: every message handler honours the suspend invariant (F-25)",
	_A0720WV_EveryHandlerIsSuspendGuarded)


; The guard must not swallow page-lifecycle signals. Dropping `ready` is how the
; model browser ended up with a permanently empty table (F-32's class).
_A0720WV_ReadyIsNotGatedAway() {
	for _, Fn in ["_OnbWeb_OnWebMessage", "_HCWWeb_OnWebMessage", "_PathsEdWeb_OnWebMessage"
	            , "_PiEdWeb_OnWebMessage", "_ActPickWeb_OnWebMessage"] {
		Body := _DriverFuncBody(Fn)
		if (Body == "" or InStr(Body, "ready") = 0)
			continue
		Assert(RegExMatch(Body, 'A_IsSuspended\s*&&\s*Action\s*!=\s*"ready"') > 0,
			Fn . " must exempt the `ready` page-lifecycle signal from its suspend guard — gating it strands the SafetyFlush and leaves the page permanently un-initialised, which is a different bug than the one the guard fixes")
	}
}
Test("webview: the suspend guard exempts page-lifecycle signals (F-25)",
	_A0720WV_ReadyIsNotGatedAway)
