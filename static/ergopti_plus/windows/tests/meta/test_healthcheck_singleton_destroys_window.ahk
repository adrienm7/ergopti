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


; The handle must be dropped when the user closes the window by hand too, or the
; next _HC_Close would Destroy() a Gui that is already gone.
_HCSW_ManualCloseClearsTheHandle() {
	Body := _DriverFuncBody("_HealthCheck_CloseGui")
	Assert(Body != "", "_HealthCheck_CloseGui must exist in the driver source")
	Assert(InStr(Body, "_HC_Gui") > 0,
		"_HealthCheck_CloseGui must clear _HC_Gui — a stale handle left behind by a manual close makes the next open Destroy() a window that no longer exists")
}
Test("meta healthcheck-singleton: closing the window by hand clears the singleton handle",
	_HCSW_ManualCloseClearsTheHandle)
