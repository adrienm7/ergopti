; tests/meta/test_uia_wrap_resets_both_buffers.ahk

; ==============================================================================
; MODULE: Regression — the UIA selection-wrap declares its edit to BOTH buffers
;         (uia-wrap-resets-only-the-preview-buffer)
; DESCRIPTION:
; Typing a wrapping symbol while text is selected replaces the selection with
; « (selection) »: the branch deletes the character the pass-through hook has
; already delivered, then injects the left symbol, the selection and the right
; symbol.
;
; ROOT CAUSE ENCODED: it declared that edit to ONE buffer. The finally reset
; _PrefixBuffer and returned — before Critical, before HSE_FeedChar — so the
; ENGINE buffer still described text that is no longer left of the caret. Every
; other site in the driver pairs the two (mouse click, Ctrl+A, Ctrl+X/V/Z/Y,
; Insert/Delete, Tab/Enter, navigation, Win+L, suspend/resume, live rebuild) and
; hotstring_buffer_effects.ahk states the contract as "both buffers or neither".
; The next expansion then counts its backspaces against the pre-wrap text and
; eats the wrapped selection instead of the trigger.
;
; The preview keeps agreeing with the engine throughout, because
; _PreviewEngineWouldFire evaluates candidates against HSE_Buffer — the two end
; up describing the pre-wrap world together, which is why nothing detects it.
;
; SCOPE: source-level. The branch needs a live UIA selection and a running
; InputHook, neither of which exists in the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0






; ====================================================================
; ====================================================================
; ======= 1/ The wrap branch invalidates the engine buffer too =======
; ====================================================================
; ====================================================================

_UWB_WrapResetsBothBuffers() {
	Body := _DriverFuncBody("_OnPrefixChar")
	Assert(Body != "", "_OnPrefixChar() must be readable")
	Pos := InStr(Body, "SendInstant(Left")
	Assert(Pos > 0, "the UIA selection-wrap branch must exist")
	Window := SubStr(Body, Pos, 400)
	Assert(InStr(Window, "_ResetPrefixBuffer") > 0,
		"the wrap must reset the preview buffer — this is the half that always worked")
	Assert(InStr(Window, "HSE_FeedReset") > 0,
		"the wrap replaces the selection and deletes the typed character, so the ENGINE buffer must be invalidated too. Resetting the preview alone leaves the engine holding text that is no longer left of the caret, and its next expansion backspaces over the wrapped selection")
	Assert(InStr(Window, "HSE_FeedReset(true, true)") > 0,
		"and it must declare itself PHYSICAL: the wrap runs with the suppression held, and HSE_FeedReset is a no-op for a non-physical caller while HSE_Suppressed is up — a silent no-op is exactly the failure this guards")
}
Test("meta hotstrings: the UIA selection-wrap resets both buffers (uia-wrap-resets-only-the-preview-buffer)",
	_UWB_WrapResetsBothBuffers)
