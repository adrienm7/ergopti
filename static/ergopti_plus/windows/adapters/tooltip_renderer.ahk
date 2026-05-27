; adapters/tooltip_renderer.ahk

; ==============================================================================
; MODULE: TooltipRenderer Adapter (AutoHotkey)
; DESCRIPTION:
; AHK v2 implementation of the TooltipRenderer port contract defined in
; static/ergopti_plus/_shared/ports/TooltipRenderer.spec.js. Wraps the existing
; lib/tooltip.ahk subsystem behind the four canonical functions
; (TooltipRShow, TooltipRHide, TooltipRIsVisible, TooltipRUpdateElement) so
; domain modules can control tooltip display without coupling to the AHK-
; specific Gui / tooltip implementation.
;
; NAMING CONVENTION:
; Port method → AHK name mapping:
;   show(payload)          → TooltipRShow(Payload)
;   hide()                 → TooltipRHide()
;   isVisible()            → TooltipRIsVisible()
;   updateElement(drawCall) → TooltipRUpdateElement(DrawCall)
;
; The "R" suffix prevents collision with the lib/tooltip.ahk public symbols
; (TooltipShow, TooltipHide) which use the same root name.
;
; DELEGATION MODEL:
; This adapter is a thin facade over lib/tooltip.ahk. No rendering logic lives
; here — the adapter only translates port contract calls into existing function
; calls. TooltipRShow unpacks the payload's "items" array if present; otherwise
; it passes the payload directly to TooltipShow.
; ==============================================================================

; Visibility sentinel — updated by TooltipRShow / TooltipRHide.
global _TOOLTIP_R_VISIBLE := false




; =======================================================
; =======================================================
; ======= 1/ Adapter Methods ============================
; =======================================================
; =======================================================

; Renders or updates the tooltip.
; @param Payload {Map} { items?, duration_sec?, position? }
;   items        {Array}  Array of content items passed to TooltipShow.
;   duration_sec {Float}  Auto-dismiss delay (0 = keep until hide).
;   position     {Map}    { x, y } screen coordinates (ignored — tooltip
;                         positions itself via caret / UIA detection).
TooltipRShow(Payload) {
	global _TOOLTIP_R_VISIBLE
	if !(Payload is Map)
		return
	Items       := Payload.Has("items")        ? Payload["items"]        : []
	DurationSec := Payload.Has("duration_sec") ? Payload["duration_sec"] : 0
	try {
		TooltipShow(Items, DurationSec)
		_TOOLTIP_R_VISIBLE := true
	} catch as Err {
		OutputDebug("TooltipRShow error: " . Err.Message)
		TooltipRHide()
	}
}

; Removes the tooltip from the screen immediately.
TooltipRHide() {
	global _TOOLTIP_R_VISIBLE
	try TooltipHide()
	_TOOLTIP_R_VISIBLE := false
}

; Returns true if the tooltip is currently visible.
; @return {Integer} 1 (true) or 0 (false).
TooltipRIsVisible() {
	global _TOOLTIP_R_VISIBLE
	return _TOOLTIP_R_VISIBLE
}

; Replaces a single draw call by its stable id.
; AHK tooltip rows are rebuilt on each TooltipShow call so there is no targeted
; element update API. This method falls back to a full re-render by calling
; TooltipRShow with a synthetic payload containing only the replacement content.
; @param DrawCall {Map} { id, text, … }
TooltipRUpdateElement(DrawCall) {
	if !(DrawCall is Map)
		return
	; Build a minimal payload so the existing subsystem can re-render.
	Payload := Map("items", [DrawCall], "duration_sec", 0)
	TooltipRShow(Payload)
}
