; tests/meta/test_wpm_widget_hidden_until_typed.ahk

; ==============================================================================
; MODULE: WPM Widget Hidden-Until-Typed Meta Test
; DESCRIPTION:
; Regression guard: after an AHK reload the WPM widget must stay hidden until the
; user types again.
;
; PRIMARY ROOT CAUSE (graph mode): WPMWidget_PrewarmGraph warmed the layered window
; by rendering a real "0" graph into it. Gui.Show("Hide") leaves WS_VISIBLE set on
; the window (verified: IsWindowVisible == 1), and a layered window with a
; non-transparent surface displays the instant WS_VISIBLE is applied. WPMWidget_Show
; calls Gui.Show("Hide") AGAIN ~2500 ms in to reposition the window, re-applying
; WS_VISIBLE -- so the opaque "0" surface from the pre-warm flashed/sat on screen at
; the real position with no typing after every reload. (An off-screen warm did not
; help: the reposition brought it back on-screen.)
; FIX: WPMWidget_PrewarmGraph uploads a FULLY TRANSPARENT surface (GR_DrawBitmap with
; a no-op draw callback), which still warms the DWM/UpdateLayeredWindow path but is
; invisible regardless of WS_VISIBLE. The tick uploads the real opaque content only
; once the user types, so it stays the sole revealer.
;
; SECONDARY (defensive): WPMWidget.visible is set true by WPMWidget_LoadConfig at
; the start of boot, so keystrokes typed during boot/reload are counted into the
; ring via WPMWidget_Push. WPMWidget_Show calls _WPMWidget_ResetRolling() to
; discard the ring, history and input timestamps, so the surface only reveals on
; post-show typing rather than from pre-show keystrokes.
; ==============================================================================

#Requires AutoHotkey v2.0

_WHUT_ShowResetsRolling() {
	Body := _DriverFuncBody("WPMWidget_Show")
	Assert(Body != "", "WPMWidget_Show must exist in the wpm widget module")
	Assert(InStr(Body, "_WPMWidget_ResetRolling()") > 0,
		"WPMWidget_Show must call _WPMWidget_ResetRolling() so a reload does not reveal the widget from pre-show keystrokes")
}
Test("wpm-hidden-until-typed: WPMWidget_Show resets the rolling buffer on show", _WHUT_ShowResetsRolling)

_WHUT_ResetClearsState() {
	Body := _DriverFuncBody("_WPMWidget_ResetRolling")
	Assert(Body != "", "_WPMWidget_ResetRolling must exist")
	Assert(InStr(Body, "_ring := []") > 0,
		"_WPMWidget_ResetRolling must clear the keystroke ring")
	Assert(InStr(Body, "_last_input_ms := 0") > 0,
		"_WPMWidget_ResetRolling must reset the last-input timestamp (drives the idle/hide gate)")
}
Test("wpm-hidden-until-typed: _WPMWidget_ResetRolling clears ring + input timestamp", _WHUT_ResetClearsState)

_WHUT_PrewarmWarmsTransparent() {
	Body := _DriverFuncBody("WPMWidget_PrewarmGraph")
	Assert(Body != "", "WPMWidget_PrewarmGraph must exist in the wpm widget module")
	; The warm must NOT upload an opaque graph. WPMWidget_RenderGraph draws the "0"
	; pill, and Gui.Show("Hide") keeps WS_VISIBLE set on the layered window, so an
	; opaque warm surface flashes a "0" the moment WPMWidget_Show re-applies
	; WS_VISIBLE to reposition the window.
	Assert(InStr(Body, "WPMWidget_RenderGraph(") = 0,
		"WPMWidget_PrewarmGraph must NOT warm with WPMWidget_RenderGraph (opaque '0' surface) -- it flashes when WPMWidget_Show re-applies WS_VISIBLE")
	Assert(InStr(Body, "GR_DrawBitmap(") > 0,
		"WPMWidget_PrewarmGraph must warm the layered/DWM upload path via GR_DrawBitmap")
	Assert(InStr(Body, "_WPMWidget_WarmDrawTransparent") > 0,
		"WPMWidget_PrewarmGraph must warm with the transparent no-op draw callback so the uploaded surface is invisible regardless of WS_VISIBLE")
	Assert(InStr(Body, "GR_Hide(") > 0,
		"WPMWidget_PrewarmGraph must leave the window in the SW_HIDE resting state after the warm")
}
Test("wpm-hidden-until-typed: WPMWidget_PrewarmGraph warms with a transparent surface (no opaque '0')", _WHUT_PrewarmWarmsTransparent)

_WHUT_WarmDrawCallbackPaintsNothing() {
	Body := _DriverFuncBody("_WPMWidget_WarmDrawTransparent")
	Assert(Body != "", "_WPMWidget_WarmDrawTransparent must exist")
	Assert(InStr(Body, "Gdip") = 0,
		"_WPMWidget_WarmDrawTransparent must draw nothing (no GDI+ calls) so the warmed layered surface stays fully transparent")
	Assert(InStr(Body, "DllCall") = 0,
		"_WPMWidget_WarmDrawTransparent must draw nothing (no DllCall) so the warmed layered surface stays fully transparent")
}
Test("wpm-hidden-until-typed: _WPMWidget_WarmDrawTransparent paints nothing (surface stays transparent)", _WHUT_WarmDrawCallbackPaintsNothing)
