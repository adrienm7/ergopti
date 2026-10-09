; tests/meta/test_healthcheck_singleton_destroys_window.ahk

; ==============================================================================
; MODULE: Regression — the healthcheck singleton must destroy the previous window
;         (healthcheck-singleton-destroys-window)
; DESCRIPTION:
; HealthCheck_ShowWindow calls _HC_Close() under the comment "Close any previous
; singleton before opening a new one". _HC_Close only ever called _HC_Reset(),
; which closes the WebView2 CONTROLLER. The host Gui was a function-local that no
; global held — Gui_Create just returns Gui(...) and registers nothing — so
; nothing could destroy it.
;
; ROOT CAUSE ENCODED: the singleton bookkeeping was split in half. The controller
; handles lived in module globals, the window did not, and _HC_Close was written
; to "close the singleton" while only having access to the half that was global.
; Each menu click therefore left another window on screen showing a dead blank
; pane. Worse, every successful WebView2 create re-arms _HC_ResetDone, so closing
; one of those stale windows ran _HC_Reset again and closed the LIVE controller of
; the window the user was actually reading.
;
; SCOPE: source-level — the healthcheck window is outside the headless include
; graph (it builds a Gui and spins up WebView2 at open time).
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The window is reachable from module scope =============
; ==================================================================
; ==================================================================

_HCSW_HostGuiIsPublished() {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, "m)^global\s+_HC_Gui\b") > 0,
		"the healthcheck host window must live in a module-level global — while it was a function-local, no later call could reach it and 'close the previous singleton' had nothing to close")

	Body := _DriverFuncBody("HealthCheck_ShowWindow")
	Assert(Body != "", "HealthCheck_ShowWindow must exist in the driver source")
	Assert(RegExMatch(Body, "_HC_Gui\s*:=\s*G\b") > 0,
		"HealthCheck_ShowWindow must publish its Gui into _HC_Gui — declaring the global without assigning it leaves _HC_Close exactly as blind as before")
}
Test("meta healthcheck-singleton: the host window is published in a module global",
	_HCSW_HostGuiIsPublished)





; ==================================================================
; ==================================================================
; ======= 2/ Closing the singleton closes BOTH halves ==============
; ==================================================================
; ==================================================================

_HCSW_CloseDestroysTheWindow() {
	Body := _DriverFuncBody("_HC_Close")
	Assert(Body != "", "_HC_Close must exist in the driver source")

	Assert(InStr(Body, "_HC_Gui") > 0,
		"_HC_Close must reach the host window, not just the controller — closing the controller alone leaves the previous window on screen with a dead blank pane while a second one opens on top")
	DestroyPos := InStr(Body, ".Destroy()")
	Assert(DestroyPos > 0,
		"_HC_Close must Destroy() the previous window: it is the only thing that removes it from the screen")

	ResetPos := InStr(Body, "_HC_Reset()")
	Assert(ResetPos > 0, "prerequisite: _HC_Close still tears the controller down")
	Assert(ResetPos < DestroyPos,
		"the controller must be closed BEFORE its host HWND is destroyed — the WebView2 spec requires that ordering, and it is the one _CLW_OnClose and _LLM_MBW_OnClose already use")
}
Test("meta healthcheck-singleton: _HC_Close destroys the previous window, not only its controller",
	_HCSW_CloseDestroysTheWindow)


; Manual closure retains one hidden host. A stale GUI callback still cannot
; revoke the newer singleton; destructive disposal remains owned by _HC_Close.
_HCSW_ManualCloseClearsTheHandle() {
	Body := _DriverFuncBody("_HealthCheck_CloseGui")
	Assert(Body != "", "_HealthCheck_CloseGui must exist in the driver source")
	Assert(InStr(Body, "G == _HC_Gui") > 0,
		"manual closure must validate the exact singleton GUI before retiring its session")
	Assert(InStr(Body, "G == _HC_Gui") < InStr(Body, "_HC_WindowEpoch += 1"),
		"stale GUI callbacks must be refused before the active epoch changes")
}
Test("meta healthcheck-singleton: manual closure validates the exact retained singleton",
	_HCSW_ManualCloseClearsTheHandle)


; WebMessageReceived is delivered asynchronously by WebView2, and the probes
; answer later still. A message or an answer of the window just closed can
; therefore arrive after its replacement has assigned the module globals. The
; subscription, the deferred handling and every push into the page carry the
; opening session, while Reset revokes that session before releasing COM state.
; This stays source-level because the headless suite never constructs WebView2.
_HCSW_MessagesOwnWindowSession() {
	ShowBody := _DriverFuncBody("HealthCheck_ShowWindow")
	ReceiveBody := _DriverFuncBody("_HC_OnWebMessage")
	HandleBody := _DriverFuncBody("_HC_HandleMessage")
	SendBody := _DriverFuncBody("_HC_Send")
	PublishBody := _DriverFuncBody("_HC_PublishProbe")
	ResetBody := _DriverFuncBody("_HC_Reset")
	Assert(ShowBody != "" && ReceiveBody != "" && HandleBody != "" && SendBody != "" && PublishBody != ""
		&& ResetBody != "", "the healthcheck WebView opening, messaging, and reset functions must exist")
	Assert(InStr(ShowBody, "_HC_WindowEpoch += 1") > 0
		&& InStr(ShowBody, "_HC_OnWebMessage.Bind(WindowEpoch)") > 0,
		"each healthcheck WebView instance must allocate and bind a window epoch to WebMessageReceived")
	GuardPos := InStr(ReceiveBody, "WindowEpoch != _HC_WindowEpoch")
	TimerPos := InStr(ReceiveBody, "_HC_HandleMessage.Bind(WindowEpoch")
	Assert(GuardPos > 0 && TimerPos > GuardPos,
		"a late message must be rejected for a retired session before its handling is scheduled")
	for Name, Body in Map("_HC_HandleMessage", HandleBody, "_HC_Send", SendBody, "_HC_PublishProbe", PublishBody)
		Assert(InStr(Body, "WindowEpoch != _HC_WindowEpoch") > 0,
			Name . " must revalidate its captured session before touching the page")
	RevokePos := InStr(ResetBody, "_HC_WindowEpoch += 1")
	CancelPos := InStr(ResetBody, "HealthCheck_CancelProbes()")
	ClosePos := InStr(ResetBody, ".Close()")
	Assert(RevokePos > 0 && CancelPos > RevokePos && ClosePos > CancelPos,
		"reset must revoke the window epoch and cancel its probes before closing the controller")
}
Test("meta healthcheck-singleton: page messages and probe answers cannot cross window sessions (AHK-152)",
	_HCSW_MessagesOwnWindowSession)

; Closing the UI must retire the session while preserving its bounded native host.
_HCSW_WarmReopen() {
	HideBody := _DriverFuncBody("_HealthCheck_CloseGui")
	ShowBody := _DriverFuncBody("HealthCheck_ShowWindow")
	Assert(HideBody != "" && ShowBody != "", "diagnostics lifecycle must exist")
	Assert(InStr(HideBody, ".Hide()") > 0 && InStr(HideBody, ".Destroy()") = 0,
		"manual close must hide the owned diagnostics host rather than rebuilding Chromium next time")
	Assert(InStr(ShowBody, "_HC_CanReuse(") > 0,
		"opening diagnostics must reuse its certified live host before creating another")
}
Test("diagnostics: warm reopen retains the native host (ui-warm-reopen)", _HCSW_WarmReopen)
